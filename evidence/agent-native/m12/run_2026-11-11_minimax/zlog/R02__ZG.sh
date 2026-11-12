#!/usr/bin/env bash
printf '%s\n' "$*" >> '<repo>/evidence/agent-native/m12/run_2026-11-11_minimax/zlog/R02__ZG.log'
exec '~/.local/bin/ziggrep' "$@"
