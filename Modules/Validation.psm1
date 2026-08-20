<#
.SYNOPSIS
    Provides validation services for Microsoft Photos offline deployment.

.DESCRIPTION
    Implements pre-deployment validation for the Windows 11 LTSC 24H2 Microsoft Photos
    offline deployment tool. The module validates operating system requirements, Windows
    edition, DISM availability, disk space, package availability, image files, administrator
    privileges, and the broader deployment environment.

.NOTES
    Project: Win11-LTSC-24H2-Photos-Offline-Deployment-Tool
    Module: Validation
    File: Modules/Validation.psm1
    Encoding: UTF-8 with BOM
    Author: Enterprise Endpoint Engineering
    Copyright: (c) 2026. All rights reserved.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleMetadata = [ordered]@{
    Name        = 'Validation'
    Version     = '1.0.0'
    Description = 'Validation services for Microsoft Photos offline deployment.'
    Project     = 'Win11-LTSC-24H2-Photos-Offline-Deployment-Tool'
    Encoding    = 'UTF-8 with BOM'
}

$script:LoggerModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Logger.psm1'
$script:CommonModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Common.psm1'
if (-not (Get-Command -Name 'Initialize-Logger' -CommandType Function -ErrorAction SilentlyContinue)) {
    Import-Module -Name $script:LoggerModulePath -ErrorAction Stop
}
if (-not (Get-Command -Name 'Test-PathExists' -CommandType Function -ErrorAction SilentlyContinue)) {
    Import-Module -Name $script:CommonModulePath -ErrorAction Stop
}

function Get-ValidationConfig {
    <#
    .SYNOPSIS
        Returns the deployment configuration for validation.

    .DESCRIPTION
        Loads Config.ps1 when the global deployment configuration is not already available
        and returns the shared ordered configuration object.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param()

    $configurationVariable = Get-Variable -Name 'PhotosDeploymentConfig' -Scope Global -ErrorAction SilentlyContinue

    if (-not $configurationVariable) {
        $configPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Config.ps1'

        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            . $configPath
        }
    }

    return (Get-Variable -Name 'PhotosDeploymentConfig' -Scope Global -ErrorAction Stop).Value
}

function New-ValidationResult {
    <#
    .SYNOPSIS
        Creates a validation result object.

    .DESCRIPTION
        Builds a consistent ordered validation result for both individual validations and
        aggregate pre-deployment validation output.

    .PARAMETER Name
        Validation name.

    .PARAMETER Passed
        Indicates whether the validation passed.

    .PARAMETER Message
        Human-readable validation message.

    .PARAMETER Details
        Optional validation details.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory = $true)]
        [bool]
        $Passed,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [object]
        $Details
    )

    return [ordered]@{
        Name      = $Name
        Passed    = $Passed
        Message   = $Message
        Details   = $Details
        Timestamp = Get-Timestamp -Format 'yyyy-MM-dd HH:mm:ss K'
    }
}

function Write-ValidationResultLog {
    <#
    .SYNOPSIS
        Writes a validation result through the Logger module.

    .DESCRIPTION
        Sends validation result messages to Logger.psm1 using informational or error logging
        based on the validation result state.

    .PARAMETER Result
        Validation result object to log.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Collections.IDictionary]
        $Result
    )

    if ($Result['Passed']) {
        Write-Info -Message ('Validation passed: {0} - {1}' -f $Result['Name'], $Result['Message']) -Component 'Validation'
        return
    }

    Write-Error -Message ('Validation failed: {0} - {1}' -f $Result['Name'], $Result['Message']) -Component 'Validation'
}

function Invoke-ValidationSafely {
    <#
    .SYNOPSIS
        Executes a validation script block and converts exceptions to results.

    .DESCRIPTION
        Ensures aggregate validation continues even when an individual validation raises an
        unexpected exception.

    .PARAMETER Name
        Validation name.

    .PARAMETER ScriptBlock
        Validation script block to execute.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [scriptblock]
        $ScriptBlock
    )

    try {
        return (& $ScriptBlock)
    }
    catch {
        $message = 'Validation raised an unexpected exception: {0}' -f $_.Exception.Message
        Write-Fatal -Message $message -Component 'Validation'
        return (New-ValidationResult -Name $Name -Passed $false -Message $message)
    }
}

function Test-OperatingSystem {
    <#
    .SYNOPSIS
        Validates the operating system build requirement.

    .DESCRIPTION
        Uses Common.psm1 operating system information to validate the configured minimum
        Windows build and Windows 11 requirement.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param()

    $config = Get-ValidationConfig
    $osInfo = Get-OperatingSystemInfo
    $minimumBuild = [int]$config.Validation.MinimumBuild
    $buildNumber = [int]$osInfo['BuildNumber']
    $requiresWindows11 = [bool]$config.Validation.RequireWindows11
    $caption = [string]$osInfo['Caption']
    $passed = ($buildNumber -ge $minimumBuild)

    if ($requiresWindows11) {
        $passed = ($passed -and ($caption -match 'Windows 11' -or $buildNumber -ge 22000))
    }

    $message = 'Detected {0} build {1}; minimum build is {2}.' -f $caption, $buildNumber, $minimumBuild
    $result = New-ValidationResult -Name 'OperatingSystem' -Passed $passed -Message $message -Details $osInfo
    Write-ValidationResultLog -Result $result

    return $result
}

