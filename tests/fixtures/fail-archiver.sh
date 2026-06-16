#!/bin/sh
# Usage: fail-archiver.sh URL  → writes some stdout then exits non-zero,
# exercising the archiver-failure path (must not double-free or leak).
echo "<html><body>partial output before failure</body></html>"
exit 1
