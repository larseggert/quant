#! /usr/bin/env bash

# SPDX-License-Identifier: BSD-2-Clause
#
# Copyright (c) 2016-2020, NetApp, Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
#    this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.


declare -A servers=(
    # # [tag]="name|flags|port|retry-port|h3-port|URL"
    [aioquic]="quic.aiortc.org||443|4434|443|/40000"
    [akamai]="ietf.akaquic.com|-3|443|443|443|/100k"
    # [apple]="[2a00:79e1:abc:301:18c7:dac8:b9c6:f91f]|-3|4433|4433|4433|/40000"
    [ats]="quic.ogre.com||4433|4434|4433|/en/latest/_static/jquery.js"
    [f5]="f5quic.com|-3|4433|4433|4433|/50000"
    [google]="quic.rocks|-3|4433|4434|4433|/40000"
    [haskell]="mew.org||4433|4433|4433|/40000"
    [lsquic]="http3-test.litespeedtech.com|-3|4433|4434|4433|/40000"
    [mvfst]="fb.mvfst.net|-3|443|4434|443|/40000"
    [ngtcp2]="nghttp2.org|-3|4433|4434|4433|/40000"
    [ngx_quic]="cloudflare-quic.com|-3|443|443|443|/index.html"
    # [pandora]="pandora.cm.in.tum.de||4433|4434|4433|/index.html"
    [picoquic]="test.privateoctopus.com||4433|4434|4433|/40000"
    [quant]="quant.eggert.org||4433|4434|4433|/40000"
    [quic-go]="quic.seemann.io|-3|443|443|443|/dynamic/40000"
    [quiche]="quic.tech|-3|8443|8444|8443|/128KB.png"
    # [quicker]="quicker.edm.uhasselt.be||4433|4434|4433|/index.html"
    [quicly]="quic.examp1e.net||4433|4434|443|/40000"
    [quinn]="h3.stammw.eu||4433|4434|443|/100K"
    [winquic]="quic.westus.cloudapp.azure.com||4433|4434|443|/draft-ietf-quic-http-11.txt"
    # [local]="localhost||4433|4434|4433|/40000"
)

results=(live fail vneg hshk data clse rsmt zrtt rtry qrdy migr bind adrm kyph spin aecn zcid http)

if [ -n "$1" ]; then
    results+=(perf t_h2 t_hq)
    benchmarking=1
fi


iface=$(route get default | grep interface: | cut -f2 -d: | tr -d "[:space:]")

# use colordiff, if installed
if command -v colordiff > /dev/null; then
    colordiff=$(command -v colordiff)
else
    colordiff=$(command -v cat)
fi


pid=$$
script=$(basename -s .sh "$0")
rm -rf /tmp/"$script"*

# detect_leaks=1:
export ASAN_OPTIONS=strict_string_checks=1:strict_init_order=1:detect_stack_use_after_return=1:check_initialization_order=1:sleep_before_dying=30:alloc_dealloc_mismatch=1:detect_invalid_pointer_pairs=1:print_stacktrace=1:halt_on_error=1
export UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1:suppressions=../misc/gcc-ubsan-suppressions.txt