function Test-WindowsEdition {
    <#
    .SYNOPSIS
        Validates the Windows edition for LTSC deployment suitability.

    .DESCRIPTION
        Uses Common.psm1 operating system information to verify that the current Windows
        edition caption indicates an LTSC or Enterprise environment suitable for this tool.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param()

    $osInfo = Get-OperatingSystemInfo
    $caption = [string]$osInfo['Caption']
    $passed = ($caption -match 'LTSC' -or $caption -match 'Enterprise')
    $message = 'Detected Windows edition: {0}.' -f $caption
    $result = New-ValidationResult -Name 'WindowsEdition' -Passed $passed -Message $message -Details $osInfo
    Write-ValidationResultLog -Result $result

    return $result
}

function Test-DismVersion {
    <#
    .SYNOPSIS
        Validates DISM availability.

    .DESCRIPTION
        Verifies that DISM is available when required by configuration and reports the
        discovered executable path and file version when available.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param()

    $config = Get-ValidationConfig
    $requiresDism = [bool]$config.Validation.RequireDISM
    $dismCommand = Get-Command -Name 'dism.exe' -ErrorAction SilentlyContinue

    if (-not $dismCommand) {
        $message = 'DISM executable was not found in the current PATH.'
        $result = New-ValidationResult -Name 'DismVersion' -Passed (-not $requiresDism) -Message $message
        Write-ValidationResultLog -Result $result
        return $result
    }

    $fileVersion = $null

    if ($dismCommand.Source -and (Test-PathExists -Path $dismCommand.Source -PathType Leaf)) {
        $fileVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($dismCommand.Source).FileVersion
    }

    $details = [ordered]@{
        Path    = $dismCommand.Source
        Version = $fileVersion
    }
    $message = 'DISM found at {0}; version {1}.' -f $dismCommand.Source, $fileVersion
    $result = New-ValidationResult -Name 'DismVersion' -Passed $true -Message $message -Details $details
    Write-ValidationResultLog -Result $result

    return $result
}

function Test-DiskSpace {
    <#
    .SYNOPSIS
        Validates available disk space for the image mount path.

    .DESCRIPTION
        Checks the target drive for the configured mount path and verifies that it has at
        least the requested free space.

    .PARAMETER Path
        Path whose drive should be checked. Defaults to the configured image mount path.

    .PARAMETER MinimumFreeGB
        Minimum required free disk space in gigabytes.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int]
        $MinimumFreeGB = 10
    )

    $config = Get-ValidationConfig

    if (-not $PSBoundParameters.ContainsKey('Path')) {
        $Path = [string]$config.Image.MountPath
    }

    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($fullPath)
    $drive = New-Object -TypeName System.IO.DriveInfo -ArgumentList $rootPath
    $freeGB = [math]::Round(($drive.AvailableFreeSpace / 1GB), 2)
    $passed = ($freeGB -ge $MinimumFreeGB)
    $details = [ordered]@{
        Path          = $Path
        RootPath      = $rootPath
        FreeGB        = $freeGB
        MinimumFreeGB = $MinimumFreeGB
    }
    $message = 'Drive {0} has {1} GB free; minimum required is {2} GB.' -f $rootPath, $freeGB, $MinimumFreeGB
    $result = New-ValidationResult -Name 'DiskSpace' -Passed $passed -Message $message -Details $details
    Write-ValidationResultLog -Result $result

    return $result
}

function Test-RequiredPackages {
    [CmdletBinding()] param()
    $rootPath = [string](Get-ValidationConfig).Package.RootPath
    if (-not (Test-PathExists -Path $rootPath -PathType Container)) {
        New-Directory -Path $rootPath | Out-Null
    }
    $packages = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -ErrorAction Stop | Where-Object {
        @('.appx','.appxbundle','.msix','.msixbundle') -contains $_.Extension.ToLowerInvariant()
    })
    $passed = $packages.Count -gt 0
    $message = 'Found {0} supported package file(s) recursively beneath {1}.' -f $packages.Count,$rootPath
    $result = New-ValidationResult -Name 'RequiredPackages' -Passed $passed -Message $message -Details @($packages.FullName)
    Write-ValidationResultLog -Result $result
    return $result
}

function Test-ImageFile {
    <#
    .SYNOPSIS
        Validates the configured Windows image file.

    .DESCRIPTION
        Validates that the configured image file path exists and uses a supported Windows
        image extension. Supported extensions are .wim and .esd.

    .PARAMETER ImagePath
        Optional image file path to validate. Defaults to the configured image path.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $ImagePath
    )

    $config = Get-ValidationConfig

    if (-not $PSBoundParameters.ContainsKey('ImagePath')) {
        $ImagePath = [string]$config.Image.ImagePath
    }

    $extension = [System.IO.Path]::GetExtension($ImagePath)
    $supportedExtension = ($extension -ieq '.wim' -or $extension -ieq '.esd')
    $exists = Test-PathExists -Path $ImagePath -PathType Leaf
    $passed = ($exists -and $supportedExtension)
    $details = [ordered]@{
        ImagePath          = $ImagePath
        Extension          = $extension
        SupportedExtension = $supportedExtension
        Exists             = $exists
    }
    $message = 'Image path {0}; extension {1}; supported extensions are .wim and .esd.' -f $ImagePath, $extension
    $result = New-ValidationResult -Name 'ImageFile' -Passed $passed -Message $message -Details $details
    Write-ValidationResultLog -Result $result

    return $result
}

