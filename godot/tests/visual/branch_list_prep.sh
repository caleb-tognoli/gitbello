#!/bin/sh
# Prepares a CLI fixture repo-1 for branch_list_screenshots.tscn: eight local
# branches with prefixes (one with a long name), a checkout history so Recent
# has an order (fix/crash last, then docs/readme, chore/deps), `docs/readme`
# pushed with tracking and `zeta` without, and remote-only branches
# (`origin/teammate/spike`, `origin/release/2.0`).
# Ends on main. Throwaway fixtures only.
# usage: branch_list_prep.sh <fixture dir>
set -e
dir="$1"
repo="$dir/repo-1"
export GIT_CONFIG_GLOBAL="$dir/global.gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com
g() { git -C "$repo" -c commit.gpgsign=false "$@"; }
# No local changes, so choosing a branch checks it out without asking.
g checkout --quiet -- app.txt
rm -f "$repo/notes.txt"
tree=$(g rev-parse 'main^{tree}')
for b in chore/deps docs/readme fix/crash old-experiment zeta \
	feature/settings-page-with-a-much-longer-descriptive-name-than-fits; do
	g branch "$b" main
done
spike=$(echo "Spike" | g commit-tree "$tree" -p main)
g push --quiet origin "$spike:refs/heads/teammate/spike" "$spike:refs/heads/release/2.0"
# Pushed with tracking: hidden from Remote. Pushed without: still listed.
g push --quiet -u origin docs/readme
g push --quiet origin zeta
g fetch --quiet origin
# The checkout history, oldest first (the clock moves between them).
n=1700001000
for b in chore/deps docs/readme main fix/crash main; do
	n=$((n + 60))
	GIT_COMMITTER_DATE="$n +0000" g switch --quiet "$b"
done
g branch -vv
