#!/usr/bin/env bash
# Adds the shelves `options_app_screenshots.tscn` shows in the shelves'
# branch filter to the history repo of a throwaway CLI fixture: one on the
# current branch and one each on `spike` and a long branch name. The
# repository's own uncommitted changes stay as they are.
#
#   tests/visual/options_app_prep.sh <fixture dir>/history
#
# Only ever point it at a fixture made by `gitbello-cli fixture`.
set -euo pipefail

repo="${1:?usage: options_app_prep.sh <fixture dir>/history}"
cd "$repo"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com
home="$(git symbolic-ref --short HEAD)"

# Shelves only the named new file, leaving the other changes in place.
shelve() {
	echo "$2" > "$1"
	git stash push -q -u -m "$2" -- "$1"
}

shelve notes.txt "Release notes draft"
for branch in spike feature/rate-limiting-and-retry-backoff; do
	git checkout -q -b "$branch"
	shelve "$(basename "$branch").txt" "Work on $branch"
	git checkout -q "$home"
done
git stash list
