#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# worker_processes must track the container CPU limit, never the host core
# count. nginx's own `auto` calls sysconf(_SC_NPROCESSORS_ONLN) and cannot see
# the cgroup quota, so on a large node it starts several times more workers than
# the pod can run. Run from the chart subtree:
#   bash tests/chart-render/verify-worker-processes.sh
set -euo pipefail
CHART_DIR="$(cd "$(dirname "$0")/../.." && pwd)/deploy"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Emits the rendered worker_processes value for the given --set arguments.
wp() {
  helm template t "$CHART_DIR" "$@" 2>/dev/null \
    | grep -m1 'worker_processes' \
    | sed -E 's/.*worker_processes +([^;]+);.*/\1/'
}

echo "1. default: derived from resources.limits.cpu, not from the host"
got="$(wp)"
[ "$got" = "32" ] || fail "expected 32 from the default cpu limit, got '$got'"

echo "2. explicit cache.workerProcesses wins"
got="$(wp --set cache.workerProcesses=8)"
[ "$got" = "8" ] || fail "explicit override ignored, got '$got'"

echo "3. milliCPU limits are converted, not parsed as a bare integer"
got="$(wp --set resources.limits.cpu=16500m)"
[ "$got" = "16" ] || fail "expected 16 from 16500m, got '$got'"

echo "4. sub-core limits still yield at least one worker"
# A naive integer division here yields 0, and `worker_processes 0` is a config
# error that stops nginx from serving at all.
got="$(wp --set resources.limits.cpu=500m)"
[ "$got" = "1" ] || fail "expected 1 worker for a 500m limit, got '$got'"

echo "5. integer-typed limits parse the same as string-typed"
got="$(wp --set-json resources.limits.cpu=8)"
[ "$got" = "8" ] || fail "expected 8 from an integer-typed limit, got '$got'"

echo "6. no cpu limit falls back to auto"
# With no quota the host core count is the correct answer, so auto is right.
got="$(wp --set resources.limits.cpu=null)"
[ "$got" = "auto" ] || fail "expected auto when no cpu limit is set, got '$got'"

echo "7. worker_connections is per worker and is left alone"
helm template t "$CHART_DIR" 2>/dev/null | grep -q 'worker_connections  16384' \
  || fail "worker_connections must remain at its configured value"

echo "PASS: worker_processes tracks the CPU limit in every value shape"
