<#
.SYNOPSIS
    Provides package preparation services for Microsoft Photos offline deployment.

.DESCRIPTION
    Implements Microsoft Photos package discovery, dependency discovery, package integrity
    validation, package copying, manifest parsing, version extraction, version comparison,
    and package preparation orchestration for the Windows 11 LTSC 24H2 Microsoft Photos
    offline deployment tool.

.NOTES
    Project: Win11-LTSC-24H2-Photos-Offline-Deployment-Tool
    Module: Package
    File: Modules/Package.psm1
    Encoding: UTF-8 with BOM
    Author: Enterprise Endpoint Engineering
    Copyright: (c) 2026. All rights reserved.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleMetadata = [ordered]@{
    Name        = 'Package'
    Version     = '1.0.0'
    Description = 'Package preparation services for Microsoft Photos offline deployment.'
    Project     = 'Win11-LTSC-24H2-Photos-Offline-Deployment-Tool'
    Encoding    = 'UTF-8 with BOM'
}

$script:LoggerModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Logger.psm1'
$script:CommonModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Common.psm1'
$script:ValidationModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Validation.psm1'
if (-not (Get-Command -Name 'Write-Info' -CommandType Function -ErrorAction SilentlyContinue)) {
    Import-Module -Name $script:LoggerModulePath -ErrorAction Stop
}
if (-not (Get-Command -Name 'Test-PathExists' -CommandType Function -ErrorAction SilentlyContinue)) {
    Import-Module -Name $script:CommonModulePath -ErrorAction Stop
}
if (-not (Get-Command -Name 'Test-RequiredPackages' -CommandType Function -ErrorAction SilentlyContinue)) {
    Import-Module -Name $script:ValidationModulePath -ErrorAction Stop
}

function Get-PackageConfig {
    <#
    .SYNOPSIS
        Returns the deployment configuration for package operations.

    .DESCRIPTION
        Loads Config.ps1 when needed and returns the global deployment configuration used by
        package discovery and preparation functions.

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

function Invoke-PackageError {
    <#
    .SYNOPSIS
        Logs and throws a package module error.

    .DESCRIPTION
        Writes the supplied error message through the Logger module and throws a terminating
        exception for package operations that cannot safely continue.

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
        Write-Error -Message ('{0} Details: {1}' -f $Message, $Exception.Message) -Component 'Package'
        throw (New-Object -TypeName System.InvalidOperationException -ArgumentList $Message, $Exception)
    }

    Write-Error -Message $Message -Component 'Package'
    throw $Message
}

function Test-SupportedPackageExtension {
    <#
    .SYNOPSIS
        Determines whether a package extension is supported.

    .DESCRIPTION
        Validates a package path extension against the supported AppX/MSIX package types.

    .PARAMETER Path
        Package path to validate.

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

    $extension = [System.IO.Path]::GetExtension($Path)
    return (@('.appx', '.appxbundle', '.msix', '.msixbundle') -contains $extension.ToLowerInvariant())
}

function Get-PackageFilesByFilter {
    <#
    .SYNOPSIS
        Gets package files matching a configured filter.

    .DESCRIPTION
        Returns supported AppX/MSIX package files from the supplied root path and filter.

    .PARAMETER RootPath
        Package root path to search.

    .PARAMETER Filter
        One or more file filters to apply.

    .OUTPUTS
        System.IO.FileInfo[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $RootPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $Filter
    )

    if (-not (Test-PathExists -Path $RootPath -PathType Container)) {
        Invoke-PackageError -Message ('Package root path does not exist: {0}' -f $RootPath)
    }

    $filesByPath = @{}

    foreach ($currentFilter in $Filter) {
        foreach ($file in (Get-ChildItem -LiteralPath $RootPath -Filter $currentFilter -File -ErrorAction Stop)) {
            if (Test-SupportedPackageExtension -Path $file.FullName) {
                $filesByPath[$file.FullName] = $file
            }
        }
    }

    return @($filesByPath.Values | Sort-Object -Property FullName)
}

