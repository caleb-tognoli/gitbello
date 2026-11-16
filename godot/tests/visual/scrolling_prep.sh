#!/usr/bin/env bash
# Builds the repository `scrolling_screenshots.tscn` captures: 150 commits
# (one with a long message), a long README.md changed in many places, 60
# changed files and 10 worktrees with long folder names.
#
#   tests/visual/scrolling_prep.sh <new directory>
#
# The directory must not exist: the script only ever writes inside it (the
# repository is <dir>/shop, its worktrees <dir>/shop-*).
set -euo pipefail

dir="${1:?usage: scrolling_prep.sh <new directory>}"
if [ -e "$dir" ]; then
	echo "scrolling_prep: $dir exists; pass a new directory" >&2
	exit 2
fi
repo="$dir/shop"
mkdir -p "$repo/src"
cd "$repo"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Ada Example" GIT_AUTHOR_EMAIL="ada@example.com"
export GIT_COMMITTER_NAME="Ada Example" GIT_COMMITTER_EMAIL="ada@example.com"
git init -q -b main .
git config commit.gpgsign false

{
	echo "# Shop"
	for i in $(seq 1 40); do
		echo
		echo "## Section $i"
		echo
		echo "Paragraph $i explains part $i of the shop: what it does, how to run it and what to watch."
	done
} > README.md
for i in $(seq 1 60); do
	echo "module $i" > "src/module_$i.txt"
done
git add -A
git commit -q -m "Start the shop"

body=""
for i in $(seq 1 60); do
	body+="- Step $i of the migration: move table $i, check its rows and keep the old one for a week."$'\n'
done
for i in $(seq 1 149); do
	echo "change $i" >> "src/module_$(( (i % 60) + 1 )).txt"
	git add -A
	if [ "$i" -eq 145 ]; then
		git commit -q -m "Migrate the order tables" -m "$body"
	else
		git commit -q -m "Update module $(( (i % 60) + 1 )) ($i)"
	fi
done

# A long Markdown change and 60 changed files.
sed -i 's/^Paragraph \([0-9]*[05]\) explains/Paragraph \1 now explains/' README.md
for i in $(seq 1 60); do
	echo "edited" >> "src/module_$i.txt"
done

for name in checkout-redesign payment-retries invoice-export search-filters \
		cart-performance mobile-layout tax-rules order-history gift-cards admin-audit; do
	git worktree add -q -b "feature/$name" "../shop-$name"
done
echo "scrolling_prep: $repo"