function test_server {
    # run quant client and save a log for post-processing
    local opts="-i $iface -t5 -v5 -b 1000 -l /dev/null"
    local log_base="/tmp/$script.$pid.$1.log"

    IFS='|' read -ra info <<< "${servers[$1]}"
    # 0=name, 1=flags, 2=port, 3=retry-port, 4=h3-port, 5=URL

    # initial 1rtt run followed by consecutive rsmt/0rtt run
    local cache="/tmp/$script.$pid.$1.cache"
    bin/client $opts -s "$cache" ${info[1]} \
        "https://${info[0]}:${info[2]}${info[5]}" > "$log_base.1rtt" 2>&1 ; \

    if ! grep -E -q 'RX.*len=' "$log_base.1rtt"; then
        # server seems down, skip the rest of the tests
        return
    fi

    bin/client $opts -s "$cache" ${info[1]} \
        "https://${info[0]}:${info[2]}${info[5]}" > "$log_base.0rtt" 2>&1 ; \
    [ -z "$benchmarking" ] && rm -f "$cache" &

    # rtry run
    bin/client $opts ${info[1]} -s /dev/null \
        "https://${info[0]}:${info[3]}${info[5]}" > "$log_base.rtry" 2>&1 &

    # key update run
    bin/client $opts ${info[1]} -s /dev/null -u \
        "https://${info[0]}:${info[2]}${info[5]}" > "$log_base.kyph" 2>&1 &

    # h3 run
    bin/client $opts ${info[1]} -s /dev/null -3 \
        "https://${info[0]}:${info[4]}${info[5]}" > "$log_base.h3" 2>&1 &

    # NAT rebinding run
    bin/client $opts ${info[1]} -s /dev/null -n \
        "https://${info[0]}:${info[2]}${info[5]}" > "$log_base.nat" 2>&1 &

    # quantum-readiness run
    bin/client $opts ${info[1]} -s /dev/null -m \
        "https://${info[0]}:${info[2]}${info[5]}" > "$log_base.qr" 2>&1 &

    # IP address mobility run
    bin/client $opts ${info[1]} -s /dev/null -n -n \
        "https://${info[0]}:${info[2]}${info[5]}" > "$log_base.adrm" 2>&1 &

    # zero-len CID run
    bin/client $opts ${info[1]} -s /dev/null -z \
        "https://${info[0]}:${info[2]}${info[5]}" > "$log_base.zcid" 2>&1 &

    wait
    printf "%s " "$s"
}


function bench_server {
    IFS='|' read -ra info <<< "${servers[$1]}"
    # 0=name, 1=flags, 2=port, 3=retry-port, 4=h3-port, 5=URL

    local size=5000000
    local obj=$size
    local log_base="/tmp/$script.$pid.$1.bench"
    local ret_base="/tmp/$script.$pid.$1.ret"
    local h2_out="$log_base.h2.out"
    local h2 ext prefix port host
    host=${info[0]}
    port=443

    if ! grep -E -q 'RX.*len=' "/tmp/$script.$pid.$1.log.1rtt"; then
        # server seems down, skip benchmark
        return
    fi

    # special cases for some servers
    [ "$s" = "winquic" ] && ext=.txt
    [ "$s" = "quic-go" ] && prefix=dynamic/
    [ "$s" = "quicly" ] && port=8443
    [ "$s" = "ngx_quic" ] && obj=5MB.png
    [ "$s" = "lsquic" ] && host=http3check.net && prefix=test/
    [ "$s" = "mvfst" ] && port=443

    h2=$({ time -p curl -k -s -o "$h2_out" --max-time 20 --connect-timeout 3 \
                 "https://$host:$port/$prefix$obj$ext"; } 2>&1)
    h2=$(echo "$h2" | fmt | cut -d' ' -f2)
    h2_size=$(stat -q "$h2_out" | cut -d' ' -f8)
    rm -f "$h2_out"
    if [ -n "$h2_size" ] && [ "$h2_size" -ge $size ]; then
        echo "$h2" > "$ret_base.t_h2"

        local cache="/tmp/$script.$pid.$1.cache"
        local opts="-i $iface -t5 -v3 -l /dev/null"
        local hq_out="$log_base.hq.out"
        local wd hq
        ext=""
        prefix=""
        host=${info[0]}
        port=${info[2]}

        [ "$s" = "quicly" ] && ext=.txt
        [ "$s" = "lsquic" ] && port=4435

        mkdir "$hq_out"
        wd=$(pwd)
        pushd "$hq_out" > /dev/null || exit
        hq=$({ time -p $wd/bin/client $opts ${info[1]} -s "$cache" -w \
                     "https://$host:$port/$prefix$obj$ext" \
                     > "$log_base.log" 2>&1 ; } 2>&1)
        hq=$(echo "$hq" | fmt | cut -d' ' -f2)
        hq_size=$(stat -q "$obj$ext" | cut -d' ' -f8)
        popd > /dev/null || exit
        rm -rf "$hq_out" "$cache"

        if [ -n "$h2_size" ] && [ -n "$hq_size" ] && \
            [ "$hq_size" -ge "$size" ]; then
            echo "$hq" > "$ret_base.t_hq"
            perl -e "print 'T' if $h2 * 1.1 >= $hq" > "$ret_base.perf"
        fi
    fi

    printf "%s " "$s"
}


