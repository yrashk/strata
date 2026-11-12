#!/bin/sh
# web-stamp.sh DIR STAMP: stamp the play page's asset URLs with a build id
# (the commit), so that a browser never pairs files of two deploys (GitHub
# Pages lets browsers cache everything for 10 minutes; an old play.js with
# a new page, or an old .wasm with a new .js, fails in odd ways).
# play.js, worker.js and index.html carry the placeholder __BUILD__, and so
# do the Forth section's page and playground (forth/), which run the play
# page's worker and module, and the debugger's page (debug/), which runs the
# module in a worker of its own.
set -e
DIR=$1
STAMP=$2
# Every page links the shared highlighter as hl.js?v=__BUILD__ / hl.css?v=__BUILD__
# too (the site's host caches plain URLs for hours), so all pages are stamped.
for f in $(find "$DIR" -name '*.html') "$DIR/play/play.js" "$DIR/play/worker.js" \
         "$DIR/forth/forth.js" "$DIR/debug/debug.js"; do
  [ -f "$f" ] || continue
  grep -q __BUILD__ "$f" || continue
  sed "s/__BUILD__/$STAMP/g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
