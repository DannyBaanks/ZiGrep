#!/usr/bin/env bash
printf '%s\n' "$*" >> 'evidence/agent-native/m12/run_2026-11-11_minimax/zlog/R07__RG.log'
exec '~/.local/bin/ziggrep' "$@"
