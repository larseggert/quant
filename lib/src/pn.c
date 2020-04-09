// SPDX-License-Identifier: BSD-2-Clause
//
// Copyright (c) 2016-2020, NetApp, Inc.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#include <stdbool.h>
#include <string.h>

#include "bitset.h"
#include "conn.h"
#include "frame.h"
#include "pkt.h"
#include "pn.h"
#include "quic.h"
#include "stream.h"

#ifdef DEBUG_EXTRA
#include "cid.h"
#endif


void pm_by_nr_del(khash_t(pm_by_nr) * const pbn,
                  const struct pkt_meta * const p)
{
    const khiter_t k = kh_get(pm_by_nr, pbn, p->hdr.nr);
    ensure(k != kh_end(pbn), "found");
    kh_del(pm_by_nr, pbn, k);
}


void pm_by_nr_ins(khash_t(pm_by_nr) * const pbn, struct pkt_meta * const p)
{
    int ret;
    const khiter_t k = kh_put(pm_by_nr, pbn, p->hdr.nr, &ret);
    ensure(ret >= 1, "inserted");
    kh_val(pbn, k) = p;
}


struct w_iov * find_sent_pkt(const struct pn_space * const pn,
                             const uint_t nr,
                             struct pkt_meta ** const m)
{
    const khiter_t k = kh_get(pm_by_nr, &pn->sent_pkts, nr);
    if (unlikely(k == kh_end(&pn->sent_pkts)))
        return 0;
    *m = kh_val(&pn->sent_pkts, k);
    return w_iov(pn->c->w, pm_idx(pn->c->w, *m));
}


void init_pn(struct pn_space * const pn,
             struct q_conn * const c,
             const pn_t type)
{
    diet_init(&pn->recv);
    diet_init(&pn->recv_all);
    diet_init(&pn->acked_or_lost);
    pn->lg_sent = pn->lg_acked = UINT_T_MAX;
    pn->c = c;
    pn->type = type;
    pn->abandoned = false;
}


void free_pn(struct pn_space * const pn)
{
    if (pn->abandoned == false) {
        struct pkt_meta * m;
        kh_foreach_value(&pn->sent_pkts, m, {
            // TX'ed but non-RTX'ed pkts are freed when their stream is freed
            if (m->has_rtx || !has_strm_data(m))
                free_iov(w_iov(pn->c->w, pm_idx(pn->c->w, m)), m);
        });
        kh_release(pm_by_nr, &pn->sent_pkts);
        pn->abandoned = true;
    }

    diet_free(&pn->recv);
    diet_free(&pn->recv_all);
    diet_free(&pn->acked_or_lost);
}


void reset_pn(struct pn_space * const pn)
{
    free_pn(pn);
    memset(&pn->sent_pkts, 0, sizeof(pn->sent_pkts));
    pn->lg_sent = pn->lg_acked = UINT_T_MAX;
    pn->ect0_cnt = pn->ect1_cnt = pn->ce_cnt = 0;
    pn->pkts_rxed_since_last_ack_tx = 0;
    pn->abandoned = false;
    bit_zero(FRM_MAX, &pn->rx_frames);
    bit_zero(FRM_MAX, &pn->tx_frames);
}


void abandon_pn(struct pn_space * const pn)
{
    ensure(pn->type != pn_data, "cannot abandon pn_data");

    warn(DBG, "abandoning %s %s processing", conn_type(pn->c),
         pn_type_str(pn->type));

    struct q_conn * const c = pn->c;
    if (c->pmtud_pkt != UINT16_MAX && c->pmtud_pkt >> 14 == pn->type)
        validate_pmtu(c);

    epoch_t e = ep_init;
    if (unlikely(pn->type == pn_hshk))
        e = ep_hshk;
    free_stream(c->cstrms[e]);
    c->cstrms[e] = 0;
    free_pn(pn);
    dispose_cipher(&pn->early.in);
    dispose_cipher(&pn->early.out);
}


ack_t needs_ack(const struct pn_space * const pn)
{
    if (unlikely(pn->imm_ack)) {
#ifdef DEBUG_EXTRA
        warn(DBG, "%s conn %s: %s imm_ack: forced", conn_type(pn->c),
             cid_str(pn->c->scid), pn_type_str(pn->type));
#endif
        return imm_ack;
    }

    const bool rxed_one_or_more = pn->pkts_rxed_since_last_ack_tx >= 1;
    if (rxed_one_or_more == false) {
#ifdef DEBUG_EXTRA
        warn(DBG, "%s conn %s: %s no_ack: rxed_one_or_more == false",
             conn_type(pn->c), cid_str(pn->c->scid), pn_type_str(pn->type));
#endif
        return no_ack;
    }

    const bool rxed_ack_eliciting = is_ack_eliciting(&pn->rx_frames);
    if (rxed_ack_eliciting == false) {
#ifdef DEBUG_EXTRA
        warn(DBG, "%s conn %s: %s grat_ack: rxed_ack_eliciting == false",
             conn_type(pn->c), cid_str(pn->c->scid), pn_type_str(pn->type));
#endif
        return grat_ack;
    }

    const bool in_hshk = pn->type != pn_data || has_frm(pn->rx_frames, FRM_CRY);
    if (in_hshk) {
#ifdef DEBUG_EXTRA
        warn(DBG, "%s conn %s: %s imm_ack: in_hshk", conn_type(pn->c),
             cid_str(pn->c->scid), pn_type_str(pn->type));
#endif
        return imm_ack;
    }

    const bool rxed_two_or_more = pn->pkts_rxed_since_last_ack_tx >= 2;
    if (rxed_two_or_more) {
#ifdef DEBUG_EXTRA
        warn(DBG, "%s conn %s: %s imm_ack: rxed_two_or_more", conn_type(pn->c),
             cid_str(pn->c->scid), pn_type_str(pn->type));
#endif
        return imm_ack;
    }

#ifdef DEBUG_EXTRA
    warn(DBG, "%s conn %s: %s del_ack", conn_type(pn->c), cid_str(pn->c->scid),
         pn_type_str(pn->type));
#endif
    return del_ack;
}
