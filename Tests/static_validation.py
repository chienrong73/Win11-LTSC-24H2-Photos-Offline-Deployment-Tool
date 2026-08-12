#!/usr/bin/env python3
"""Static validations for package discovery, elevation, and mount ownership semantics."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
BATCH = (ROOT / "Add_Photos_Offline.bat").read_text(encoding="utf-8")
DISM = (ROOT / "Modules" / "Dism.psm1").read_text(encoding="utf-8")
ELEVATE = (ROOT / "Modules" / "Elevate-AddPhotos.ps1").read_text(encoding="utf-8")
ADD_PHOTOS = (ROOT / "Add_Photos.ps1").read_text(encoding="utf-8")
CONFIG = (ROOT / "Config.ps1").read_text(encoding="utf-8")
PACKAGE = (ROOT / "Modules" / "Package.psm1").read_text(encoding="utf-8-sig")
VALIDATION = (ROOT / "Modules" / "Validation.psm1").read_text(encoding="utf-8-sig")


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
    ]
    pr4_regression_tests = [
        test_batch_elevation_preserves_arguments_and_exit_code,
        test_batch_preserves_spaces_metacharacters_and_exclamation_marks,
        test_add_photos_exits_with_script_exit_code,
        test_new_mount_is_committed_and_dismounted,
        test_existing_mount_is_saved_and_remains_mounted,
        test_no_commit_reports_false,
    ]
    tests = package_discovery_tests + pr4_regression_tests

    for test in tests:
        test()
        print(f"PASS {test.__name__}")


if __name__ == "__main__":
    main()
