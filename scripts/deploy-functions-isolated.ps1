param(
  [string[]]$FunctionName,
  [string]$ConfirmDeploy,
  [string]$ConfirmFile,
  [string]$ConfirmImpact,
  [switch]$InteractiveConfirm,
  [string]$FinalAcknowledge,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$importScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\van2\scripts\deploy-governance-import.ps1'))
. $importScript -CallingScriptRoot $PSScriptRoot
$deployScript = Join-Path $PSScriptRoot 'deploy-isolated.ps1'

if (-not $FunctionName -or $FunctionName.Count -eq 0) {
  throw 'Functions deploy is locked to explicit function names.'
}
if (-not (Test-Path $deployScript)) {
  throw "Missing deploy script: $deployScript"
}

Assert-VanFunctionOwnership -App 'van1' -FunctionName $FunctionName
Invoke-VanDeployGuardSession -App 'van1' -ConfirmDeploy $ConfirmDeploy -ConfirmFile $ConfirmFile -ExpectedFile 'functions' -ConfirmImpact $ConfirmImpact -ExpectedImpact 'SELF:van1' -FinalAcknowledge $FinalAcknowledge -InteractiveConfirm:$InteractiveConfirm
Invoke-VanDeployPreflight -App 'van1' -Target 'functions'

& $deployScript -FunctionsOnly -FunctionName $FunctionName -ConfirmDeploy $ConfirmDeploy -ConfirmFile $ConfirmFile -ConfirmImpact $ConfirmImpact -FinalAcknowledge $FinalAcknowledge -DryRun:$DryRun
