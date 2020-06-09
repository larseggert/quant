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

#pragma once

#include <stdint.h>

#include <quant/quant.h>

#include "diet.h"
#include "frame.h"
#include "tls.h"

struct pkt_meta; // IWYU pragma: no_forward_declare pkt_meta
struct q_conn;   // IWYU pragma: no_forward_declare q_conn
// IWYU pragma: no_include "quic.h"


KHASH_MAP_INIT_INT64(pm_by_nr, struct pkt_meta *)


struct pn_hshk {
    struct cipher_ctx in;
    struct cipher_ctx out;
};


struct pn_data {
    struct cipher_ctx in_0rtt;
    struct cipher_ctx out_0rtt;
    struct cipher_ctx in_1rtt[2];
    struct cipher_ctx out_1rtt[2];
    uint8_t in_kyph : 1;  ///< Last seen inbound key phase bit.
    uint8_t out_kyph : 1; ///< Current outbound key phase bit.
    uint8_t : 6;
    uint8_t _unused[7];
};


typedef enum { pn_init = 0, pn_hshk = 1, pn_data = 2 } pn_t;


static inline const char * __attribute__((const)) pn_type_str(const pn_t type)
{
    switch (type) { // lgtm [cpp/missing-return]
    case pn_init:
        return "Initial";
    case pn_hshk:
        return "Handshake";
    case pn_data:
        return "Data";
    default:
        die("unhandled pn %u", type);
    }
}


struct pn_space {
    struct q_conn * c;

    struct frames rx_frames; ///< Frame types RX'ed since last ACK TX.
    struct frames tx_frames; ///< Frame types TX'ed since last ACK RX.

    struct diet recv; ///< Received packet numbers still needing to be ACKed.
    struct diet recv_all;      ///< All received packet numbers.
    struct diet acked_or_lost; ///< Sent packet numbers already ACKed (or lost).

    khash_t(pm_by_nr) sent_pkts; // sent_packets

    uint_t lg_sent;            // largest_sent_packet
    uint_t lg_acked;           // largest_acked_packet
    uint_t lg_sent_before_rto; // largest_sent_before_rto

    uint_t pkts_rxed_since_last_ack_tx;

#ifndef NO_ECN
    uint_t ecn_ref[ECN_MASK + 1];
    uint_t ecn_rxed[ECN_MASK + 1];
#endif

#if !HAVE_64BIT
    uint8_t _unused[4];
#endif

    uint64_t loss_t;       // loss_time
    uint64_t last_ae_tx_t; // time_of_last_sent_ack_eliciting_packet

    pn_t type;

    uint8_t _unused2[3];

    uint8_t imm_ack : 1;   ///< Force an immediate ACK.
    uint8_t abandoned : 1; ///< Has this PN space been abandoned?
    uint8_t : 6;

    union {
        struct pn_hshk early;
        struct pn_data data;
    };
};


extern void __attribute__((nonnull))
pm_by_nr_del(khash_t(pm_by_nr) * const pbn, const struct pkt_meta * const p);

extern void __attribute__((nonnull))
pm_by_nr_ins(khash_t(pm_by_nr) * const pbn, struct pkt_meta * const p);

extern struct w_iov * __attribute__((nonnull))
find_sent_pkt(const struct pn_space * const pn,
              const uint_t nr,
              struct pkt_meta ** const m);

extern void __attribute__((nonnull))
init_pn(struct pn_space * const pn, struct q_conn * const c, const pn_t type);

extern void __attribute__((nonnull)) free_pn(struct pn_space * const pn);

extern void __attribute__((nonnull)) reset_pn(struct pn_space * const pn);

extern void __attribute__((nonnull)) abandon_pn(struct pn_space * const pn);


typedef enum { no_ack = 0, grat_ack = 1, del_ack = 2, imm_ack = 3 } ack_t;

extern ack_t __attribute__((nonnull))
needs_ack(const struct pn_space * const pn);
