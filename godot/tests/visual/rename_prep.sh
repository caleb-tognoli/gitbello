#!/bin/sh
# Builds the throwaway repository rename_screenshots.tscn expects in the new
# directory $1: a commit that moves `src/util.rs` to `lib/core/util.rs` (with
# an edit), renames `docs/old.md` to `docs/new.md` in its folder and moves and
# renames `a/b/x.txt` to `c/y.txt`; then staged moves into deep folders and
# `guides/setup.md` moved to `docs/handbook/` and edited without `git mv`.
set -e
repo="$1"
mkdir -p "$repo"
cd "$repo"
git init -q
git config user.name "Fixture"
git config user.email "fixture@example.com"
git config core.autocrlf false
mkdir -p src docs a/b
seq 1 60 > src/util.rs
printf 'hello\n' > docs/old.md
seq 1 30 > a/b/x.txt
seq 1 40 > keep.txt
mkdir -p tools/scripts/build/release
seq 1 20 > tools/scripts/build/release/settings.json
mkdir -p guides
seq 1 50 > guides/setup.md
git add .
git commit -qm "Add files"
mkdir -p lib/core c
git mv src/util.rs lib/core/util.rs
sed -i 's/^30$/thirty/' lib/core/util.rs
git add lib/core/util.rs
git mv docs/old.md docs/new.md
git mv a/b/x.txt c/y.txt
git commit -qm "Move files"
mkdir -p packages/frontend/components/buttons
git mv keep.txt packages/frontend/components/buttons/primary_button.txt
mkdir -p packages/config/release
git mv tools/scripts/build/release/settings.json packages/config/release/settings.json
# Moved without git mv, then edited: git sees a deletion and a new file.
mkdir -p docs/handbook
mv guides/setup.md docs/handbook/setup.md
sed -i 's/^25$/twenty-five/' docs/handbook/setup.md
