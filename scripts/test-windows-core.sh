#!/bin/sh
set -eu
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
cd "$SHOU_TASK_ROOT/apps/windows"
"$SHOU_TASK_DOTNET" test "tests/Shou.Windows.Core.Tests/Shou.Windows.Core.Tests.csproj" -c Release -p:RestoreLockedMode=true
"$SHOU_TASK_DOTNET" test "tests/Shou.Windows.Presentation.Tests/Shou.Windows.Presentation.Tests.csproj" -c Release -p:RestoreLockedMode=true
"$SHOU_TASK_DOTNET" build "src/Shou.Windows.Platform/Shou.Windows.Platform.csproj" -c Release -p:RestoreLockedMode=true
"$SHOU_TASK_DOTNET" test "tests/Shou.Windows.Platform.Tests/Shou.Windows.Platform.Tests.csproj" -c Release -p:RestoreLockedMode=true
"$SHOU_TASK_DOTNET" build "src/Shou.Windows.Cli/Shou.Windows.Cli.csproj" -c Release -p:RestoreLockedMode=true -p:SelfContained=false -p:UseAppHost=false
"$SHOU_TASK_DOTNET" test "tests/Shou.Windows.Cli.Tests/Shou.Windows.Cli.Tests.csproj" -c Release -p:RestoreLockedMode=true
cd "$SHOU_TASK_ROOT"
python3 "$SHOU_TASK_ROOT/scripts/verify-windows-cli-contract.py" --dotnet "$SHOU_TASK_DOTNET"
