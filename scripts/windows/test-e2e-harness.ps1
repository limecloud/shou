param([string]$ArtifactsRoot = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Exercise the production diagnostic checks without loading Windows UI Automation
# or executing the desktop runner's fixture mutations.
$Tokens = $null
$Errors = $null
$Ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'test-desktop-e2e.ps1'), [ref]$Tokens, [ref]$Errors)
if ($Errors.Count) { throw ($Errors | Out-String) }
foreach ($Name in @('Assert-That', 'Test-ExpectedCliRejection', 'Run-Cli')) {
    $Function = $Ast.Find({ param($Node)
        $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name
    }, $true)
    if ($null -eq $Function) { throw "Missing production harness function: $Name" }
    Invoke-Expression $Function.Extent.Text
}

$Expected = [ordered]@{
    command = 'generated-rejection'; operation_id = '0123456789abcdef0123456789abcdef'; code = 'confirmation_required'
}
$Cases = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw $Name }
    $Cases.Add($Name)
}
function New-Event([string]$Code = 'confirmation_required', [string]$Parent = $Expected.operation_id,
    [string]$Operation = 'application.exception', [string]$Kind = 'failed') {
    [ordered]@{ event = $Kind; operation = $Operation; code = $Code; parent_id = $Parent }
}
function Rejects([scriptblock]$Action, [string]$Message) {
    $Rejected = $false
    try { $null = & $Action } catch { $Rejected = $true }
    Check $Rejected $Message
}
function Invoke-HarnessFixtureCli {
    $script:LASTEXITCODE = $script:HarnessExit
    $script:HarnessEnvelope | ConvertTo-Json -Compress
}

Check (Test-ExpectedCliRejection (New-Event) @($Expected)) 'Exact request and error match'
Check (-not (Test-ExpectedCliRejection (New-Event -Parent 'another-request') @($Expected))) 'Same code from another request is rejected'
Check (-not (Test-ExpectedCliRejection (New-Event -Code 'plan_consumed') @($Expected))) 'Another code from the expected request is rejected'
Check (-not (Test-ExpectedCliRejection (New-Event -Operation 'ui.cleanup') @($Expected))) 'UI failures cannot be treated as CLI rejections'
Check (-not (Test-ExpectedCliRejection (New-Event -Kind 'completed') @($Expected))) 'Completed events are not rejection evidence'
Check (-not (Test-ExpectedCliRejection (New-Event -Code 'unsupported_capability') @())) 'Unsupported capability has no blanket exemption'

$ShouRun = Join-Path $ArtifactsRoot ('e2e-harness-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $ShouRun
$SavedDiagnostics = [Environment]::GetEnvironmentVariable('SHOU_DIAGNOSTICS_DIR', 'Process')
try {
    $env:SHOU_DIAGNOSTICS_DIR = $ShouRun
    $ShouExpectedRejections = [Collections.Generic.List[object]]::new()
    $ShouCli = 'Invoke-HarnessFixtureCli'
    $script:HarnessExit = 7
    $script:HarnessEnvelope = [ordered]@{
        api_version = '1.0'; request_id = 'request_' + $Expected.operation_id; error = @{ code = $Expected.code }
    }
    $Log = Join-Path $ShouRun 'application.jsonl'
    [IO.File]::WriteAllText($Log, ((New-Event) | ConvertTo-Json -Compress))
    $Result = Run-Cli 'expected' @('plan', 'execute') @(7) 'confirmation_required'
    Check ($Result.request_id -eq $script:HarnessEnvelope.request_id -and $ShouExpectedRejections.Count -eq 1) 'Validated CLI rejection is registered'
    Check (Test-Path -LiteralPath (Join-Path $ShouRun 'expected.diagnostics.json')) 'Correlated diagnostics are retained separately'

    [IO.File]::WriteAllText($Log, '')
    Rejects { Run-Cli 'missing-diagnostic' @('plan') @(7) 'confirmation_required' } 'Missing diagnostics cannot satisfy a rejection'
    $Duplicate = (New-Event) | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($Log, "$Duplicate`n$Duplicate")
    Rejects { Run-Cli 'duplicate-diagnostic' @('plan') @(7) 'confirmation_required' } 'Duplicate rejection evidence is rejected'
    [IO.File]::WriteAllText($Log, ((New-Event -Parent 'wrong-root') | ConvertTo-Json -Compress))
    Rejects { Run-Cli 'wrong-root' @('plan') @(7) 'confirmation_required' } 'Unrelated diagnostics cannot satisfy a rejection'
    [IO.File]::WriteAllText($Log, ((New-Event) | ConvertTo-Json -Compress))
    $script:HarnessEnvelope.error.code = 'unexpected_error'
    Rejects { Run-Cli 'wrong-code' @('plan') @(7) 'confirmation_required' } 'Matching exit code cannot hide another error'
    $script:HarnessEnvelope.error.code = 'confirmation_required'
    $script:HarnessEnvelope.request_id = 'request_invalid'
    Rejects { Run-Cli 'wrong-id' @('plan') @(7) 'confirmation_required' } 'Malformed request IDs are rejected'
    $script:HarnessEnvelope.request_id = 'request_' + $Expected.operation_id
    $script:HarnessExit = 0
    Rejects { Run-Cli 'wrong-exit' @('plan') @(0, 7) 'confirmation_required' } 'Success cannot satisfy an expected rejection'
    Check ($ShouExpectedRejections.Count -eq 1) 'Invalid rejections never enter the accepted list'
    $script:HarnessEnvelope = [ordered]@{ api_version = '1.0'; request_id = 'request_' + $Expected.operation_id; data = @{ fixture = $true } }
    $Result = Run-Cli 'ordinary-success' @('fixture')
    Check ($Result.data.fixture -and $ShouExpectedRejections.Count -eq 1) 'Ordinary success needs no rejection exemption'

    [ordered]@{
        schema_version = 1; at_utc = [DateTimeOffset]::UtcNow.ToString('o'); outcome = 'passed'
        cases_passed = $Cases.Count; cases = @($Cases.ToArray()); native_windows_e2e_run = $false
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ShouRun 'verification.json') -Encoding UTF8
    Write-Output "Desktop E2E harness: $($Cases.Count) checks passed. Evidence: $ShouRun"
} finally {
    # The environment provider removes an absent value; a string-parameter call
    # can turn PowerShell null into an invalid empty override on current .NET.
    $env:SHOU_DIAGNOSTICS_DIR = $SavedDiagnostics
}
