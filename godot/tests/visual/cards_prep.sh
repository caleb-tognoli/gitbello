#!/bin/sh
# Builds the throwaway repository card_screenshots.tscn expects in the new
# directory $1: a commit that renames `docs/guide.md` to `docs/manual.md`
# without edits, one that only makes `run.sh` executable, then a merge of
# `feat` left in conflict: `gone.txt` deleted on main and changed on feat,
# `moved.txt` renamed to `ours.txt` on main and to `theirs.txt` on feat.
set -e
repo="$1"
mkdir -p "$repo"
cd "$repo"
git init -q -b main
git config user.name "Fixture"
git config user.email "fixture@example.com"
git config core.autocrlf false
git config core.filemode false
mkdir -p docs
seq 1 40 > docs/guide.md
printf '#!/bin/sh\necho run\n' > run.sh
seq 1 30 > gone.txt
seq 1 12 > moved.txt
git add .
git commit -qm "Add files"
git mv docs/guide.md docs/manual.md
git commit -qm "Rename the guide"
git update-index --chmod=+x run.sh
git commit -qm "Make run.sh executable"
git branch feat
git rm -q gone.txt
git mv moved.txt ours.txt
git commit -qm "Delete gone.txt, rename moved.txt"
git checkout -q feat
sed -i 's/^15$/fifteen/' gone.txt
git commit -qam "Edit gone.txt"
git mv moved.txt theirs.txt
git commit -qm "Rename moved.txt"
git checkout -q main
git merge feat > /dev/null 2>&1 || true
git status --short
