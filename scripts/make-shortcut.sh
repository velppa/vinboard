#!/bin/sh
# Build a signed vinboard share-sheet shortcut.
# $1 = api credential "handle:TOKEN", substituted into the template.
# $2 = output path (atomic move); when omitted, bytes go to stdout.
set -e
dir=$(dirname "$0")
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
sed "s/__VINBOARD_AUTH__/$1/" "$dir/shortcut-template.xml" > "$t/in.shortcut"
shortcuts sign -m anyone -i "$t/in.shortcut" -o "$t/out.shortcut" 1>&2
if [ -n "$2" ]; then
    chmod 644 "$t/out.shortcut"
    mv "$t/out.shortcut" "$2"
else
    cat "$t/out.shortcut"
fi
