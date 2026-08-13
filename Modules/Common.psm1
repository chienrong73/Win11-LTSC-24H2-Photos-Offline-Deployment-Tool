<#
.SYNOPSIS
    Provides common utility functions for Microsoft Photos offline deployment.

.DESCRIPTION
    Implements reusable operating system, filesystem, timestamp, and safe path helper
    functions for the Windows 11 LTSC 24H2 Microsoft Photos offline deployment tool.
    The module uses the Logger module for all informational and error messages and is
    compatible with Windows PowerShell 5.1 and PowerShell 7.

.NOTES
    Project: Win11-LTSC-24H2-Photos-Offline-Deployment-Tool
    Module: Common
    File: Modules/Common.psm1
    Encoding: UTF-8 with BOM
    Author: Enterprise Endpoint Engineering
    Copyright: (c) 2026. All rights reserved.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleMetadata = [ordered]@{
    Name        = 'Common'
    Version     = '1.0.0'
    Description = 'Common utility functions for Microsoft Photos offline deployment.'
    Project     = 'Win11-LTSC-24H2-Photos-Offline-Deployment-Tool'
    Encoding    = 'UTF-8 with BOM'
}

$script:LoggerModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Logger.psm1'
if (-not (Get-Command -Name 'Write-Error' -CommandType Function -ErrorAction SilentlyContinue)) {
    Import-Module -Name $script:LoggerModulePath -ErrorAction Stop
}

function Invoke-CommonError {
    <#
    .SYNOPSIS
        Logs and throws a common module error.

    .DESCRIPTION
        Writes the supplied error message through the Logger module and throws a terminating
        exception so callers can handle failures consistently.

    .PARAMETER Message
        Error message to log and throw.

    .PARAMETER Exception
        Optional source exception to include in the thrown error.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message,

        [Parameter()]
        [System.Exception]
        $Exception
    )

    if ($Exception) {
        Write-Error -Message ('{0} Details: {1}' -f $Message, $Exception.Message) -Component 'Common'
        throw (New-Object -TypeName System.InvalidOperationException -ArgumentList $Message, $Exception)
    }

    Write-Error -Message $Message -Component 'Common'
    throw $Message
}

function Test-IsUnsafeRootPath {
    <#
    .SYNOPSIS
        Determines whether a path points to a filesystem root.

    .DESCRIPTION
        Resolves a path and determines whether destructive operations should reject it as a
        protected root path.

    .PARAMETER Path
        Path to evaluate.

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path
    )

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($resolvedPath)

    return ($resolvedPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) -eq $rootPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
}

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        Determines whether the current process is running with administrative privileges.

    .DESCRIPTION
        Checks the current Windows security principal for membership in the built-in
        Administrators role. On non-Windows platforms, the function returns whether the
        effective user is root when that information is available.

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    param()

    try {
        if ($env:OS -eq 'Windows_NT') {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)

            return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        }

        if (Get-Command -Name 'id' -ErrorAction SilentlyContinue) {
            return ((& id -u) -eq '0')
        }

        return $false
    }
    catch {
        Invoke-CommonError -Message 'Unable to determine whether the current process is elevated.' -Exception $_.Exception
    }
}

