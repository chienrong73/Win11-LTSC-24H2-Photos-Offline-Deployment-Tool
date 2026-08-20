#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LoggerModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Logger.psm1'
$script:CommonModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Common.psm1'
if (-not (Get-Command -Name 'Initialize-Logger' -CommandType Function -ErrorAction SilentlyContinue)) {
    Import-Module -Name $script:LoggerModulePath -ErrorAction Stop
}
if (-not (Get-Command -Name 'Test-PathExists' -CommandType Function -ErrorAction SilentlyContinue)) {
    Import-Module -Name $script:CommonModulePath -ErrorAction Stop
}

function Get-PackageConfig {
    $variable = Get-Variable PhotosDeploymentConfig -Scope Global -ErrorAction SilentlyContinue
    if (-not $variable) { . (Join-Path (Split-Path $PSScriptRoot -Parent) 'Config.ps1') }
    (Get-Variable PhotosDeploymentConfig -Scope Global -ErrorAction Stop).Value
}

function Test-SupportedPackageExtension {
    param([Parameter(Mandatory)][string]$Path)
    @('.appx', '.appxbundle', '.msix', '.msixbundle') -contains [IO.Path]::GetExtension($Path).ToLowerInvariant()
}

function Get-PackageFiles {
    [CmdletBinding()] param([string]$RootPath = [string](Get-PackageConfig).Package.RootPath)
    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) { return @() }
    $extensions = [string[]](Get-PackageConfig).Package.SupportedExtensions
    @(Get-ChildItem -LiteralPath $RootPath -Recurse -File -ErrorAction Stop |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object FullName)
}

function Read-ZipXml {
    param([Parameter(Mandatory)][string]$PackagePath, [Parameter(Mandatory)][string[]]$EntryName)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $entry = $archive.Entries | Where-Object { $EntryName -contains $_.FullName } | Select-Object -First 1
        if (-not $entry) { throw "Package has no recognized manifest: $PackagePath" }
        $stream = $entry.Open(); $reader = New-Object -TypeName IO.StreamReader -ArgumentList $stream
        try { [xml]$reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
    } finally { $archive.Dispose() }
}

function Get-PackageManifest {
    [CmdletBinding()] param([Parameter(Mandatory,Position=0)][string]$PackagePath)
    Read-ZipXml $PackagePath @('AppxManifest.xml', 'AppxMetadata/AppxBundleManifest.xml')
}

function Get-XmlChildElement {
    param([System.Xml.XmlNode]$Node,[Parameter(Mandatory)][string]$LocalName)
    if ($null -eq $Node) { return $null }
    $Node.SelectSingleNode("*[local-name()='$LocalName']")
}

function Get-XmlAttributeValue {
    param([System.Xml.XmlNode]$Node,[Parameter(Mandatory)][string]$Name)
    if ($null -eq $Node -or $null -eq $Node.Attributes) { return '' }
    $attribute = $Node.Attributes.GetNamedItem($Name)
    if ($null -eq $attribute) { return '' }
    [string]$attribute.Value
}

function Get-ManifestRootElement {
    param([Parameter(Mandatory)][xml]$Manifest)
    $Manifest.SelectSingleNode("/*[local-name()='Package' or local-name()='Bundle']")
}

function Get-PackageVersion {
    [CmdletBinding(DefaultParameterSetName='Path')] param(
        [Parameter(Mandatory,ParameterSetName='Path',Position=0)][string]$PackagePath,
        [Parameter(Mandatory,ParameterSetName='Manifest')][xml]$Manifest)
    if ($PSCmdlet.ParameterSetName -eq 'Path') { $Manifest = Get-PackageManifest $PackagePath }
    $root = Get-ManifestRootElement $Manifest
    $identity = Get-XmlChildElement $root 'Identity'
    if ($null -eq $identity) { throw 'Package manifest has no Identity element.' }
    [version](Get-XmlAttributeValue $identity 'Version')
}

function Compare-PackageVersion {
    param([Parameter(Mandatory)][version]$Version,[Parameter(Mandatory)][version]$ReferenceVersion)
    if ($Version -gt $ReferenceVersion) { 'Newer' } elseif ($Version -lt $ReferenceVersion) { 'Older' } else { 'Equal' }
}

function Get-ManifestDependencies {
    param([Parameter(Mandatory)][xml]$Manifest)
    @($Manifest.SelectNodes("//*[local-name()='Dependencies']/*[local-name()='PackageDependency']") | ForEach-Object {
        [pscustomobject]@{
            Name = Get-XmlAttributeValue $_ 'Name'
            MinimumVersion = if ([string]::IsNullOrWhiteSpace((Get-XmlAttributeValue $_ 'MinVersion'))) { [version]'0.0.0.0' } else { [version](Get-XmlAttributeValue $_ 'MinVersion') }
            Publisher = Get-XmlAttributeValue $_ 'Publisher'
        }
    })
}

