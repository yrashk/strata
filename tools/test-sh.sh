#!/bin/sh
# The interactive shell on the emulator: line editing, history, Tab
# completion, quoting and variables, lists, jobs and builtins. Boots StrataOS
# with a scripted console (keys as the terminal sends them: escape sequences
# for the arrows, Home/End and Delete; DEL for Backspace; control characters)
# and compares the console output with tools/test-sh.out.
#
#   tools/test-sh.sh build/bootrom.stx build/disk.img     (-u: update the .out)
#
# The emulator runs the interpreter with the virtual timer (-j -T virtual),
# so the session is deterministic. Before comparing, the output is cut to start
# at the first prompt (the boot messages belong to the kernel), pids in job
# reports and `time` results are replaced by placeholders, and control bytes
# are shown as cat -v does (^[ is ESC).
set -u
here=$(cd "$(dirname "$0")/.." && pwd)
b="$here/${BUILD:-build}"
n=${NCORES:-8}
upd=0
if [ "${1:-}" = "-u" ]; then upd=1; shift; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
E=$(printf '\033')
UP="$E[A"; DN="$E[B"; RT="$E[C"; LT="$E[D"; HOME="$E[H"; END="$E[F"; DEL="$E[3~"
BS=$(printf '\177'); TAB=$(printf '\t')
CA=$(printf '\001'); CE=$(printf '\005'); CK=$(printf '\013'); CU=$(printf '\025')
CW=$(printf '\027'); CL=$(printf '\014'); CD=$(printf '\004')
{
  # editing
  printf 'echo hellX%so world\n' "$BS"
  printf 'echo wrld%s%s%so\n' "$LT" "$LT" "$LT"
  printf 'cho hi%se%s!\n' "$HOME" "$END"
  printf 'cho there%se%s.\n' "$CA" "$CE"
  printf 'echo abXc%s%s%s\n' "$LT" "$LT" "$DEL"
  printf 'echo keep junk%s%s%s%s%s%s\n' "$LT" "$LT" "$LT" "$LT" "$LT" "$CK"
  printf 'garbage%secho after-u\n' "$CU"
  printf 'echo one two%sthree\n' "$CW"
  printf 'echo xyz%s%s!\n' "$BS" "$BS"
  printf '%s' "$CL"; printf 'echo cleared\n'
  # history
  printf '%s\n' "$UP"
  printf '%s%s%s%s\n' "$UP" "$UP" "$UP" "$DN"
  printf 'echo new%s%s%s\n' "$UP" "$DN" "$BS"
  printf 'history\n'
  # completion
  printf 'echo alpha beta > tfile\n'
  printf 'ech%shi\n' "$TAB"
  printf 'echo hi | upp%s\n' "$TAB"
  printf 'cat tf%s\n' "$TAB"
  printf 'hell%s\n' "$TAB"
  printf 'hel%s%s%s\n' "$TAB" "$TAB" "$CU"
  printf 'un%s%s%secho listed\n' "$TAB" "$TAB" "$CU"
  printf 'echo stream%s%s x%s\n' "$TAB" "$TAB" "$CU"
  printf 'wc < tf%s\n' "$TAB"
  printf -- '-n 2 hell%s\n' "$TAB"
  printf 'run -n 2 hell%s\n' "$TAB"
  # quoting, variables, status
  printf "echo 'a  b' \"c  d\" e\"f g\"h\n"
  printf 'set X world\n'
  printf "echo \"hello \$X\" '\$X' \$X!\n"
  printf 'set GREETING hi there\n'
  printf 'set\n'
  printf 'unset X; echo [$X] [$GREETING]\n'
  printf 'false\n'
  printf 'echo $?; echo $?\n'
  printf 'echo "unterminated\n'
  printf 'echo a # a comment\n'
  printf '# only a comment\n'
  # lists
  printf 'true && echo yes || echo no\n'
  printf 'false && echo yes || echo no\n'
  printf 'cat nosuch || echo failed: $?\n'
  printf 'echo a; echo b ;echo c\n'
  printf 'false || false && echo not-run; echo after\n'
  printf '&& echo bad\n'
  # pipelines and redirections
  printf 'seq 12 | grep 1 | wc\n'
  printf 'echo piped builtin | upper\n'
  printf "echo it\\\\'s \"a  b\" \\\\\$X \\\\; c | upper\n"
  printf 'echo "jobs; echo piped" | sh\n'
  printf 'sh -c "set A 1; echo \\$A"\n'
  printf 'echo a\\ \\ b "q\\"q" \\# x\n'
  printf 'echo to a file > f1; echo more >> f1; cat < f1\n'
  # scripts
  printf 'echo echo sourced $$ > s1; echo set Y from-script >> s1\n'
  printf 'source s1; echo Y=$Y\n'
  printf 'sh s1\n'
  printf 'sh -c "echo from -c; false"\n'
  printf 'source nosuch\n'
  # jobs
  printf 'sleep 0.05 & echo started\n'
  printf 'jobs\n'
  printf 'wait %%1\n'
  printf 'seq 3 > f2 &\n'
  printf 'wait\n'
  printf 'cat f2\n'
  printf 'spin > f3 &\n'
  printf 'kill %%1\n'
  printf 'wait\n'
  printf 'sleep 0.05 &\n'
  printf 'fg\n'
  printf 'fg\n'
  printf 'time sleep 0.1\n'
  printf 'sleep x\n'
  # tags: files in several "directories" at once, intersections, tag paths
  printf 'tags motd rc ls\n'
  printf 'echo alpha > n1; echo beta > /notes/n2; echo gamma > /notes/work/n3\n'
  printf 'tag n1 notes\n'
  printf 'ls -t /notes\n'
  printf 'ls /notes/work; ls /work//notes/; ls /work/n3\n'
  printf 'tags n1 n2 n3 | upper\n'
  printf 'cat /work/n3 /notes/n2 n1\n'
  printf 'cat /work/n2 || cat /nosuch/n1\n'
  printf 'cat /notes/work/n%s\n' "$TAB"
  printf 'cat /work/n%s%s%s\n' "$TAB" "$TAB" "$CU"
  printf 'echo more >> /work/n1; tags n1\n'
  printf 'cat /notes/n%s%s%s\n' "$TAB" "$TAB" "$CU"
  printf 'untag n3 work; untag n1 work; ls /work\n'
  printf 'tags | grep notes\n'
  printf 'tag n1 a/b; tag nosuch x; untag; tags nosuch\n'
  printf 'wc < /notes/n1 > /out/w1; ls -t /out; cat /out/w1\n'
  printf 'rm /notes/n1 /notes/n2 n3 /out/w1; ls /notes; tags | grep notes\n'
  # file utilities: facets (tags as subdirectories), exclusion, tag completion,
  # cp, mv, touch, retag
  printf 'echo one > /proj/p1; echo two > /proj/todo/p2; touch /proj/done/p3\n'
  printf 'ls /proj; ls /proj/-done/-todo; ls /proj/todo/-done; ls /proj/-nosuch/p1\n'
  printf 'ls -t /-proj/-bin/-src/-sys/-demo/-ws/-forth\n'
  printf 'cat /proj%sp2\n' "$TAB"
  printf 'cat /proj/t%s%s\n' "$TAB" "$TAB"
  printf 'ls /proj/%s%s%s\n' "$TAB" "$TAB" "$CU"
  printf 'cp /proj/p1 /copy/p4; cp -t p2 /copy/p5; ls -t /copy; cat p4 p5\n'
  printf 'cp p1 /copy/p1; cp nosuch p6; cp p1; cp /todo/p1 p6\n'
  printf 'mv p4 /done/; echo old > p6; mv p5 p6; ls -t /done; tags p6; cat p6\n'
  printf 'mv nosuch p7; mv p6 /a/-b/p7; mv p6 0123456789012345678901234; mv p6\n'
  printf 'touch p1 /proj/p8 /proj/-done/p9 0123456789012345678901234; ls -t /proj; cat p1\n'
  printf 'touch /extra/p2; tags p2; cat p2\n'
  printf 'retag p6 x y; tags p6; retag p6 y; tags p6; retag p6; tags p6; retag nosuch\n'
  printf 'rm p1 p2 p3 p4 p6 p8; ls /proj\n'
  printf 'rm f1 f2 f3 s1 tfile\n'
  printf 'exit 3 &\n'
  printf 'wait\n'
  # Ctrl-D on an empty line ends the login shell: the machine halts
  printf 'echo bye\n%s' "$CD"
} >"$tmp/in.txt"
cp "$2" "$tmp/d.img"
"$b/strata-emu" -c "$n" -j -T virtual -g none -m 2000000000 -d "$tmp/d.img" -i "$tmp/in.txt" "$1" >"$tmp/raw.out" 2>/dev/null
# from the first prompt on; job pids and times normalised; control bytes visible
awk 'f || /^strata\$ /{f=1; print}' "$tmp/raw.out" |
  sed -E -e 's/^(\[[0-9]+\]) [0-9]+$/\1 PID/' -e 's/^(\[[0-9]+\]) [0-9]+  /\1 PID  /' \
         -e 's/time: [0-9]+\.[0-9]+ s/time: T s/' -e 's/^(sourced) [0-9]+$/\1 PID/' | cat -v >"$tmp/out.txt"
if [ $upd -eq 1 ]; then cp "$tmp/out.txt" "$here/tools/test-sh.out"; echo "tools/test-sh.out updated"; exit 0; fi
if cmp -s "$tmp/out.txt" "$here/tools/test-sh.out"; then
  printf '%-14s OK    line editing, history, completion, syntax, jobs, tags, file utilities\n' shell; exit 0
fi
printf '%-14s FAIL\n' shell; diff "$here/tools/test-sh.out" "$tmp/out.txt" | head -40; exit 1