function Test-AdministratorPrivileges {
    <#
    .SYNOPSIS
        Validates administrator privileges.

    .DESCRIPTION
        Uses Common.psm1 Test-IsAdministrator to verify that the current process is elevated
        when administrator privileges are required by configuration.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param()

    $config = Get-ValidationConfig
    $requiresAdministrator = [bool]$config.Validation.RequireAdministrator
    $isAdministrator = Test-IsAdministrator
    $passed = ((-not $requiresAdministrator) -or $isAdministrator)
    $details = [ordered]@{
        RequireAdministrator = $requiresAdministrator
        IsAdministrator      = $isAdministrator
    }
    $message = 'Administrator required: {0}; current process elevated: {1}.' -f $requiresAdministrator, $isAdministrator
    $result = New-ValidationResult -Name 'AdministratorPrivileges' -Passed $passed -Message $message -Details $details
    Write-ValidationResultLog -Result $result

    return $result
}

function Test-DeploymentEnvironment {
    <#
    .SYNOPSIS
        Validates overall deployment environment characteristics.

    .DESCRIPTION
        Uses Common.psm1 public functions to validate OS architecture and identify Windows PE
        or audit mode state for deployment readiness reporting.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param()

    $is64Bit = Test-Is64BitOS
    $isWindowsPE = Test-IsWindowsPE
    $isAuditMode = Test-IsAuditMode
    $passed = $is64Bit
    $details = [ordered]@{
        Is64BitOS    = $is64Bit
        IsWindowsPE  = $isWindowsPE
        IsAuditMode  = $isAuditMode
    }
    $message = 'Environment state: 64-bit OS={0}; Windows PE={1}; Audit Mode={2}.' -f $is64Bit, $isWindowsPE, $isAuditMode
    $result = New-ValidationResult -Name 'DeploymentEnvironment' -Passed $passed -Message $message -Details $details

    if ($isWindowsPE -or $isAuditMode) {
        Write-Warning -Message $message -Component 'Validation'
    }

    Write-ValidationResultLog -Result $result

    return $result
}

function Invoke-PreDeploymentValidation {
    <#
    .SYNOPSIS
        Runs all pre-deployment validation checks.

    .DESCRIPTION
        Executes every validation function and returns a complete aggregate validation report.
        The function continues running remaining validations even if one validation fails or
        raises an exception.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param()

    Write-Info -Message 'Starting pre-deployment validation.' -Component 'Validation'

    $results = @(
        Invoke-ValidationSafely -Name 'OperatingSystem' -ScriptBlock { Test-OperatingSystem }
        Invoke-ValidationSafely -Name 'WindowsEdition' -ScriptBlock { Test-WindowsEdition }
        Invoke-ValidationSafely -Name 'DismVersion' -ScriptBlock { Test-DismVersion }
        Invoke-ValidationSafely -Name 'DiskSpace' -ScriptBlock { Test-DiskSpace }
        Invoke-ValidationSafely -Name 'RequiredPackages' -ScriptBlock { Test-RequiredPackages }
        Invoke-ValidationSafely -Name 'ImageFile' -ScriptBlock { Test-ImageFile }
        Invoke-ValidationSafely -Name 'AdministratorPrivileges' -ScriptBlock { Test-AdministratorPrivileges }
        Invoke-ValidationSafely -Name 'DeploymentEnvironment' -ScriptBlock { Test-DeploymentEnvironment }
    )

    $failedResults = @($results | Where-Object { -not $_['Passed'] })
    $passed = ($failedResults.Count -eq 0)
    $summary = [ordered]@{
        Passed      = $passed
        Total       = $results.Count
        PassedCount = ($results.Count - $failedResults.Count)
        FailedCount = $failedResults.Count
        Results     = $results
        Timestamp   = Get-Timestamp -Format 'yyyy-MM-dd HH:mm:ss K'
    }

    if ($passed) {
        Write-Info -Message 'Pre-deployment validation completed successfully.' -Component 'Validation'
    }
    else {
        Write-Fatal -Message ('Pre-deployment validation completed with {0} failed check(s).' -f $failedResults.Count) -Component 'Validation'
    }

    return $summary
}

Export-ModuleMember -Function 'Test-OperatingSystem', 'Test-WindowsEdition', 'Test-DismVersion', 'Test-DiskSpace', 'Test-RequiredPackages', 'Test-ImageFile', 'Test-AdministratorPrivileges', 'Test-DeploymentEnvironment', 'Invoke-PreDeploymentValidation'
