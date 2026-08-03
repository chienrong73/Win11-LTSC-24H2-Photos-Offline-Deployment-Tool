<#
.SYNOPSIS
    Runs the Microsoft Photos offline deployment workflow.

.DESCRIPTION
    Serves as the single entry point for the Windows 11 LTSC 24H2 Microsoft Photos offline
    deployment tool. The script loads configuration and all required modules, initializes
    logging, runs validation, prepares packages, invokes the offline deployment workflow,
    and closes logging with deterministic exit codes.

.PARAMETER ReadOnly
    Mounts the target image in read-only mode when the deployment module supports it.

.PARAMETER Discard
    Discards image changes during the deployment dismount phase.

.EXAMPLE
    .\Add_Photos.ps1 -Verbose

    Runs the deployment workflow with verbose output enabled.

.EXAMPLE
    .\Add_Photos.ps1 -WhatIf

    Runs non-destructive validation and reports the deployment action that would be invoked.

.NOTES
    Project: Win11-LTSC-24H2-Photos-Offline-Deployment-Tool
    File: Add_Photos.ps1
    Encoding: UTF-8 with BOM
    Author: Enterprise Endpoint Engineering
    Copyright: (c) 2026. All rights reserved.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [switch]
    $ReadOnly,

    [Parameter()]
    [switch]
    $Discard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ExitCode = 0
$script:LoggerInitialized = $false
$script:ScriptRoot = $PSScriptRoot
$script:ConfigPath = Join-Path -Path $script:ScriptRoot -ChildPath 'Config.ps1'
$script:ModuleRoot = Join-Path -Path $script:ScriptRoot -ChildPath 'Modules'

. $script:ConfigPath
Import-Module -Name (Join-Path -Path $script:ModuleRoot -ChildPath 'Logger.psm1') -Force
Import-Module -Name (Join-Path -Path $script:ModuleRoot -ChildPath 'Common.psm1') -Force
Import-Module -Name (Join-Path -Path $script:ModuleRoot -ChildPath 'Validation.psm1') -Force
Import-Module -Name (Join-Path -Path $script:ModuleRoot -ChildPath 'Package.psm1') -Force
Import-Module -Name (Join-Path -Path $script:ModuleRoot -ChildPath 'Dism.psm1') -Force

try {
    Test-DeploymentConfig | Out-Null

    Initialize-Logger `
        -EnableConsole ([bool]$Global:PhotosDeploymentConfig.Logging.EnableConsole) `
        -EnableFile ([bool]$Global:PhotosDeploymentConfig.Logging.EnableFile) `
        -LogFolder ([string]$Global:PhotosDeploymentConfig.Logging.LogFolder) `
        -LogFileName ([string]$Global:PhotosDeploymentConfig.Logging.LogFileName) `
        -LogLevel ([string]$Global:PhotosDeploymentConfig.Logging.LogLevel) | Out-Null
    $script:LoggerInitialized = $true

    Write-Header

    $validationSummary = Invoke-PreDeploymentValidation

    if (-not [bool]$validationSummary['Passed']) {
        $script:ExitCode = 20
        Write-Fatal -Message 'Pre-deployment validation failed. Review validation results before retrying.' -Component 'Main'
        throw 'Pre-deployment validation failed.'
    }

    if ($PSCmdlet.ShouldProcess('offline Windows image', 'Prepare packages and deploy Microsoft Photos')) {
        $packageSummary = Invoke-PackagePreparation

        if (-not [bool]$packageSummary['Passed']) {
            $script:ExitCode = 30
            Write-Fatal -Message 'Package preparation failed. Review package preparation results before retrying.' -Component 'Main'
            throw 'Package preparation failed.'
        }

        $deploymentSummary = Invoke-OfflineDeployment -ReadOnly:$ReadOnly -Discard:$Discard

        if (-not [bool]$deploymentSummary['Passed']) {
            $script:ExitCode = 40
            Write-Fatal -Message 'Offline deployment failed. Review deployment summary before retrying.' -Component 'Main'
            throw 'Offline deployment failed.'
        }

        Write-Success -Message 'Microsoft Photos offline deployment completed successfully.' -Component 'Main'
    }
    else {
        Write-Warning -Message 'WhatIf mode requested; package preparation and offline deployment were not executed.' -Component 'Main'
    }
}
catch {
    if ($script:ExitCode -eq 0) {
        $script:ExitCode = 1
    }

    if (Get-Command -Name 'Write-Fatal' -ErrorAction SilentlyContinue) {
        Write-Fatal -Message ('Fatal error: {0}' -f $_.Exception.Message) -Component 'Main'
    }
}
finally {
    if ($script:LoggerInitialized -and (Get-Command -Name 'Close-Logger' -ErrorAction SilentlyContinue)) {
        Close-Logger
    }
}

exit $script:ExitCode