function Get-ZipEntries {
    <#
    .SYNOPSIS
        Returns ZIP archive entries for a package file.

    .DESCRIPTION
        Opens an AppX/MSIX package as a ZIP archive and returns entries for manifest and
        integrity checks.

    .PARAMETER PackagePath
        Package file path.

    .OUTPUTS
        System.IO.Compression.ZipArchiveEntry[]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $PackagePath
    )

    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)

    try {
        return @($archive.Entries)
    }
    finally {
        $archive.Dispose()
    }
}

function Get-TargetAppPackage {
    <#
    .SYNOPSIS
        Gets the configured target app package file.

    .DESCRIPTION
        Discovers supported target app bundle files, validates their package identities
        and versions, and returns only the newest valid package.

    .OUTPUTS
        System.IO.FileInfo
    #>
    [CmdletBinding()]
    param()

    $config = Get-PackageConfig
    $packages = @(Get-PackageFilesByFilter -RootPath ([string]$config.Package.RootPath) -Filter ([string[]]$config.Package.AppFilters))
    $validPackages = @()

    foreach ($package in $packages) {
        try {
            $manifest = Get-PackageManifest -PackagePath $package.FullName
            $identity = Get-PackageManifestIdentity -Manifest $manifest

            if (-not $identity -or [string]$identity.Name -ine [string]$config.Package.AppIdentity) {
                Write-Warning -Message ('Ignoring package whose identity does not match {0}: {1}' -f $config.Package.AppIdentity, $package.FullName) -Component 'Package'
                continue
            }

            $validPackages += [pscustomobject]@{
                File    = $package
                Version = Get-PackageVersion -Manifest $manifest
            }
        }
        catch {
            Write-Warning -Message ('Ignoring invalid target app package {0}: {1}' -f $package.FullName, $_.Exception.Message) -Component 'Package'
        }
    }

    if ($validPackages.Count -eq 0) {
        Write-Warning -Message ('No valid package files were found for {0}.' -f $config.Package.AppIdentity) -Component 'Package'
        return @()
    }

    $selected = $validPackages | Sort-Object -Property @{ Expression = { $_.Version }; Descending = $true }, @{ Expression = { $_.File.FullName }; Descending = $false } | Select-Object -First 1
    Write-Info -Message ('Selected package {0} for {1} (version {2}) from {3} valid candidate(s).' -f $selected.File.FullName, $config.Package.AppIdentity, $selected.Version, $validPackages.Count) -Component 'Package'

    return $selected.File
}

function Get-PackageManifestIdentity {
    <#
    .SYNOPSIS
        Returns the Identity element from a package or bundle manifest.

    .DESCRIPTION
        Resolves the document element without relying on PowerShell's adapted XML properties.
        AppxManifest.xml and MSIX manifests use a Package root, while AppxBundleManifest.xml
        and MSIX bundle manifests use a Bundle root. Namespace-agnostic XPath supports both
        formats consistently in Windows PowerShell 5.1 with StrictMode enabled.

    .PARAMETER Manifest
        Parsed package or bundle manifest XML.

    .OUTPUTS
        System.Xml.XmlElement
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [xml]
        $Manifest
    )

    $root = $Manifest.DocumentElement
    if (-not $root -or @('Package', 'Bundle') -notcontains $root.LocalName) {
        Invoke-PackageError -Message 'Package manifest root must be Package or Bundle.'
    }

    $identity = $root.SelectSingleNode("*[local-name()='Identity']")
    if (-not $identity) {
        Invoke-PackageError -Message ('{0} manifest does not contain an Identity element.' -f $root.LocalName)
    }

    return $identity
}

