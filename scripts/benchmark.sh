#!/bin/zsh
# Opt-in core and AppKit benchmarks share the test harness.
set -e
cd "$(dirname "$0")/.."
KNOPO_BENCH=1 KNOPO_SIDEBAR_BENCH=1 ./scripts/test.sh -c release \
  --filter 'InlineParserBenchmark|TypingCostBenchmark|EditCostBenchmark|SidebarOpenBenchmark' "$@"
