#!/usr/bin/env bash
# Comment
set -euo pipefail

export NAME="world"
local_var='single quoted'

function greet() {
  local who="${1:-$NAME}"
  echo "Hello $who" # trailing
  return 0
}

if [ -f "$HOME/.bashrc" ]; then
  cd "$HOME" || exit 1
elif [[ $# -gt 2 ]]; then
  echo "args: $@"
fi

for f in *.txt; do
  case "$f" in
    a*) echo a ;;
    *) echo "other#notcomment" ;;
  esac
done
while read -r line; do echo "$line"; done < input.txt
count=$((count + 1))
echo "$(date +%s)"
cat <<EOF > out.txt
Hello $USER, today is $(date)
EOF
cat <<-'RAW'
	$NOT_EXPANDED
	RAW
echo "a string
over two lines" && echo done
