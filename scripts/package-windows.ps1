param(
    [Parameter(Mandatory = $true)][string]$EngineExecutable,
    [Parameter(Mandatory = $true)][string[]]$SwiftRuntimeDirectory,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$RuntimeLicenseDirectory
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "Run packaging in PowerShell 7 on Windows x64." }
$repo = Split-Path -Parent $PSScriptRoot
$version = ([xml](Get-Content -LiteralPath (Join-Path $repo "apps/windows/Directory.Build.props") -Raw)).Project.PropertyGroup.Version
$engine = Get-Item -LiteralPath $EngineExecutable
if ($engine.Name -ne "shou.exe") { throw "Select the Windows shou.exe built from this repository." }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Output already exists; select a new directory. Existing artifacts are preserved." }
$runtimeRoots = @($engine.DirectoryName) + @($SwiftRuntimeDirectory | ForEach-Object { (Get-Item -LiteralPath $_).FullName })
$inspector = (Get-Command llvm-readobj -ErrorAction Stop).Source
Push-Location (Join-Path $repo "apps/windows")
try {
    dotnet publish "Shou.Windows/Shou.Windows.csproj" -c Release -r win-x64 --self-contained true -o $output --nologo
    if ($LASTEXITCODE -ne 0) { throw "WPF publish failed." }
} finally { Pop-Location }
$engineOutput = Join-Path $output "Engine"
New-Item -ItemType Directory -Path $engineOutput | Out-Null
Copy-Item -LiteralPath $engine.FullName -Destination $engineOutput
$resources = @(Get-ChildItem -LiteralPath $engine.DirectoryName -Directory | Where-Object { $_.Name -match '\.(resources|bundle)$' })
if ($resources.Count -lt 3) { throw "Missing SwiftPM core, contracts or bundled Skill resources." }
$resources | Copy-Item -Destination $engineOutput -Recurse

# Resolve the PE import closure from declared runtime roots. Never silently
# depend on the developer's PATH for Swift or VC runtime dependencies.
$pending = [Collections.Generic.Queue[string]]::new()
$pending.Enqueue((Join-Path $engineOutput "shou.exe"))
$visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
while ($pending.Count -gt 0) {
    $binary = $pending.Dequeue()
    if (-not $visited.Add([IO.Path]::GetFileName($binary))) { continue }
    $imports = & $inspector --coff-imports $binary
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect PE dependencies: $binary" }
    foreach ($line in $imports) {
        if ($line -notmatch '^\s*Name:\s*(\S+\.dll)\s*$') { continue }
        $name = $Matches[1]
        if ($visited.Contains($name)) { continue }
        $source = $null
        foreach ($root in $runtimeRoots) {
            $candidate = Join-Path $root $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $source = $candidate; break }
        }
        if ($source) {
            $destination = Join-Path $engineOutput $name
            Copy-Item -LiteralPath $source -Destination $destination -Force
            $pending.Enqueue($destination)
        } elseif ($name -match '^(api-ms-win-|ext-ms-win-)' -or (Test-Path -LiteralPath (Join-Path ([Environment]::SystemDirectory) $name))) {
            # OS components, including Windows SQLite, are supplied by Windows 11.
            if ($name -match '^(swift|Foundation|dispatch|BlocksRuntime|vcruntime|msvcp)') { throw "Declare the redistributable runtime root for $name" }
        } else { throw "Missing runtime dependency $name; provide its official redistributable directory." }
    }
}
Copy-Item -LiteralPath (Join-Path $repo "LICENSE") -Destination $output
Copy-Item -LiteralPath (Join-Path $repo "apps/windows/README.md") -Destination $output
if ($RuntimeLicenseDirectory) {
    Copy-Item -LiteralPath $RuntimeLicenseDirectory -Destination (Join-Path $output "Licenses") -Recurse
}
@"
Shou $version for Windows 11 x64. Extract the entire ZIP, then start Shou.exe.
.NET and the resolved Swift/VC runtime dependencies are bundled. Windows 11 supplies winsqlite3.
Recycle Bin and restoration are disabled by default; permanent removal is enabled with explicit scope confirmation and cannot be undone.
AppData standard cache roots remain protected and unavailable. The interface is Simplified Chinese.
This portable application is unsigned, with no installer or automatic Windows update. It runs without administrator access.
Keep the Engine directory and resource bundles beside the application. See Licenses for bundled runtime notices.
"@ | Set-Content -LiteralPath (Join-Path $output "READ-FIRST.txt") -Encoding utf8

$start = [Diagnostics.ProcessStartInfo]::new((Join-Path $engineOutput "shou.exe"))
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.ArgumentList.Add("capabilities"); $start.ArgumentList.Add("--json")
$start.Environment["PATH"] = $engineOutput + ";" + [Environment]::SystemDirectory
$probe = [Diagnostics.Process]::Start($start)
$stdout = $probe.StandardOutput.ReadToEndAsync(); $stderr = $probe.StandardError.ReadToEndAsync()
if (-not $probe.WaitForExit(30000)) { $probe.Kill($true); throw "Packaged engine discovery timed out." }
$contract = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json
if ($probe.ExitCode -ne 0 -or -not $contract.ok -or $contract.data.platform -ne "windows" -or $contract.data.application_version -ne $version) { throw "Packaged engine failed version/platform validation with a restricted runtime search path: $($stderr.GetAwaiter().GetResult())" }
$manifest = Get-ChildItem -LiteralPath $output -File -Recurse | ForEach-Object {
    [ordered]@{ path = [IO.Path]::GetRelativePath($output, $_.FullName).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
ConvertTo-Json -InputObject @($manifest) -Depth 4 | Set-Content -LiteralPath (Join-Path $output "files.sha256.json") -Encoding utf8
Write-Output "Windows $version portable package created: $output. Native UI, clean installation, signing and upgrades retain separate acceptance limits."
