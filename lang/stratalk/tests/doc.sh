#!/bin/sh
# lang/stratalk/tests/doc.sh [-h] [FILE.st...]: the examples in the kernel's
# comments (lines `EXPR >>> RESULT`, which the site shows) as a test vector:
# each EXPR typed into `stratalk -` under StrataOS must print RESULT. Then the
# site's code blocks that have a Try button: each must run without an error.
#   -h   on the host's reference interpreter instead (the examples only)
#   FILE.st...  only the examples of these kernel files
set -eu
here=$(cd "$(dirname "$0")/../../.." && pwd)
h=
if [ "${1:-}" = "-h" ]; then h=-h; shift; fi
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
python3 "$here/doc/manual/gen/genstratalk.py" --examples "$d" ${h:+--host} "$@"
TESTS="$d" "$here/lang/stratalk/tests/run.sh" $h doc
