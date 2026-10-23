#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    echo "Usage: sh scripts/build-windows-cli.sh win-x64|win-arm64" >&2
    exit 2
fi
case "$1" in
    win-x64|win-arm64) SHOU_TASK_RUNTIME=$1 ;;
    *) echo "Choose win-x64 or win-arm64." >&2; exit 2 ;;
esac
SHOU_TASK_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SHOU_TASK_DOTNET=${SHOU_DOTNET:-dotnet}
if ! command -v "$SHOU_TASK_DOTNET" >/dev/null 2>&1; then
    SHOU_TASK_DOTNET="$SHOU_TASK_ROOT/.build/toolchains/dotnet/dotnet"
fi
if [ ! -x "$SHOU_TASK_DOTNET" ] && ! command -v "$SHOU_TASK_DOTNET" >/dev/null 2>&1; then
    echo "Install the .NET SDK pinned by apps/windows/global.json, or set SHOU_DOTNET." >&2
    exit 2
fi
python3 "$SHOU_TASK_ROOT/scripts/generate-windows-resources.py" --check
SHOU_TASK_ARTIFACTS="$SHOU_TASK_ROOT/.build/windows/native/$SHOU_TASK_RUNTIME"
SHOU_TASK_OUTPUT="$SHOU_TASK_ROOT/.build/windows/publish/$SHOU_TASK_RUNTIME/cli"
cd "$SHOU_TASK_ROOT/apps/windows"
# restore --runtime replaces the shared RID list; RuntimeIdentifier retains both locked targets.
"$SHOU_TASK_DOTNET" restore "src/Shou.Windows.Cli/Shou.Windows.Cli.csproj" "-p:RuntimeIdentifier=$SHOU_TASK_RUNTIME" --locked-mode "-p:ArtifactsPath=$SHOU_TASK_ARTIFACTS"
"$SHOU_TASK_DOTNET" publish "src/Shou.Windows.Cli/Shou.Windows.Cli.csproj" -c Release -r "$SHOU_TASK_RUNTIME" --self-contained true --no-restore "-p:ArtifactsPath=$SHOU_TASK_ARTIFACTS" -o "$SHOU_TASK_OUTPUT"
python3 "$SHOU_TASK_ROOT/scripts/prepare-windows-cli-notices.py" --payload "$SHOU_TASK_OUTPUT" --assets "$SHOU_TASK_ARTIFACTS/obj/Shou.Windows.Cli/project.assets.json"
echo "Unsigned development CLI: $SHOU_TASK_OUTPUT"
echo "Run and verify on the matching Windows architecture before distribution."