function Get-DependencyPackages {
    <#
    .SYNOPSIS
        Gets dependency package files.

    .DESCRIPTION
        Discovers supported dependency AppX/MSIX package files using the configured package
        root path and DependencyFilters values. The configured target app itself is excluded.

    .OUTPUTS
        System.IO.FileInfo[]
    #>
    [CmdletBinding()]
    param()

    $config = Get-PackageConfig
    $packages = @(Get-PackageFilesByFilter -RootPath ([string]$config.Package.RootPath) -Filter ([string[]]$config.Package.DependencyFilters) |
        Where-Object { -not ([string]$_.BaseName).StartsWith([string]$config.Package.AppIdentity, [System.StringComparison]::OrdinalIgnoreCase) })

    if ($packages.Count -eq 0) {
        Write-Warning -Message 'No dependency package files were found.' -Component 'Package'
    }
    else {
        Write-Info -Message ('Found {0} dependency package file(s).' -f $packages.Count) -Component 'Package'
    }

    return $packages
}

function Test-PackageIntegrity {
    <#
    .SYNOPSIS
        Validates package file integrity.

    .DESCRIPTION
        Validates that a package file exists, has a supported extension, can be opened as a
        ZIP archive, and contains a recognizable package manifest.

    .PARAMETER PackagePath
        Package file path to validate.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $PackagePath
    )

    $exists = Test-PathExists -Path $PackagePath -PathType Leaf
    $supportedExtension = Test-SupportedPackageExtension -Path $PackagePath
    $manifestLoaded = $false
    $message = 'Package integrity validation completed.'

    if ($exists -and $supportedExtension) {
        try {
            [void](Get-PackageManifest -PackagePath $PackagePath)
            $manifestLoaded = $true
        }
        catch {
            $message = 'Package manifest could not be loaded: {0}' -f $_.Exception.Message
        }
    }
    elseif (-not $exists) {
        $message = 'Package file does not exist.'
    }
    else {
        $message = 'Package file extension is not supported.'
    }

    $passed = ($exists -and $supportedExtension -and $manifestLoaded)
    $result = [ordered]@{
        PackagePath        = $PackagePath
        Passed             = $passed
        Exists             = $exists
        SupportedExtension = $supportedExtension
        ManifestLoaded     = $manifestLoaded
        Message            = $message
        Timestamp          = Get-Timestamp -Format 'yyyy-MM-dd HH:mm:ss K'
    }

    if ($passed) {
        Write-Info -Message ('Package integrity passed: {0}' -f $PackagePath) -Component 'Package'
    }
    else {
        Write-Error -Message ('Package integrity failed: {0}. {1}' -f $PackagePath, $message) -Component 'Package'
    }

    return $result
}

function Copy-PackageFiles {
    <#
    .SYNOPSIS
        Copies package files to a destination directory.

    .DESCRIPTION
        Copies supplied package files to a destination directory using Common.psm1 safe copy
        helpers. The destination directory is created when required.

    .PARAMETER PackagePath
        One or more package file paths to copy.

    .PARAMETER DestinationPath
        Destination directory path for copied package files.

    .OUTPUTS
        System.IO.FileInfo[]
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $PackagePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $DestinationPath
    )

    begin {
        New-Directory -Path $DestinationPath | Out-Null
        $copiedItems = @()
    }

    process {
        foreach ($path in $PackagePath) {
            if (-not (Test-PathExists -Path $path -PathType Leaf)) {
                Invoke-PackageError -Message ('Package file does not exist and cannot be copied: {0}' -f $path)
            }

            $destinationFile = Join-Path -Path $DestinationPath -ChildPath (Split-Path -Path $path -Leaf)

            if ($PSCmdlet.ShouldProcess($destinationFile, ('Copy package file from {0}' -f $path))) {
                Copy-ItemSafe -SourcePath $path -DestinationPath $destinationFile -Force
                $copiedItems += (Get-Item -LiteralPath $destinationFile)
            }
        }
    }

    end {
        Write-Info -Message ('Copied {0} package file(s) to {1}.' -f $copiedItems.Count, $DestinationPath) -Component 'Package'
        return $copiedItems
    }
}