function Test-IsWindowsPE {
    <#
    .SYNOPSIS
        Determines whether the current environment is Windows PE.

    .DESCRIPTION
        Detects Windows PE by checking for the MiniNT registry key that is present in Windows
        Preinstallation Environment sessions.

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    param()

    try {
        return (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT' -PathType Container)
    }
    catch {
        Invoke-CommonError -Message 'Unable to determine whether the current environment is Windows PE.' -Exception $_.Exception
    }
}

function Test-IsAuditMode {
    <#
    .SYNOPSIS
        Determines whether Windows is currently in audit mode.

    .DESCRIPTION
        Checks Windows setup registry values commonly used to indicate audit mode or audit
        boot state.

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    param()

    try {
        $auditBootPath = 'HKLM:\SYSTEM\Setup\Status\AuditBoot'
        $setupStatePath = 'HKLM:\SYSTEM\Setup\State'

        if (Test-Path -LiteralPath $auditBootPath -PathType Container) {
            $auditBoot = Get-ItemProperty -LiteralPath $auditBootPath -Name 'AuditBoot' -ErrorAction SilentlyContinue

            if ($auditBoot -and $auditBoot.AuditBoot -eq 1) {
                return $true
            }
        }

        if (Test-Path -LiteralPath $setupStatePath -PathType Container) {
            $setupState = Get-ItemProperty -LiteralPath $setupStatePath -Name 'ImageState' -ErrorAction SilentlyContinue

            if ($setupState -and $setupState.ImageState -match 'AUDIT') {
                return $true
            }
        }

        return $false
    }
    catch {
        Invoke-CommonError -Message 'Unable to determine whether Windows is in audit mode.' -Exception $_.Exception
    }
}

function Test-Is64BitOS {
    <#
    .SYNOPSIS
        Determines whether the operating system is 64-bit.

    .DESCRIPTION
        Uses the .NET Environment API to determine whether the host operating system is
        64-bit.

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    param()

    return [System.Environment]::Is64BitOperatingSystem
}

function Test-PathExists {
    <#
    .SYNOPSIS
        Determines whether a filesystem path exists.

    .DESCRIPTION
        Validates whether a supplied path exists as any item, a file, or a directory.

    .PARAMETER Path
        Path to validate.

    .PARAMETER PathType
        Type of path to validate. Valid values are Any, Leaf, and Container.

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [Parameter()]
        [ValidateSet('Any', 'Leaf', 'Container')]
        [string]
        $PathType = 'Any'
    )

    try {
        if ($PathType -eq 'Any') {
            return (Test-Path -LiteralPath $Path)
        }

        return (Test-Path -LiteralPath $Path -PathType $PathType)
    }
    catch {
        Invoke-CommonError -Message ('Unable to test path existence: {0}' -f $Path) -Exception $_.Exception
    }
}

function New-Directory {
    <#
    .SYNOPSIS
        Creates a directory when it does not already exist.

    .DESCRIPTION
        Safely creates a directory path and logs the action through the Logger module.
        Existing directories are left unchanged.

    .PARAMETER Path
        Directory path to create.

    .OUTPUTS
        System.IO.DirectoryInfo
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path
    )

    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            Write-Info -Message ('Directory already exists: {0}' -f $Path) -Component 'Common'
            return (Get-Item -LiteralPath $Path)
        }

        Write-Info -Message ('Creating directory: {0}' -f $Path) -Component 'Common'
        return (New-Item -Path $Path -ItemType Directory -Force)
    }
    catch {
        Invoke-CommonError -Message ('Unable to create directory: {0}' -f $Path) -Exception $_.Exception
    }
}

function Remove-DirectorySafe {
    <#
    .SYNOPSIS
        Removes a directory using safety checks.

    .DESCRIPTION
        Removes an existing directory after rejecting filesystem root paths. The operation is
        logged through the Logger module and supports ShouldProcess semantics.

    .PARAMETER Path
        Directory path to remove.

    .PARAMETER Recurse
        Removes child items recursively.

    .OUTPUTS
        None.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path,

        [Parameter()]
        [switch]
        $Recurse
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            Write-Info -Message ('Directory does not exist; no removal needed: {0}' -f $Path) -Component 'Common'
            return
        }

        if (Test-IsUnsafeRootPath -Path $Path) {
            Invoke-CommonError -Message ('Refusing to remove protected root path: {0}' -f $Path)
        }

        if ($PSCmdlet.ShouldProcess($Path, 'Remove directory')) {
            Write-Info -Message ('Removing directory: {0}' -f $Path) -Component 'Common'
            Remove-Item -LiteralPath $Path -Recurse:$Recurse -Force
        }
    }
    catch {
        Invoke-CommonError -Message ('Unable to remove directory safely: {0}' -f $Path) -Exception $_.Exception
    }
}

