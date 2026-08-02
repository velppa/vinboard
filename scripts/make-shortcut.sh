#!/bin/sh
# Emit a signed vinboard share-sheet shortcut to stdout.
# $1 = api credential "handle:TOKEN", substituted into the template.
set -e
dir=$(dirname "$0")
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
sed "s/__VINBOARD_AUTH__/$1/" "$dir/shortcut-template.xml" > "$t/in.shortcut"
shortcuts sign -m anyone -i "$t/in.shortcut" -o "$t/out.shortcut" 1>&2
cat "$t/out.shortcut"
