#!/bin/sh
# fetch-optional.sh: download the test suites whose licences keep them out of
# this repository (LGPL, GPL) into tests/optional/, which git ignores.
# Nothing here is needed by `make test-cc`.
set -e
cd "$(dirname "$0")"
mkdir -p optional
cd optional
# TinyCC tests2 (LGPL-2.1): single-file programs with expected output
[ -d tinycc ] || git clone --depth 1 https://repo.or.cz/tinycc.git tinycc
# c-testsuite (its 69 tests of TinyCC origin are LGPL; the rest come from scc)
[ -d c-testsuite ] || git clone --depth 1 https://github.com/c-testsuite/c-testsuite.git
# GCC's C torture tests (GPL-3.0): sparse checkout of gcc.c-torture/execute
if [ ! -d gcc ]; then
    git clone --depth 1 --filter=blob:none --sparse https://gcc.gnu.org/git/gcc.git gcc
    (cd gcc && git sparse-checkout set gcc/testsuite/gcc.c-torture/execute)
fi
echo "optional suites are in $(pwd)"