function New-PackageRecord {
    param([string]$Path,[xml]$Manifest,[string]$DeployPath = $Path,[switch]$FromBundle,[string]$BundleIdentity)
    $package = $Manifest.SelectSingleNode("/*[local-name()='Package']")
    $identity = Get-XmlChildElement $package 'Identity'
    if ($null -eq $identity) { throw "Inner package has no Identity: $Path" }
    $properties = Get-XmlChildElement $package 'Properties'
    $applications = @($Manifest.SelectNodes("/*[local-name()='Package']/*[local-name()='Applications']/*[local-name()='Application']"))
    $framework = Get-XmlChildElement $properties 'Framework'
    $resourcePackage = Get-XmlChildElement $properties 'ResourcePackage'
    $isFramework = ($null -ne $framework -and [string]$framework.InnerText -ieq 'true')
    $isResource = ($null -ne $resourcePackage -and [string]$resourcePackage.InnerText -ieq 'true') -or (-not [string]::IsNullOrWhiteSpace((Get-XmlAttributeValue $identity 'ResourceId')))
    $isOptional = @($Manifest.SelectNodes("//*[local-name()='Dependencies']/*[local-name()='MainPackageDependency']")).Count -gt 0
    $classification = if ($isFramework) { 'Framework' } elseif ($isResource) { 'Resource' } elseif ($isOptional) { 'Optional' } elseif ($applications.Count -gt 0) { 'MainApplication' } else { 'Dependency' }
    $displayNameElement = Get-XmlChildElement $properties 'DisplayName'
    $displayName = if ($null -eq $displayNameElement) { '' } else { [string]$displayNameElement.InnerText }
    if ([string]::IsNullOrWhiteSpace($displayName) -or $displayName.StartsWith('ms-resource:')) { $displayName = Get-XmlAttributeValue $identity 'Name' }
    $architecture = Get-XmlAttributeValue $identity 'ProcessorArchitecture'
    if ([string]::IsNullOrWhiteSpace($architecture)) { $architecture = 'neutral' }
    [pscustomobject]@{
        Path=$DeployPath; ManifestPath=$Path; Identity=Get-XmlAttributeValue $identity 'Name'; Publisher=Get-XmlAttributeValue $identity 'Publisher'
        Version=[version](Get-XmlAttributeValue $identity 'Version'); Architecture=$architecture
        DisplayName=$displayName; Classification=$classification; IsBundle=[bool]$FromBundle; BundleIdentity=$BundleIdentity
        Dependencies=@(Get-ManifestDependencies $Manifest)
    }
}

function Get-BundleRecords {
    param([Parameter(Mandatory)][IO.FileInfo]$File,[Parameter(Mandatory)][xml]$BundleManifest)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($File.FullName); $records=@()
    try {
        $bundle = $BundleManifest.SelectSingleNode("/*[local-name()='Bundle']")
        $bundleIdentityNode = Get-XmlChildElement $bundle 'Identity'
        $bundleIdentity = Get-XmlAttributeValue $bundleIdentityNode 'Name'
        foreach ($node in @($BundleManifest.SelectNodes("//*[local-name()='Packages']/*[local-name()='Package']"))) {
            $fileName = Get-XmlAttributeValue $node 'FileName'
            if ([string]::IsNullOrWhiteSpace($fileName)) { continue }
            $entry = $archive.GetEntry($fileName); if (-not $entry) { continue }
            $memory = New-Object -TypeName IO.MemoryStream; $source=$entry.Open()
            try { $source.CopyTo($memory); $memory.Position=0; $inner=New-Object -TypeName IO.Compression.ZipArchive -ArgumentList @($memory,[IO.Compression.ZipArchiveMode]::Read,$true)
                try { $manifestEntry=$inner.GetEntry('AppxManifest.xml'); if (-not $manifestEntry) { continue }; $s=$manifestEntry.Open(); $r=New-Object -TypeName IO.StreamReader -ArgumentList $s
                    try { [xml]$xml=$r.ReadToEnd(); $records += New-PackageRecord -Path ($File.FullName+'!'+$fileName) -Manifest $xml -DeployPath $File.FullName -FromBundle -BundleIdentity $bundleIdentity }
                    finally { $r.Dispose(); $s.Dispose() }
                } finally { $inner.Dispose() }
            } finally { $source.Dispose(); $memory.Dispose() }
        }
    } finally { $archive.Dispose() }
    $records
}

function Get-PackageCatalog {
    [CmdletBinding()] param([string]$RootPath = [string](Get-PackageConfig).Package.RootPath)
    $catalog=@()
    foreach ($file in @(Get-PackageFiles $RootPath)) {
        try {
            $manifest=Get-PackageManifest $file.FullName
            $root = Get-ManifestRootElement $manifest
            if ($null -ne $root -and $root.LocalName -eq 'Bundle') { $catalog += Get-BundleRecords $file $manifest }
            else { $catalog += New-PackageRecord $file.FullName $manifest }
        } catch { Write-Warning -Message ("Ignoring invalid package {0}: {1}" -f $file.FullName,$_.Exception.Message) -Component Package }
    }
    Write-Info -Message ('Discovered {0} valid package payload record(s) beneath {1}.' -f $catalog.Count,$RootPath) -Component Package
    @($catalog)
}

