#!/usr/bin/env bash
# Builds the repository `merge_screenshots.tscn` captures: `main` with
# branches `topic` (two conflicting blocks in app.txt, plus a new file),
# `clean` (changes README.md's first line), `ahead` (main plus commits: a
# fast-forward), `long` (dozens of commits ahead, for the scrolling list),
# `feature` (its own commits, one pushed to `origin`, and a merge: a clean
# rebase) and `rework` (a commit that conflicts with main when rebased), plus
# topic under a long name, by a few people. `origin` is a bare repository inside `.git`.
#
#   tests/visual/merge_prep.sh <new directory>
#
# The directory must not exist: the script only ever writes inside it.
set -euo pipefail

repo="${1:?usage: merge_prep.sh <new directory>}"
if [ -e "$repo" ]; then
	echo "merge_prep: $repo exists; pass a new directory" >&2
	exit 2
fi
mkdir -p "$repo"
cd "$repo"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q -b main .
git config commit.gpgsign false
git config user.name "Ada Lovelace"
git config user.email "ada@example.com"

day=0
# commit <author> <email> <subject>
commit() {
	day=$((day + 1))
	local date="2026-10-$(printf '%02d' $(( (day % 28) + 1 )))T10:00:00"
	git add -A
	GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" GIT_AUTHOR_DATE="$date" \
	GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="$2" GIT_COMMITTER_DATE="$date" \
		git commit -q -m "$3"
}

printf 'gitbello demo\n\nA small service.\n' > README.md
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\n' > app.txt
commit "Ada Lovelace" ada@example.com "Start the service"

git branch topic
git branch clean
git branch long
git branch feature
git branch rework

printf 'one\nours two\nthree\nfour\nfive\nours six\nseven\n' > app.txt
commit "Ada Lovelace" ada@example.com "Tune the defaults on main"
git branch ahead

git checkout -q topic
printf 'one\ntheir two\nthree\nfour\nfive\ntheir six\nseven\n' > app.txt
commit "Grace Hopper" grace@example.com "Rework the defaults"
printf 'topic\n' > topic.txt
commit "Linus Pauling" linus@example.com "Add the topic notes"

git checkout -q clean
printf 'gitbello demo service\n\nA small service.\n' > README.md
commit "Grace Hopper" grace@example.com "Name the service in the README"

git checkout -q ahead
for i in 1 2 3; do
	printf 'step %s\n' "$i" >> steps.txt
	commit "Linus Pauling" linus@example.com "Add step $i"
done

git checkout -q long
for i in $(seq 1 40); do
	printf 'entry %s\n' "$i" >> log.txt
	commit "Grace Hopper" grace@example.com "Log entry $i of the long branch"
done

git checkout -q feature
printf 'notes\n' > notes.md
commit "Ada Lovelace" ada@example.com "Start the feature notes"
git init -q --bare .git/origin.git
git remote add origin .git/origin.git
git push -q origin feature
git branch -q --set-upstream-to=origin/feature
git checkout -q -b feature-part
printf 'part\n' > part.md
commit "Grace Hopper" grace@example.com "Draft a part of the feature"
git checkout -q feature
printf 'notes\nmore notes\n' > notes.md
commit "Ada Lovelace" ada@example.com "Extend the feature notes"
GIT_AUTHOR_DATE="2026-10-20T10:00:00" GIT_COMMITTER_DATE="2026-10-20T10:00:00" git merge -q --no-ff --no-edit feature-part
git branch -q -D feature-part

git checkout -q rework
printf 'one\nreworked two\nthree\nfour\nfive\nsix\nseven\n' > app.txt
commit "Linus Pauling" linus@example.com "Rework the second default"
printf 'rework\n' > rework.txt
commit "Linus Pauling" linus@example.com "Note the rework"

# The same commit as topic under a long name, for the wrapping first row.
git branch "defaults/rework-the-service-defaults-so-new-people-can-run-it" topic

git checkout -q main
