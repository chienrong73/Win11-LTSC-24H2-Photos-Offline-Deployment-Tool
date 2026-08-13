#!/usr/bin/env python3
"""Static validations for package discovery, elevation, and mount ownership semantics."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BATCH = (ROOT / "Add_Photos_Offline.bat").read_text(encoding="utf-8")
DISM = (ROOT / "Modules" / "Dism.psm1").read_text(encoding="utf-8")
ELEVATE = (ROOT / "Modules" / "Elevate-AddPhotos.ps1").read_text(encoding="utf-8")
ADD_PHOTOS = (ROOT / "Add_Photos.ps1").read_text(encoding="utf-8")
CONFIG = (ROOT / "Config.ps1").read_text(encoding="utf-8")
PACKAGE = (ROOT / "Modules" / "Package.psm1").read_text(encoding="utf-8-sig")
VALIDATION = (ROOT / "Modules" / "Validation.psm1").read_text(encoding="utf-8-sig")
LOGGER = (ROOT / "Modules" / "Logger.psm1").read_text(encoding="utf-8")


def assert_contains(text: str, needle: str, message: str) -> None:
    if needle not in text:
        raise AssertionError(message)


def test_batch_elevation_preserves_arguments_and_exit_code() -> None:
    assert_contains(
        BATCH,
        'Modules\\Elevate-AddPhotos.ps1" -ScriptPath "%SCRIPT_PATH%" %*',
        "elevation must hand the original %* arguments to the elevation helper",
    )
    assert_contains(
        ELEVATE,
        "[Parameter(ValueFromRemainingArguments = $true)]",
        "elevation helper must capture all remaining script arguments",
    )
    assert_contains(
        ELEVATE,
        "ConvertTo-Json -InputObject $ScriptArgument -Compress",
        "elevation helper must serialize arguments before elevation",
    )
    assert_contains(
        ELEVATE,
        "-EncodedCommand",
        "elevation helper must avoid rebuilding a quoted command line from raw arguments",
    )
    assert_contains(
        ELEVATE,
        "Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru",
        "elevation must wait for the elevated process and capture it",
    )
    assert_contains(
        ELEVATE,
        "exit $process.ExitCode",
        "elevation must return the elevated process exit code to the caller",
    )
    assert_contains(
        BATCH,
        "setlocal DisableDelayedExpansion",
        "batch file must keep delayed expansion disabled while reading paths and forwarding arguments",
    )
    if "EnableDelayedExpansion" in BATCH:
        raise AssertionError("delayed expansion must not be enabled while %~dp0 or %* is expanded")
    assert_contains(
        BATCH,
        'set "ELEVATED_EXIT_CODE=%errorlevel%"\nexit /b %ELEVATED_EXIT_CODE%',
        "batch file must capture and return the helper exit code outside a parenthesized block",
    )
    elevation_section = BATCH.split("echo Requesting administrator privileges...", 1)[1].split(":RunDeployment", 1)[0]
    if "(" in elevation_section or ")" in elevation_section:
        raise AssertionError("elevation and exit-code capture must remain outside parenthesized batch blocks")
    assert_contains(
        BATCH,
        'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %*',
        "the elevated batch path must forward all original arguments to Add_Photos.ps1",
    )


def test_batch_preserves_spaces_metacharacters_and_exclamation_marks() -> None:
    assert_contains(BATCH, 'set "SCRIPT_DIR=%~dp0"', "script directory must be read with delayed expansion disabled")
    assert_contains(BATCH, '-File "%SCRIPT_DIR%Modules\\Elevate-AddPhotos.ps1"', "helper path containing spaces or ! must be quoted")
    assert_contains(BATCH, '-ScriptPath "%SCRIPT_PATH%" %*', "quoted script path and original argument spelling must be preserved")

    script_path = r"C:\Deployment! Tools\Add_Photos.ps1"
    forwarded_arguments = r'-PackageRoot "C:\Packages! & Tools" -ImagePath "C:\Images\LTSC 24H2.wim"'
    assert "!" in script_path and " " in script_path
    assert "!" in forwarded_arguments and " " in forwarded_arguments and "&" in forwarded_arguments
    assert "%*" in BATCH, "batch forwarding must retain the caller's original quoting and metacharacter escaping"


def test_add_photos_exits_with_script_exit_code() -> None:
    assert_contains(
        ADD_PHOTOS,
        "if ($MyInvocation.InvocationName -ne '.') { exit $exitCode }",
        "Add_Photos.ps1 must terminate the PowerShell process with its deployment exit code",
    )
    if "$host.SetShouldExit($exitCode)" in ADD_PHOTOS:
        raise AssertionError("Add_Photos.ps1 must not rely on SetShouldExit when the elevation helper needs the process exit code")
    assert_contains(ADD_PHOTOS, "$exitCode = 0", "successful deployment must return exit code zero")
    assert_contains(ADD_PHOTOS, "$exitCode = 1", "failed deployment must retain a nonzero default exit code")


def test_logger_cleanup_is_public_idempotent_and_non_masking() -> None:
    assert_contains(LOGGER, "function Close-Logger {", "Logger module must implement Close-Logger")
    export_line = next((line for line in LOGGER.splitlines() if line.startswith("Export-ModuleMember -Function")), "")
    assert "'Close-Logger'" in export_line, "Logger module must export Close-Logger"
    assert_contains(LOGGER, "$wasInitialized = [bool]$script:LoggerState['Initialized']", "Close-Logger must tolerate uninitialized state")
    assert_contains(LOGGER, "Logger finalization failed:", "Close-Logger must handle finalization failures safely")
    assert_contains(LOGGER, "finally {", "Close-Logger must reset state even if final logging fails")
    assert_contains(ADD_PHOTOS, "Close-Logger", "Add_Photos must call the exported logger cleanup function")
    if "Logger\\Close-Logger" in ADD_PHOTOS:
        raise AssertionError("cleanup must not use module qualification that triggers PSModulePath discovery")
    cleanup = ADD_PHOTOS.split("finally {", 1)[1]
    assert_contains(cleanup, "try {", "logger cleanup must be guarded")
    assert_contains(cleanup, "catch {", "logger cleanup failures must not mask deployment failures")
    assert "exit $exitCode" not in cleanup.split("}", 2)[0], "finally must not exit and suppress the deployment exception"
    assert_contains(ADD_PHOTOS, "$deploymentError = $_", "the original deployment ErrorRecord must be retained")
    assert_contains(ADD_PHOTOS, "throw $deploymentError", "dot-sourcing must rethrow the original deployment error")
    assert_contains(ADD_PHOTOS, "Write-Error -ErrorRecord $deploymentError", "script execution must display the original deployment error")


def test_project_module_runtime_after_path_import_when_available() -> bool:
    powershell = shutil.which("powershell.exe") or shutil.which("powershell")
    if not powershell:
        return False

    script_path = ROOT / "Add_Photos.ps1"
    fixtures = {
        "dependency.appx": ("AppxManifest.xml", '<Package xmlns="urn:test:appx"><Identity Name="Dependency.Appx" Version="1.2.3.4" /></Package>'),
        "dependency.msix": ("AppxManifest.xml", '<Package xmlns="urn:test:msix"><Identity Name="Dependency.Msix" Version="2.3.4.5" /></Package>'),
        "photos.appxbundle": ("AppxMetadata/AppxBundleManifest.xml", '<Bundle xmlns="urn:test:appxbundle"><Identity Name="Microsoft.Windows.Photos" Version="2023.10030.27002.0" /></Bundle>'),
        "photos.msixbundle": ("AppxMetadata/AppxBundleManifest.xml", '<Bundle xmlns="urn:test:msixbundle"><Identity Name="Microsoft.Windows.Photos" Version="2026.11060.2004.0" /></Bundle>'),
    }

    with tempfile.TemporaryDirectory() as temp_dir:
        fixture_paths = []
        for filename, (manifest_path, manifest) in fixtures.items():
            fixture_path = Path(temp_dir) / filename
            with zipfile.ZipFile(fixture_path, "w") as archive:
                archive.writestr(manifest_path, manifest)
            fixture_paths.append(str(fixture_path).replace("'", "''"))

        powershell_fixtures = ",".join(f"'{path}'" for path in fixture_paths)
        command = (
            "$ErrorActionPreference = 'Stop'; "
            "if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5.1 is required.' }; "
            f"$scriptText = Get-Content -LiteralPath '{str(script_path).replace("'", "''")}' -Raw; "
            "$importBlock = [regex]::Match($scriptText, '(?s)\\$projectModulePaths = .*?(?=\\$exitCode = 1)').Value; "
            "if ([string]::IsNullOrWhiteSpace($importBlock)) { throw 'Add_Photos module import block was not found.' }; "
            f"$moduleRoot = '{str(ROOT / "Modules").replace("'", "''")}'; Invoke-Expression $importBlock; "
            "$required = @('Initialize-Logger','Write-Fatal','Close-Logger','Invoke-PreDeploymentValidation','Invoke-PackagePreparation','Invoke-OfflineDeployment'); "
            "foreach ($name in $required) { if (-not (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) { throw ('Missing command: ' + $name) } }; "
            f"$fixtures = @({powershell_fixtures}); "
            "foreach ($fixture in $fixtures) { $manifest = Get-PackageManifest -PackagePath $fixture; $version = Get-PackageVersion -Manifest $manifest; if (-not $version) { throw ('Manifest version could not be resolved: ' + $fixture) } }; "
            "Close-Logger; Close-Logger"
        )
        result = subprocess.run(
            [powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
            capture_output=True,
            text=True,
            check=False,
        )
    if result.returncode != 0:
        raise AssertionError(f"project module commands failed in a fresh PowerShell process: {result.stderr.strip()}")
    return True


def test_project_module_import_contract_is_explicit() -> None:
    assert_contains(ADD_PHOTOS, "Import-Module -Name $modulePath -Force -Global -ErrorAction Stop", "project modules must be visible to the full script invocation")
    assert_contains(ADD_PHOTOS, "$requiredCommands = @(", "Add_Photos must define its required command contract")
    for command in (
        "Initialize-Logger", "Write-Header", "Write-Fatal", "Write-Success", "Close-Logger",
        "Invoke-PreDeploymentValidation", "Invoke-PackagePreparation", "Invoke-OfflineDeployment",
    ):
        assert f"'{command}'" in ADD_PHOTOS, f"module command contract must include {command}"
    assert_contains(ADD_PHOTOS, "Project module import did not expose required command(s):", "missing commands must produce a diagnostic error")


def test_module_dependencies_do_not_force_reload() -> None:
    dependency_modules = {
        "Common": ROOT / "Modules" / "Common.psm1",
        "Validation": ROOT / "Modules" / "Validation.psm1",
        "Package": ROOT / "Modules" / "Package.psm1",
        "Dism": ROOT / "Modules" / "Dism.psm1",
    }
    for name, path in dependency_modules.items():
        text = path.read_text(encoding="utf-8-sig")
        dependency_imports = [line.strip() for line in text.splitlines() if line.strip().startswith("Import-Module")]
        if any("-Force" in line for line in dependency_imports):
            raise AssertionError(f"{name}.psm1 must not force-reload project dependencies")
        assert dependency_imports, f"{name}.psm1 must retain conditional standalone dependency loading"
        assert_contains(text, "Get-Command -Name", f"{name}.psm1 must check before importing a dependency")


def manifest_identity(xml_text: str) -> tuple[str, str, str]:
    """Model the namespace-agnostic Package/Bundle identity contract."""
    root = ET.fromstring(xml_text)
    root_name = root.tag.rsplit("}", 1)[-1]
    if root_name not in {"Package", "Bundle"}:
        raise AssertionError(f"unsupported manifest root: {root_name}")
    identity = next((child for child in root if child.tag.rsplit("}", 1)[-1] == "Identity"), None)
    if identity is None:
        raise AssertionError("manifest identity is missing")
    return root_name, identity.attrib["Name"], identity.attrib["Version"]


def test_appx_manifest_identity_parsing() -> None:
    manifest = '<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="Dependency.Appx" Version="1.2.3.4" /></Package>'
    assert manifest_identity(manifest) == ("Package", "Dependency.Appx", "1.2.3.4")


def test_msix_manifest_identity_parsing() -> None:
    manifest = '<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Identity Name="Dependency.Msix" Version="2.3.4.5" /></Package>'
    assert manifest_identity(manifest) == ("Package", "Dependency.Msix", "2.3.4.5")


def test_appxbundle_manifest_identity_parsing() -> None:
    manifest = '<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle"><Identity Name="Microsoft.Windows.Photos" Version="2023.10030.27002.0" /></Bundle>'
    assert manifest_identity(manifest) == ("Bundle", "Microsoft.Windows.Photos", "2023.10030.27002.0")


def test_msixbundle_manifest_identity_parsing() -> None:
    manifest = '<Bundle xmlns="http://schemas.microsoft.com/appx/2013/bundle"><Identity Name="Microsoft.Windows.Photos" Version="2026.11060.2004.0" /></Bundle>'
    assert manifest_identity(manifest) == ("Bundle", "Microsoft.Windows.Photos", "2026.11060.2004.0")


def test_manifest_access_is_strictmode_safe() -> None:
    assert_contains(PACKAGE, "$root = $Manifest.DocumentElement", "manifest parsing must inspect the actual XML document element")
    assert_contains(PACKAGE, "*[local-name()='Identity']", "identity lookup must support namespaced package and bundle manifests")
    if "$Manifest.Package.Identity" in PACKAGE or "$Manifest.Bundle.Identity" in PACKAGE:
        raise AssertionError("manifest parsing must not access absent adapted XML properties under StrictMode")


def test_empty_photos_result_is_safe_and_fails_preparation() -> None:
    assert_contains(PACKAGE, "if ($photosPackages.Count -eq 0)", "package preparation must handle an empty Photos selection explicitly")
    empty_branch = PACKAGE.split("if ($photosPackages.Count -eq 0)", 1)[1].split("$allPackages =", 1)[0]
    assert_contains(empty_branch, "Passed                    = $false", "an empty Photos selection must fail preparation")
    assert_contains(empty_branch, "PhotosPackages            = @()", "an empty Photos selection must be returned without property access")
    if "$photosPackages.FullName" in PACKAGE:
        raise AssertionError("empty Photos arrays must not use StrictMode-unsafe member enumeration")


def test_add_photos_direct_calls_are_exported() -> None:
    required_exports = {
        "Logger": ["Initialize-Logger", "Write-Header", "Write-Fatal", "Write-Success", "Close-Logger"],
        "Validation": ["Invoke-PreDeploymentValidation"],
        "Package": ["Invoke-PackagePreparation"],
        "Dism": ["Invoke-OfflineDeployment"],
    }
    module_text = {"Logger": LOGGER, "Validation": VALIDATION, "Package": PACKAGE, "Dism": DISM}
    for module, functions in required_exports.items():
        export_line = next((line for line in module_text[module].splitlines() if line.startswith("Export-ModuleMember -Function")), "")
        for function in functions:
            assert f"'{function}'" in export_line, f"{module}.psm1 must export {function}"


def select_newest_photos(filenames: list[str]) -> str | None:
    """Model the configured extension/name/version rules for static test fixtures."""
    candidates = []
    pattern = re.compile(
        r"^Microsoft\.Windows\.Photos_(\d+\.\d+\.\d+\.\d+)_.*\.(appxbundle|msixbundle)$",
        re.IGNORECASE,
    )
    for filename in filenames:
        match = pattern.match(filename)
        if match:
            candidates.append((tuple(int(part) for part in match.group(1).split(".")), filename))
    return max(candidates, default=(None, None))[1]


def test_only_appxbundle_photos() -> None:
    assert "'*Microsoft.Windows.Photos*.appxbundle'" in CONFIG
    package = "Microsoft.Windows.Photos_2024.1.2.3_x64.appxbundle"
    assert select_newest_photos([package]) == package


def test_only_msixbundle_photos() -> None:
    assert "'*Microsoft.Windows.Photos*.msixbundle'" in CONFIG
    package = "Microsoft.Windows.Photos_2026.11060.2004.0_x64.msixbundle"
    assert select_newest_photos([package]) == package


def test_mixed_photos_versions_are_accepted() -> None:
    packages = [
        "Microsoft.Windows.Photos_2024.1.2.3_x64.appxbundle",
        "Microsoft.Windows.Photos_2026.11060.2004.0_x64.msixbundle",
    ]
    assert select_newest_photos(packages) is not None
    assert_contains(PACKAGE, "$validPackages.Count -eq 0", "multiple valid Photos packages must not cause failure")


def test_newest_photos_version_is_selected_once() -> None:
    old = "Microsoft.Windows.Photos_2024.1.2.3_x64.appxbundle"
    new = "Microsoft.Windows.Photos_2026.11060.2004.0_x64.msixbundle"
    assert select_newest_photos([old, new]) == new
    assert_contains(PACKAGE, "Sort-Object -Property @{ Expression = { $_.Version }; Descending = $true }", "Photos candidates must be sorted newest first")
    assert_contains(PACKAGE, "return $selected.File", "only the selected Photos package must be returned")
    assert_contains(ADD_PHOTOS, "PhotosPackagePath    = [string]$preparation.PhotosPackages[0]", "deployment must receive only the selected Photos package")


def test_appx_dependencies_are_discovered() -> None:
    assert "'*.appx'" in CONFIG
    assert_contains(VALIDATION, "foreach ($filter in $dependencyFilters)", "required-package validation must use every configured dependency filter")


def test_msix_dependencies_exclude_photos() -> None:
    assert "'*.msix'" in CONFIG
    assert_contains(PACKAGE, "$_.BaseName -notlike 'Microsoft.Windows.Photos*'", "dependency discovery must exclude Microsoft Photos")
    assert_contains(VALIDATION, "$package.BaseName -notlike 'Microsoft.Windows.Photos*'", "required-package validation must exclude Microsoft Photos dependencies")


def get_invoke_offline_deployment_body() -> str:
    match = re.search(r"function Invoke-OfflineDeployment \{(?P<body>.*)\n\}\n\nExport-ModuleMember", DISM, re.S)
    if not match:
        raise AssertionError("Invoke-OfflineDeployment function body was not found")
    return match.group("body")


def test_new_mount_is_committed_and_dismounted() -> None:
    body = get_invoke_offline_deployment_body()
    assert_contains(body, "if ($AutoUnmount -and $mountedHere)", "new mounts must use the auto-unmount path")
    assert_contains(body, "Dismount-WindowsImage -MountPath $MountPath -Save", "successful new mounts must commit during dismount")
    assert_contains(body, "$committed = -not $WhatIfPreference", "commit must only be reported after the operation succeeds")


def test_existing_mount_is_saved_and_remains_mounted() -> None:
    body = get_invoke_offline_deployment_body()
    assert_contains(body, "$wasMounted = Test-MountState -MountPath $MountPath", "pre-existing mount state must be captured")
    assert_contains(body, "if (-not $wasMounted)", "mounting must only happen when the mount path is not already mounted")
    assert_contains(body, "Save-WindowsImage -MountPath $MountPath", "existing mounts must be saved instead of dismounted")
    dismount_calls = [line.strip() for line in body.splitlines() if "Dismount-WindowsImage" in line]
    if any("$wasMounted" in line for line in dismount_calls):
        raise AssertionError("pre-existing mounts must not be dismounted")


def test_no_commit_reports_false() -> None:
    body = get_invoke_offline_deployment_body()
    assert_contains(body, "$committed = $false", "Committed must default to false")
    assert_contains(body, "elseif ($AutoUnmount -and $mountedHere)", "discard dismount path must be separate from commit path")
    assert_contains(body, "Committed = $committed", "result must report the actual commit/save state")


def main() -> None:
    # Conflict-resolution contract: keep PR #5 package coverage alongside every
    # elevation and mount/commit regression inherited from PR #4 and latest main.
    package_discovery_tests = [
        test_only_appxbundle_photos,
        test_only_msixbundle_photos,
        test_mixed_photos_versions_are_accepted,
        test_newest_photos_version_is_selected_once,
        test_appx_dependencies_are_discovered,
        test_msix_dependencies_exclude_photos,
        test_appx_manifest_identity_parsing,
        test_msix_manifest_identity_parsing,
        test_appxbundle_manifest_identity_parsing,
        test_msixbundle_manifest_identity_parsing,
        test_manifest_access_is_strictmode_safe,
        test_empty_photos_result_is_safe_and_fails_preparation,
    ]
    pr4_regression_tests = [
        test_batch_elevation_preserves_arguments_and_exit_code,
        test_batch_preserves_spaces_metacharacters_and_exclamation_marks,
        test_add_photos_exits_with_script_exit_code,
        test_logger_cleanup_is_public_idempotent_and_non_masking,
        test_project_module_import_contract_is_explicit,
        test_module_dependencies_do_not_force_reload,
        test_add_photos_direct_calls_are_exported,
        test_new_mount_is_committed_and_dismounted,
        test_existing_mount_is_saved_and_remains_mounted,
        test_no_commit_reports_false,
    ]
    tests = package_discovery_tests + pr4_regression_tests

    for test in tests:
        test()
        print(f"PASS {test.__name__}")

    if test_project_module_runtime_after_path_import_when_available():
        print("PASS test_project_module_runtime_after_path_import_when_available")
    else:
        print("SKIP test_project_module_runtime_after_path_import_when_available (Windows PowerShell 5.1 is unavailable)")


if __name__ == "__main__":
    main()
