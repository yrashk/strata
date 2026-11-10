#!/bin/sh
# web-stamp.sh DIR STAMP: stamp the play page's asset URLs with a build id
# (the commit), so that a browser never pairs files of two deploys (GitHub
# Pages lets browsers cache everything for 10 minutes; an old play.js with
# a new page, or an old .wasm with a new .js, fails in odd ways).
# play.js, worker.js and index.html carry the placeholder __BUILD__, and so
# do the Forth section's page and playground (forth/), which run the play
# page's worker and module.
set -e
DIR=$1
STAMP=$2
for f in "$DIR/play/index.html" "$DIR/play/play.js" "$DIR/play/worker.js" \
         "$DIR/forth/index.html" "$DIR/forth/forth.js"; do
  [ -f "$f" ] || continue
  sed "s/__BUILD__/$STAMP/g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done
