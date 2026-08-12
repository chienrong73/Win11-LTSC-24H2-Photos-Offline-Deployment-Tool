#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ScriptPath,

    [Parameter(ValueFromRemainingArguments = $true)]
    [AllowEmptyString()]
    [string[]]$ScriptArgument = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-Base64Utf8 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
}

$scriptPathPayload = ConvertTo-Base64Utf8 -Value $ScriptPath
$argumentPayload = ConvertTo-Base64Utf8 -Value (ConvertTo-Json -InputObject $ScriptArgument -Compress)
$elevatedCommand = @"
`$ErrorActionPreference = 'Stop'
`$scriptPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$scriptPathPayload'))
`$argumentJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$argumentPayload'))
`$arguments = @()
if (-not [string]::IsNullOrWhiteSpace(`$argumentJson)) {
    `$arguments = @(ConvertFrom-Json -InputObject `$argumentJson)
}
try {
    & `$scriptPath @arguments
    exit `$LASTEXITCODE
}
catch {
    Write-Error -ErrorRecord `$_
    exit 1
}
"@
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevatedCommand))
$process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand)
exit $process.ExitCode