function Test-ArchitectureMatch {
    param([string]$Required,[string]$Candidate)
    ($Candidate -ieq 'neutral' -or $Candidate -ieq $Required)
}

function Get-PreferredArchitecture {
    $architecture = [string]$env:PROCESSOR_ARCHITECTURE
    if ($architecture -ieq 'AMD64') { return 'x64' }
    if ($architecture -ieq 'ARM64') { return 'arm64' }
    if ($architecture -ieq 'x86') { return 'x86' }
    return 'neutral'
}

function Resolve-AppDependencies {
    [CmdletBinding()] param([Parameter(Mandatory)]$Application,[Parameter(Mandatory)][object[]]$Catalog,[string]$TargetArchitecture = (Get-PreferredArchitecture))
    $resolved=@{}; $missing=@(); $queue=New-Object Collections.Queue
    $applicationArchitecture = if ($Application.Architecture -ieq 'neutral') { $TargetArchitecture } else { $Application.Architecture }
    foreach ($requirement in @($Application.Dependencies)) { $queue.Enqueue([pscustomobject]@{ Requirement=$requirement; Architecture=$applicationArchitecture }) }
    while ($queue.Count -gt 0) {
        $item=$queue.Dequeue(); $requirement=$item.Requirement
        $candidate=@($Catalog | Where-Object {
            $_.Classification -in @('Framework','Dependency') -and $_.Identity -ieq $requirement.Name -and
            $_.Version -ge $requirement.MinimumVersion -and (Test-ArchitectureMatch $item.Architecture $_.Architecture) -and
            ([string]::IsNullOrWhiteSpace($requirement.Publisher) -or $_.Publisher -ieq $requirement.Publisher)
        } | Sort-Object Version -Descending | Select-Object -First 1)
        if ($candidate.Count -eq 0) { $missing += ('{0} (>= {1}, {2})' -f $requirement.Name,$requirement.MinimumVersion,$item.Architecture); continue }
        $selected=$candidate[0]; $key='{0}|{1}|{2}' -f $selected.Identity,$selected.Version,$selected.Architecture
        if (-not $resolved.ContainsKey($key)) {
            $resolved[$key]=$selected
            $childArchitecture = if ($selected.Architecture -ieq 'neutral') { $item.Architecture } else { $selected.Architecture }
            foreach ($child in @($selected.Dependencies)) { $queue.Enqueue([pscustomobject]@{Requirement=$child;Architecture=$childArchitecture}) }
        }
    }
    [pscustomobject]@{ Passed=($missing.Count -eq 0); Dependencies=@($resolved.Values); Missing=@($missing | Select-Object -Unique) }
}

function Invoke-PackagePreparation {
    [CmdletBinding()] param()
    $root=[string](Get-PackageConfig).Package.RootPath
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $catalog=@(Get-PackageCatalog $root)
    $preferredArchitecture=Get-PreferredArchitecture
    $apps=@($catalog | Where-Object Classification -eq 'MainApplication' | Group-Object Identity | ForEach-Object {
        $_.Group | Sort-Object @{Expression='Version';Descending=$true},@{Expression={ if ($_.Architecture -ieq $preferredArchitecture) { 0 } elseif ($_.Architecture -ieq 'neutral') { 1 } else { 2 } }} | Select-Object -First 1
    } | Sort-Object DisplayName)
    foreach ($app in $apps) {
        $resolution=Resolve-AppDependencies $app $catalog
        Add-Member -InputObject $app -NotePropertyName Resolution -NotePropertyValue $resolution
        if ($resolution.Passed) {
            Write-Info -Message ('Application {0} is ready with {1} resolved dependency package(s).' -f $app.Identity,$resolution.Dependencies.Count) -Component Package
        }
        else {
            Write-Warning -Message ('Application {0} is missing dependencies: {1}' -f $app.Identity,($resolution.Missing -join ', ')) -Component Package
        }
    }
    [ordered]@{ Passed=($apps.Count -gt 0); Catalog=$catalog; Applications=$apps; Timestamp=Get-Date }
}

function Test-PackageIntegrity { param([Parameter(Mandatory,Position=0)][string]$PackagePath) try { [void](Get-PackageManifest $PackagePath); [ordered]@{PackagePath=$PackagePath;Passed=$true} } catch { [ordered]@{PackagePath=$PackagePath;Passed=$false;Message=$_.Exception.Message} } }

Export-ModuleMember -Function 'Get-PackageFiles','Get-PackageManifest','Get-PackageVersion','Compare-PackageVersion','Get-PackageCatalog','Resolve-AppDependencies','Test-PackageIntegrity','Invoke-PackagePreparation'
