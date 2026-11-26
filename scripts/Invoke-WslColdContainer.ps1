#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('prepare','backup','restore','reconcile')][string]$Phase='prepare',
    [Parameter(Mandatory)][string]$PolicyPath,
    [Parameter(Mandatory)][string]$ReviewedPolicySha256,
    [Parameter(Mandatory)][string]$AllowedSignersPath,
    [Parameter(Mandatory)][string]$ReviewedSignersSha256,
    [Security.SecureString]$Passphrase,
    [IO.Stream]$IndependentKey,
    [string]$TransactionId,
    [string]$BackupReceiptPath,
    [string]$ReviewedBackupReceiptSha256,
    [switch]$Execute,
    [switch]$ObserveOnly
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'lib' 'WslBackup.ps1')
$result=Invoke-WslColdContainerOperation @PSBoundParameters
# Retain the SAME process/handles if transport or kernel status is unconfirmed.
# No normal script exit can silently release source custody in that state.
if($result.CustodyRetained){Write-Warning ('Custody retained: '+$result.Gate+'. Keep this process alive; resolve the reported root gate. Only read-only status polling follows.')}
while($result.CustodyRetained) {
    Start-Sleep -Seconds 2
    $result=Invoke-WslColdContainerOperation -Phase reconcile -PolicyPath $PolicyPath -ReviewedPolicySha256 $ReviewedPolicySha256 -AllowedSignersPath $AllowedSignersPath -ReviewedSignersSha256 $ReviewedSignersSha256 -TransactionId $result.TransactionId -Execute -ObserveOnly
}
$result | ConvertTo-Json -Depth 16
