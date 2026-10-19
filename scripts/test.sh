#!/bin/sh
set -eu
TASK_NATIVE_MODE=--native-trash
if [ "$#" -eq 1 ]; then TASK_NATIVE_MODE="$1"; fi
if [ "$#" -gt 1 ]; then
    echo "Usage: scripts/test.sh [--native-trash|--native-trash-purge]" >&2
    exit 2
fi
case "$TASK_NATIVE_MODE" in
    --native-trash|--native-trash-purge) ;;
    *) echo "Usage: scripts/test.sh [--native-trash|--native-trash-purge]" >&2; exit 2 ;;
esac
TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$TASK_ROOT"
python3 "scripts/update-localizations.py" --check
python3 "scripts/verify-docs.py"
swift build --jobs 4
python3 "scripts/verify-products.py"
".build/debug/shou-tests" "$TASK_NATIVE_MODE"
python3 "scripts/verify-cli.py"
python3 "apps/cli/Tests/verify-confirmation.py"
if [ "$TASK_NATIVE_MODE" = --native-trash-purge ]; then
    python3 "scripts/verify-native-cli.py" --native-trash-purge
else
    python3 "scripts/verify-native-cli.py"
fi