function check_fail {
    local log="$2"
    if grep -q -E 'assertion failed|AddressSanitizer|runtime error|ABORT:' "$log"; then
        ret="X"
    elif grep -q -E 'hexdump|STATELESS|_close_frame.*0x1c=quic err=0x[^0]' "$log"; then
        ret="x"
    else
        return 0
    fi

    local ret_base="/tmp/$script.$pid.$1.ret"
    echo $ret > "$ret_base.fail"
    echo "Test with $1 failed with $ret (log $3)"
    return 1
}


function analyze {
    local ret_base="/tmp/$script.$pid.$1.ret"
    local log_base="/tmp/$script.$pid.$1.log"
    local sed_pattern='s,\x1B\[[0-9;]*[a-zA-Z],,g'

    # analyze 1rtt
    local log="$log_base.1rtt"
    local log_strip="$log.strip"
    gsed "$sed_pattern" "$log" > "$log_strip"
    check_fail "$1" "$log_strip" "$log"

    grep -E -q 'RX.*len=' "$log_strip" && echo \* > "$ret_base.live"
    [ ! -s "$ret_base.live" ] && return

    perl -n -e 'BEGIN{$v=-1};
                /0xbabababa, retrying with/ and $v=1;
                /no vers in common/ and $v=0;
                END{exit $v};' "$log_strip"
    local r=$?
    if [ $r -eq 1 ]; then
        echo V > "$ret_base.vneg"
    elif [ $r -eq 0 ]; then
        echo v > "$ret_base.vneg"
    fi

    perl -n -e '/TX.*Short kyph/ and $x=1;
        /RX.*len=.*Short/ && $x && exit 1;' "$log_strip"
    [ $? -eq 1 ] && echo H > "$ret_base.hshk"

    perl -n -e '/read (.*) bytes.*on clnt conn/ and ($1 > 0 ? $x=1 : next);
        /dec_close.*err=0x([^ ]*)/ and ($1 ne "0" ? exit 0 : next);
        /enc_close.*err=0x0/ and $e=1;
        END{exit ($x + $e == 2)};' "$log_strip"
    [ $? -eq 1 ] && echo D > "$ret_base.data"

    perl -n -e 'BEGIN{$x=0};
        /dec_close.*err=0x([^ ]*)/ and ($1 eq "0000" ? $x++ : next);
        /enc_close.*err=0x0/ and $x++;
        END{exit $x};' "$log_strip"
    local r=$?
    if [ $r -ge 2 ]; then
        echo C > "$ret_base.clse"
    elif [ $r -eq 1 ]; then
        echo C > "$ret_base.clse" # c
    fi

    perl -n -e '/dec_new_cid_frame.*NEW_CONNECTION_ID|preferred_address.*cid=1:/ and $n=1;
        /migration to dcid/ && $n && exit 1;' "$log_strip"
    [ $? -eq 1 ] && echo M > "$ret_base.migr"

    # analyze spin
    perl -n -e '/TX.*spin=1/ and $n=1;
        $n && /RX.*spin=1/ && exit 1;' "$log_strip"
    [ $? -eq 1 ] && echo P > "$ret_base.spin"

    # analyze ECN
    perl -n -e '/ECN verification failed/ and $n=-1;
        $n==0 && /dec_ack_frame.*ECN ect0=/ && exit 1;' "$log_strip"
    [ $? -eq 1 ] && echo E > "$ret_base.aecn"
    [ ! -e "$ret_base.fail" ] && [ -s "$ret_base.hshk" ] && \
        [ -s "$ret_base.data" ] && [ -s "$ret_base.clse" ] && rm -f "$log"
    rm -f "$log_strip"

    # analyze rsmt and 0rtt
    local log="$log_base.0rtt"
    local log_strip="$log.strip"
    gsed "$sed_pattern" "$log" > "$log_strip"
    check_fail "$1" "$log_strip" "$log"

    perl -n -e '/new 0-RTT clnt conn/ and $x=1;
        /dec_close.*err=0x([^ ]*)/ and ($1 ne "0" ? exit 0 : next);
        /enc_close.*err=0x0/ and $e=1;
        END{exit ($x + $e == 2)};' "$log_strip"
    [ $? -eq 1 ] && echo R > "$ret_base.rsmt"

    perl -n -e '/connected after 0-RTT/ and $x=1;
        /dec_close.*err=0x([^ ]*)/ and ($1 ne "0" ? exit 0 : next);
        /enc_close.*err=0x0/ and $e=1;
        END{exit ($x + $e == 2)};' "$log_strip"
    [ $? -eq 1 ] && echo Z > "$ret_base.zrtt"
    [ ! -e "$ret_base.fail" ] && [ -s "$ret_base.rsmt" ] && \
        [ -s "$ret_base.zrtt" ] && rm -f "$log"
    rm -f "$log_strip"

    # analyze rtry
    local log="$log_base.rtry"
    local log_strip="$log.strip"
    gsed "$sed_pattern" "$log" > "$log_strip"
    check_fail "$1" "$log_strip" "$log"

    perl -n -e '/RX.*len=.*Retry/ and $x=1;
        /dec_close.*err=0x([^ ]*)/ and ($1 ne "0" ? exit 0 : next);
       /enc_close.*err=0x0/ and $e=1;
       END{exit ($x + $e == 2)};' "$log_strip"
    [ $? -eq 1 ] && echo S > "$ret_base.rtry"
    [ ! -e "$ret_base.fail" ] && [ -s "$ret_base.rtry" ] && rm -f "$log"
    rm -f "$log_strip"

    # analyze key update
    local log="$log_base.kyph"
    local log_strip="$log.strip"
    gsed "$sed_pattern" "$log" > "$log_strip"
    check_fail "$1" "$log_strip" "$log"

    perl -n -e '/TX.*Short kyph=1/ and $x=1;
        /dec_close.*err=0x([^ ]*)/ and ($1 ne "0" ? exit 0 : next);
       $x && /RX.*Short kyph=1/ && exit 1;' "$log_strip"
    [ $? -eq 1 ] && echo U > "$ret_base.kyph"
    [ ! -e "$ret_base.fail" ] && [ -s "$ret_base.kyph" ] && rm -f "$log"
    rm -f "$log_strip"

    # analyze h3
    local log="$log_base.h3"
    local log_strip="$log.strip"
    gsed "$sed_pattern" "$log" > "$log_strip"
    check_fail "$1" "$log_strip" "$log"

    perl -n -e '/read (.*) bytes.*on clnt conn/ and ($1 > 0 ? $x=1 : next);
        /no h3 payload/ and $x=0;
        /dec_close.*err=0x([^ ]*)/ and ($1 ne "0" ? exit 0 : next);
        /enc_close.*err=0x0/ and $e=1;
        END{exit ($x + $e == 2)};' "$log_strip"
    [ $? -eq 1 ] && echo 3 > "$ret_base.http"
    [ ! -e "$ret_base.fail" ] && [ -s "$ret_base.http" ] && rm -f "$log"
    rm -f "$log_strip"

    # analyze NAT rebind
    local log="$log_base.nat"
    local log_strip="$log.strip"
    gsed "$sed_pattern" "$log" > "$log_strip"
    check_fail "$1" "$log_strip" "$log"

    perl -n -e '/NAT rebinding/ and $x=1;
        /dec_path.*PATH_CHALLENGE/ and $x==1 and $x=2;
        /enc_path.*PATH_RESPONSE/ and $x==2 and $x=3;
        /read (.*) bytes.*on clnt conn/ and $x==3 and ($1 > 0 ? $x=4 : next);
        /dec_close.*err=0x([^ ]*)/ and ($1 ne "0" ? exit 0 : next);
        $x==4 && /enc_close.*err=0x0/ && exit 1;' "$log_strip"
    [ $? -eq 1 ] && echo B > "$ret_base.bind"
    [ ! -e "$ret_base.fail" ] && [ -s "$ret_base.bind" ] && rm -f "$log"
    rm -f "$log_strip"

    # analyze quantum-readiness
    local log="$log_base.qr"
    local log_strip="$log.strip"
    gsed "$sed_pattern" "$log" > "$log_strip"
    check_fail "$1" "$log_strip" "$log"

    perl -n -e '/read (.*) bytes.*on clnt conn/ and ($1 > 0 ? $x=1 : next);
        /no h3 payload/ and $x=0;
        /dec_close.*err=0x([^ ]*)/ and ($1 ne "0" ? exit 0 : next);
        /enc_close.*err=0x0/ and $e=1;
        END{exit ($x + $e == 2)};' "$log_strip"
    [ $? -eq 1 ] && echo Q > "$ret_base.qrdy"
    [ ! -e "$ret_base.fail" ] && [ -s "$ret_base.qrdy" ] && rm -f "$log"
    rm -f "$log_strip"

    # analyze IP address mobility
    local log="$log_base.adrm"
    local log_strip="$log.strip"
    gsed "$sed_pattern" "$log" > "$log_strip"
    check_fail "$1" "$log_strip" "$log"

    perl -n -e '/conn migration.*failed/ && exit 0;
        /read (.*) bytes.*on clnt conn/ and ($1 > 0 ? $x=1 : next);
        /no h3 payload/ and $x=0;
        /dec_close.*err=0x([^ ]*)/ and ($1 ne "0" ? exit 0 : next);
        /enc_close.*err=0x0/ and $e=1;
        END{exit ($x + $e == 2)};' "$log_strip"
    [ $? -eq 1 ] && echo A > "$ret_base.adrm"
    [ ! -e "$ret_base.fail" ] && [ -s "$ret_base.adrm" ] && rm -f "$log"
    rm -f "$log_strip"

    # analyze zero-len source CIDs
    local log="$log_base.zcid"
    local log_strip="$log.strip"
    gsed "$sed_pattern" "$log" > "$log_strip"
    check_fail "$1" "$log_strip" "$log"

    perl -n -e '/read (.*) bytes.*on clnt conn/ and ($1 > 0 ? $x=1 : next);
        /no h3 payload/ and $x=0;
        /dec_close.*err=0x([^ ]*)/ and ($1 ne "0" ? exit 0 : next);
        /enc_close.*err=0x0/ and $e=1;
        END{exit ($x + $e == 2)};' "$log_strip"
    [ $? -eq 1 ] && echo O > "$ret_base.zcid"
    [ ! -e "$ret_base.fail" ] && [ -s "$ret_base.zcid" ] && rm -f "$log"
    rm -f "$log_strip"

    printf "%s " "$s"
}


