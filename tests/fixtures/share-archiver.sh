#!/bin/sh
# Usage: share-archiver.sh URL  → a page, and on stderr the Reddit post the
# share link led to, as the browser archiver reports it.
echo "<html><head><title>A post</title></head><body>shared post</body></html>"
echo "vinboard-final-url: https://www.reddit.com/r/test/comments/1abc/a_post/?share_id=x&utm_medium=ios_app" >&2
