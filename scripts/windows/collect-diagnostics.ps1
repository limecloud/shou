param(
    [Parameter(Mandatory)][string]$OutputRoot,
    [string]$TestResultsRoot,
    [string]$PublishRoot,
    [string]$DiagnosticsRoot = $(if ($env:SHOU_DIAGNOSTICS_DIR) { $env:SHOU_DIAGNOSTICS_DIR } else { Join-Path $env:LOCALAPPDATA 'Shou/Diagnostics' })
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$null = New-Item -ItemType Directory -Path $OutputRoot -Force
$OutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
$ShouCopied = [Collections.Generic.List[object]]::new()
$ShouMissing = [Collections.Generic.List[string]]::new()
function Copy-Evidence([string]$Path, [string]$Relative, [long]$MaximumBytes) {
    $Info = Get-Item -LiteralPath $Path
    if (($Info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $Info.Length -gt $MaximumBytes) { throw "Unbounded or redirected evidence file: $Relative" }
    $Destination = Join-Path $OutputRoot $Relative
    $null = New-Item -ItemType Directory -Path (Split-Path $Destination -Parent) -Force
    Copy-Item -LiteralPath $Path -Destination $Destination
    $ShouCopied.Add([ordered]@{ path = $Relative; bytes = $Info.Length; sha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash })
}
$ShouTrx = [Collections.Generic.List[object]]::new()
if ($TestResultsRoot -and (Test-Path -LiteralPath $TestResultsRoot)) {
    $Reports = @(Get-ChildItem -LiteralPath $TestResultsRoot -Filter '*.trx' -File -Recurse)
    if ($Reports.Count -gt 100) { throw 'Too many TRX files; choose the current run result directory.' }
    foreach ($Report in $Reports) {
        [xml]$Xml = Get-Content -LiteralPath $Report.FullName -Raw
        $Counters = $Xml.SelectSingleNode("//*[local-name()='ResultSummary']/*[local-name()='Counters']")
        if ($null -eq $Counters) { throw "TRX is missing result counters: $($Report.Name)" }
        $Values = [ordered]@{}
        foreach ($Attribute in $Counters.Attributes) { $Values[$Attribute.Name] = [int]$Attribute.Value }
        # VSTest/xUnit may report notExecuted=0 while individual results are
        # NotExecuted. Preserve both sources rather than treating skips as passes.
        $ResultCounts = [ordered]@{}
        foreach ($Result in $Xml.SelectNodes("//*[local-name()='UnitTestResult']")) {
            $Outcome = $Result.GetAttribute('outcome')
            if (-not $ResultCounts.Contains($Outcome)) { $ResultCounts[$Outcome] = 0 }
            $ResultCounts[$Outcome]++
        }
        $Index = $ShouTrx.Count
        $Relative = "tests/$Index-$($Report.Name)"
        Copy-Evidence $Report.FullName $Relative 33554432
        $ShouTrx.Add([ordered]@{ path = $Relative; counters = $Values; result_counts = $ResultCounts;
            outcome = $Xml.SelectSingleNode("//*[local-name()='ResultSummary']").GetAttribute('outcome') })
    }
    if ($Reports.Count -eq 0) { $ShouMissing.Add('TRX results') }
} else { $ShouMissing.Add('test results directory') }
foreach ($Name in @('application.jsonl', 'application.jsonl.previous')) {
    $Path = Join-Path $DiagnosticsRoot $Name
    if (Test-Path -LiteralPath $Path) { Copy-Evidence $Path "diagnostics/$Name" 1048576 }
    elseif ($Name -eq 'application.jsonl') { $ShouMissing.Add('application diagnostics') }
}
$ShouPayload = @()
if ($PublishRoot -and (Test-Path -LiteralPath $PublishRoot)) {
    $ResolvedPublish = (Resolve-Path -LiteralPath $PublishRoot).Path.TrimEnd('\', '/')
    $Files = @(Get-ChildItem -LiteralPath $ResolvedPublish -File -Recurse)
    if ($Files.Count -gt 5000) { throw 'Publish directory exceeds the manifest file budget.' }
    $ShouPayload = @($Files | ForEach-Object { [ordered]@{
        path = $_.FullName.Substring($ResolvedPublish.Length + 1).Replace('\', '/');
        bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    } })
} else { $ShouMissing.Add('publish directory') }
[ordered]@{
    schema_version = 1; captured_utc = [DateTime]::UtcNow.ToString('o');
    os = [Environment]::OSVersion.VersionString; process_architecture = $env:PROCESSOR_ARCHITECTURE;
    powershell = $PSVersionTable.PSVersion.ToString(); interactive = [Environment]::UserInteractive;
    volumes = @(Get-PSDrive -PSProvider FileSystem | Select-Object Name, Used, Free);
    tests = @($ShouTrx.ToArray()); artifacts = @($ShouCopied.ToArray()); payload = $ShouPayload;
    missing = @($ShouMissing.ToArray());
    acceptance = 'Evidence collection is not a test pass. Assess failures, skips and E2E receipts separately.'
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputRoot 'diagnostics-manifest.json') -Encoding UTF8
Write-Output "Diagnostic evidence: $OutputRoot"