function Get-PackageManifest {
    <#
    .SYNOPSIS
        Extracts the package manifest XML.

    .DESCRIPTION
        Opens a supported AppX/MSIX package and parses AppxManifest.xml. For bundle packages,
        the function also supports AppxMetadata/AppxBundleManifest.xml when a package manifest
        is not present.

    .PARAMETER PackagePath
        Package file path to inspect.

    .OUTPUTS
        System.Xml.XmlDocument
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $PackagePath
    )

    if (-not (Test-PathExists -Path $PackagePath -PathType Leaf)) {
        Invoke-PackageError -Message ('Package file does not exist: {0}' -f $PackagePath)
    }

    if (-not (Test-SupportedPackageExtension -Path $PackagePath)) {
        Invoke-PackageError -Message ('Unsupported package extension: {0}' -f $PackagePath)
    }

    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)

    try {
        $manifestEntry = $archive.Entries | Where-Object { $_.FullName -ieq 'AppxManifest.xml' } | Select-Object -First 1

        if (-not $manifestEntry) {
            $manifestEntry = $archive.Entries | Where-Object { $_.FullName -ieq 'AppxMetadata/AppxBundleManifest.xml' } | Select-Object -First 1
        }

        if (-not $manifestEntry) {
            Invoke-PackageError -Message ('No AppxManifest.xml or AppxBundleManifest.xml was found in package: {0}' -f $PackagePath)
        }

        $stream = $manifestEntry.Open()
        $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList $stream

        try {
            [xml]$manifest = $reader.ReadToEnd()
            Write-Info -Message ('Parsed package manifest from {0}.' -f $PackagePath) -Component 'Package'
            return $manifest
        }
        finally {
            $reader.Dispose()
            $stream.Dispose()
        }
    }
    catch {
        Invoke-PackageError -Message ('Unable to parse package manifest: {0}' -f $PackagePath) -Exception $_.Exception
    }
    finally {
        $archive.Dispose()
    }
}

function Get-PackageVersion {
    <#
    .SYNOPSIS
        Returns a package version as a Version object.

    .DESCRIPTION
        Parses the package manifest and returns the Identity Version value as a standard
        System.Version object.

    .PARAMETER PackagePath
        Package file path to inspect.

    .PARAMETER Manifest
        Already parsed package manifest XML.

    .OUTPUTS
        System.Version
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path', Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]
        $PackagePath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Manifest')]
        [ValidateNotNull()]
        [xml]
        $Manifest
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $Manifest = Get-PackageManifest -PackagePath $PackagePath
    }

    $identity = Get-PackageManifestIdentity -Manifest $Manifest

    if (-not $identity -or -not $identity.Version) {
        Invoke-PackageError -Message 'Package manifest does not contain an Identity Version value.'
    }

    $version = [version]$identity.Version
    Write-Info -Message ('Detected package version: {0}' -f $version) -Component 'Package'

    return $version
}

function Compare-PackageVersion {
    <#
    .SYNOPSIS
        Compares two package versions.

    .DESCRIPTION
        Compares a candidate package version to a reference package version and returns
        Newer, Older, or Equal.

    .PARAMETER Version
        Candidate package version to compare.

    .PARAMETER ReferenceVersion
        Reference package version used as the comparison baseline.

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [version]
        $Version,

        [Parameter(Mandatory = $true)]
        [version]
        $ReferenceVersion
    )

    if ($Version -gt $ReferenceVersion) {
        Write-Info -Message ('Package version {0} is newer than {1}.' -f $Version, $ReferenceVersion) -Component 'Package'
        return 'Newer'
    }

    if ($Version -lt $ReferenceVersion) {
        Write-Info -Message ('Package version {0} is older than {1}.' -f $Version, $ReferenceVersion) -Component 'Package'
        return 'Older'
    }

    Write-Info -Message ('Package version {0} is equal to {1}.' -f $Version, $ReferenceVersion) -Component 'Package'
    return 'Equal'
}

