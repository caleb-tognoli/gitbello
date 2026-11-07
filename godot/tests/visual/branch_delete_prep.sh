#!/bin/sh
# Prepares a CLI fixture repo-1 for branch_delete_screenshots.tscn: pushed
# branches (merged `done` and `light`, unmerged `wip` with one commit not
# pushed, `old` on the remote only), the current branch `cur`, the worktree
# branch feature/login pushed, a worktree `task` on a pushed merged branch,
# and the tag v1.0 pushed. Throwaway fixtures only.
# usage: branch_delete_prep.sh <fixture dir>
set -e
dir="$1"
repo="$dir/repo-1"
export GIT_CONFIG_GLOBAL="$dir/global.gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com
g() { git -C "$repo" -c commit.gpgsign=false "$@"; }
tree=$(g rev-parse 'main^{tree}')
g branch done main
g branch light main
wip1=$(echo "WIP: first step" | g commit-tree "$tree" -p main)
g branch wip "$wip1"
old=$(echo "Old experiment" | g commit-tree "$tree" -p main)
g push --quiet origin "$old:refs/heads/old"
g push --quiet -u origin done light wip feature/login v1.0
wip2=$(echo "WIP: second step" | g commit-tree "$tree" -p "$wip1")
g update-ref refs/heads/wip "$wip2"
g worktree add --quiet --no-track "$dir/repo-1-task" -b task origin/main
g push --quiet -u origin task
g switch --quiet -c cur
g push --quiet -u origin cur
g fetch --quiet origin
g branch -vv