printf "Testing: "
for s in "${!servers[@]}"; do
    test_server "$s" &
done
wait

if [ -n "$benchmarking" ]; then
    printf "\\nBenchmarking: "
    for s in "${!servers[@]}"; do
        bench_server "$s"
    done
fi

printf "\\nAnalyzing: "
for s in "${!servers[@]}"; do
    analyze "$s" &
done
wait

printf "\\n\\n"

tmp=$(mktemp)
printf "%8s\\t" "" >> "$tmp"
for r in "${results[@]}"; do
    printf "%s\\t" "$r" >> "$tmp"
done
printf "\\n" >> "$tmp"

mapfile -d '' sorted < <(printf '%s\0' "${!servers[@]}" | sort -z)
ret_base="/tmp/$script.$pid"
for s in "${sorted[@]}"; do
    printf "%-8s\\t" "$s" >> "$tmp"
    for r in "${results[@]}"; do
        ret=$ret_base.$s.ret.$r
        if [ -s "$ret" ]; then
            v=$(cat "$ret")
        else
            v=""
        fi
        rm -f "$ret"
        printf "%s\\t" "$v" >> "$tmp"
    done
    printf "\\n" >> "$tmp"
done

tmp2=$(mktemp)
expand -t 5 "$tmp" > "$tmp2"
mv "$tmp2" "$tmp"
if ! diff -wq "$(dirname $0)/$script.result" "$tmp" > /dev/null; then
    cat "$tmp"
fi
wdiff -n "$(dirname $0)/$script.result" "$tmp" | $colordiff
rm -f "$tmp"