function Copy-ItemSafe {
    <#
    .SYNOPSIS
        Copies an item with validation and logging.

    .DESCRIPTION
        Copies a file or directory from a source path to a destination path after validating
        the source exists. Parent directories for file destinations are created when needed.

    .PARAMETER SourcePath
        Source item path to copy.

    .PARAMETER DestinationPath
        Destination path for the copied item.

    .PARAMETER Recurse
        Copies child items recursively.

    .PARAMETER Force
        Allows overwriting destination items when supported by Copy-Item.

    .OUTPUTS
        None.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $SourcePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $DestinationPath,

        [Parameter()]
        [switch]
        $Recurse,

        [Parameter()]
        [switch]
        $Force
    )

    try {
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            Invoke-CommonError -Message ('Source path does not exist: {0}' -f $SourcePath)
        }

        if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
            $destinationParent = Split-Path -Path $DestinationPath -Parent

            if ($destinationParent -and -not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
                New-Directory -Path $destinationParent | Out-Null
            }
        }

        if ($PSCmdlet.ShouldProcess($DestinationPath, ('Copy item from {0}' -f $SourcePath))) {
            Write-Info -Message ('Copying item from {0} to {1}' -f $SourcePath, $DestinationPath) -Component 'Common'
            Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Recurse:$Recurse -Force:$Force
        }
    }
    catch {
        Invoke-CommonError -Message ('Unable to copy item from {0} to {1}.' -f $SourcePath, $DestinationPath) -Exception $_.Exception
    }
}

function Get-Timestamp {
    <#
    .SYNOPSIS
        Returns a formatted timestamp.

    .DESCRIPTION
        Returns the current date and time using a caller-specified .NET date/time format.

    .PARAMETER Format
        .NET date/time format string used to format the timestamp.

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Format = 'yyyyMMdd_HHmmss'
    )

    return (Get-Date -Format $Format)
}

function Get-TempDirectory {
    <#
    .SYNOPSIS
        Creates and returns a temporary working directory.

    .DESCRIPTION
        Creates a unique temporary directory below the system temporary path and logs the
        directory creation through the Logger module.

    .PARAMETER Prefix
        Prefix used for the generated temporary directory name.

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Prefix = 'PhotosDeployment'
    )

    try {
        $temporaryRoot = [System.IO.Path]::GetTempPath()
        $temporaryName = '{0}_{1}_{2}' -f $Prefix, (Get-Timestamp), ([System.Guid]::NewGuid().ToString('N'))
        $temporaryPath = Join-Path -Path $temporaryRoot -ChildPath $temporaryName

        New-Directory -Path $temporaryPath | Out-Null
        Write-Info -Message ('Temporary directory ready: {0}' -f $temporaryPath) -Component 'Common'

        return $temporaryPath
    }
    catch {
        Invoke-CommonError -Message 'Unable to create a temporary directory.' -Exception $_.Exception
    }
}

function Get-OperatingSystemInfo {
    <#
    .SYNOPSIS
        Returns operating system information for deployment validation.

    .DESCRIPTION
        Collects operating system caption, version, build number, architecture, and runtime
        state flags used by deployment validation logic.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param()

    try {
        $caption = [System.Environment]::OSVersion.VersionString
        $version = [System.Environment]::OSVersion.Version
        $architecture = if ([System.Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }

        if (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue) {
            $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue

            if ($operatingSystem) {
                $caption = $operatingSystem.Caption
                $version = [version]$operatingSystem.Version
                $architecture = $operatingSystem.OSArchitecture
            }
        }

        return [ordered]@{
            Caption      = $caption
            Version      = $version.ToString()
            BuildNumber  = $version.Build
            Architecture = $architecture
            Is64Bit      = Test-Is64BitOS
            IsWindowsPE  = Test-IsWindowsPE
            IsAuditMode  = Test-IsAuditMode
        }
    }
    catch {
        Invoke-CommonError -Message 'Unable to collect operating system information.' -Exception $_.Exception
    }
}

Export-ModuleMember -Function 'Test-IsAdministrator', 'Test-IsWindowsPE', 'Test-IsAuditMode', 'Test-Is64BitOS', 'Test-PathExists', 'New-Directory', 'Remove-DirectorySafe', 'Copy-ItemSafe', 'Get-Timestamp', 'Get-TempDirectory', 'Get-OperatingSystemInfo'
