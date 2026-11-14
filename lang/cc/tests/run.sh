#!/bin/sh
# run.sh [-v] [-f LIST] [RUNG-PREFIX | TEST.c ...]: the C test ladder.
# Compiles every test with cc inside StrataOS under the emulator, runs the
# result there and compares exit status and output (see README.md).
cd "$(dirname "$0")/../../.." || exit 2
exec python3 lang/cc/tests/ladder.py "$@"
