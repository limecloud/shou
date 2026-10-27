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
python3 "scripts/generate-windows-resources.py" --check
python3 "tests/design/test-design-tokens.py"
python3 "tests/test-update-notes.py"
python3 "scripts/verify-rule-catalog.py" --self-test
python3 "scripts/verify-docs.py"
swift build --jobs 4
python3 "scripts/verify-products.py"
".build/debug/shou-tests" "$TASK_NATIVE_MODE"
python3 "scripts/verify-cli.py"
python3 "scripts/verify-cli-support.py"
python3 "scripts/verify-application-updates-cli.py"
python3 "scripts/verify-tool-cleanup.py" --engine ".build/debug/shou"
python3 "scripts/verify-storage-cli.py"
python3 "scripts/verify-ai-investigation.py"
python3 "scripts/verify-large-files-cli.py" ".build/debug/shou"
python3 "scripts/verify-cli-install.py"
python3 "apps/cli/Tests/verify-confirmation.py"
python3 "scripts/verify-uninstall-cli.py"
python3 "scripts/verify-application-batch-cli.py" ".build/debug/shou"
python3 "scripts/verify-privacy-cli.py" ".build/debug/shou"
if [ "$TASK_NATIVE_MODE" = --native-trash-purge ]; then
    python3 "scripts/verify-installed-cache-cli.py" ".build/debug/shou" --permanent
    python3 "scripts/verify-native-cli.py" --native-trash-purge
else
    python3 "scripts/verify-installed-cache-cli.py" ".build/debug/shou"
    python3 "scripts/verify-native-cli.py"
fi