function Invoke-PackagePreparation {
    <#
    .SYNOPSIS
        Runs package preparation operations.

    .DESCRIPTION
        Validates required package availability, discovers the target app and dependency packages,
        validates package integrity, copies packages to a temporary preparation directory,
        and returns a complete package preparation summary.

    .PARAMETER DestinationPath
        Optional destination directory for prepared package files. When omitted, a temporary
        directory is created using Common.psm1.

    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $DestinationPath
    )

    Write-Info -Message 'Starting package preparation.' -Component 'Package'

    $requiredPackageValidation = Test-RequiredPackages
    $appPackages = @(Get-TargetAppPackage)
    $dependencyPackages = @(Get-DependencyPackages)

    if ($appPackages.Count -eq 0) {
        Write-Fatal -Message ('Package preparation cannot continue because no valid package for {0} was found.' -f (Get-PackageConfig).Package.AppIdentity) -Component 'Package'

        return [ordered]@{
            Passed                    = $false
            DestinationPath           = $DestinationPath
            RequiredPackageValidation = $requiredPackageValidation
            AppPackages               = @()
            DependencyPackages        = @($dependencyPackages | ForEach-Object { $_.FullName })
            IntegrityResults          = @()
            CopiedPackages            = @()
            Timestamp                 = Get-Timestamp -Format 'yyyy-MM-dd HH:mm:ss K'
        }
    }

    $allPackages = @($appPackages + $dependencyPackages)
    $integrityResults = @()

    foreach ($package in $allPackages) {
        $integrityResults += (Test-PackageIntegrity -PackagePath $package.FullName)
    }

    if (-not $PSBoundParameters.ContainsKey('DestinationPath')) {
        $DestinationPath = Get-TempDirectory -Prefix 'StoreAppPackages'
    }
    else {
        New-Directory -Path $DestinationPath | Out-Null
    }

    $passedIntegrity = @($integrityResults | Where-Object { $_['Passed'] })
    $copiedPackages = @()

    if ($passedIntegrity.Count -gt 0) {
        $packagePathsToCopy = @($passedIntegrity | ForEach-Object { $_['PackagePath'] })
        $copiedPackages = @(Copy-PackageFiles -PackagePath $packagePathsToCopy -DestinationPath $DestinationPath)
    }
    else {
        Write-Fatal -Message 'No packages passed integrity validation; package preparation cannot copy files.' -Component 'Package'
    }

    $failedIntegrity = @($integrityResults | Where-Object { -not $_['Passed'] })
    $passed = ([bool]$requiredPackageValidation['Passed'] -and $failedIntegrity.Count -eq 0 -and $copiedPackages.Count -eq $allPackages.Count)
    $summary = [ordered]@{
        Passed                    = $passed
        DestinationPath           = $DestinationPath
        RequiredPackageValidation = $requiredPackageValidation
        AppPackages               = @($appPackages | ForEach-Object { $_.FullName })
        DependencyPackages        = @($dependencyPackages | ForEach-Object { $_.FullName })
        IntegrityResults          = $integrityResults
        CopiedPackages            = @($copiedPackages | ForEach-Object { $_.FullName })
        Timestamp                 = Get-Timestamp -Format 'yyyy-MM-dd HH:mm:ss K'
    }

    if ($passed) {
        Write-Info -Message 'Package preparation completed successfully.' -Component 'Package'
    }
    else {
        Write-Fatal -Message 'Package preparation completed with failures.' -Component 'Package'
    }

    return $summary
}

Export-ModuleMember -Function 'Get-TargetAppPackage', 'Get-DependencyPackages', 'Test-PackageIntegrity', 'Copy-PackageFiles', 'Get-PackageManifest', 'Get-PackageVersion', 'Compare-PackageVersion', 'Invoke-PackagePreparation'
