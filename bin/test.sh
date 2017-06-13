#! /usr/bin/env bash

rm -f /cores/server.core /cores/client.core

v=${1:-5}

ninja && tmux new-session -d "sleep 0.1; bin/client -t3 -v$v" \; \
        split-window -h "bin/server -t5 -v$v" \; \
        set remain-on-exit on \; \
        attach
