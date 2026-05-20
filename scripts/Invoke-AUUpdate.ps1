[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

#region Helpers

function Write-ActionGroup([string]$Title) { Write-Host "::group::$Title" }
function Close-ActionGroup                 { Write-Host "::endgroup::" }
function Write-ActionError([string]$Msg)   { Write-Host "::error::$Msg" }
function Write-ActionWarning([string]$Msg) { Write-Host "::warning::$Msg" }

#endregion

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

$packagePaths = ($env:AU_PACKAGE_PATHS -split '[\r\n,]+') |
    ForEach-Object { $_.Trim() } |
    Where-Object   { $_ -ne '' }

if (-not $packagePaths) {
    Write-ActionError 'No package paths were provided via the package-paths input.'
    exit 1
}

$push        = $env:AU_PUSH        -eq 'true'
$apiKey      = $env:AU_API_KEY
$chocoServer = if ([string]::IsNullOrWhiteSpace($env:AU_CHOCO_SERVER)) {
    'https://push.chocolatey.org/'
} else {
    $env:AU_CHOCO_SERVER
}
$testInstall = $env:AU_TEST_INSTALL -eq 'true'

# ---------------------------------------------------------------------------
# Process each package
# ---------------------------------------------------------------------------

$allResults = [System.Collections.Generic.List[object]]::new()
$hasErrors  = $false

foreach ($packagePath in $packagePaths) {

    $result = [ordered]@{
        Package   = $packagePath
        Status    = 'NoUpdate'
        NupkgPath = $null
        Version   = $null
        Error     = $null
    }

    Write-ActionGroup "Updating: $packagePath"

    try {
        if (-not (Test-Path -LiteralPath $packagePath -PathType Container)) {
            throw "Path '$packagePath' does not exist or is not a directory."
        }

        Push-Location -LiteralPath $packagePath

        try {
            $updateOutput = & .\update.ps1

            # AU returns an AUPackage object with a .Result string array.
            # Fall back to treating the raw output as text if .Result is absent.
            $resultLines = if ($null -ne $updateOutput -and $null -ne $updateOutput.Result) {
                @($updateOutput.Result)
            } else {
                @($updateOutput | ForEach-Object { "$_" })
            }

            Write-Host ($resultLines -join "`n")

            # Determine whether the package was actually updated.
            $isUpdated = if ($null -ne $updateOutput.Updated) {
                [bool]$updateOutput.Updated
            } else {
                -not ($resultLines | Where-Object { $_ -match 'No new version found' })
            }

            if ($isUpdated) {
                $result.Status = 'Updated'

                # Extract nupkg path from AU result lines.
                # AU wraps the path in single quotes: 'C:\...\pkg.1.0.0.nupkg'
                $nupkgLine = $resultLines |
                    Where-Object { $_ -like "*.nupkg'*" } |
                    Select-Object -First 1

                if ($nupkgLine) {
                    $result.NupkgPath = ($nupkgLine -split "'")[1]
                } else {
                    # Fallback: regex match for any .nupkg path in quotes
                    $match = $resultLines | ForEach-Object {
                        if ($_ -match "['\`"]([^'\`"]+\.nupkg)['\`"]") { $Matches[1] }
                    } | Select-Object -First 1
                    $result.NupkgPath = $match
                }

                # Extract version from AU object properties.
                if ($null -ne $updateOutput.NuspecVersion) {
                    $result.Version = $updateOutput.NuspecVersion.ToString()
                } elseif ($null -ne $updateOutput.RemoteVersion) {
                    $result.Version = $updateOutput.RemoteVersion.ToString()
                }

                $versionSuffix = if ($result.Version) { " to v$($result.Version)" } else { '' }
                Write-Host "Package updated${versionSuffix}."

                # --- Test install ---
                if ($testInstall) {
                    if ($result.NupkgPath) {
                        Write-Host 'Running Test-Package...'
                        try {
                            Test-Package -Install -Nu $result.NupkgPath
                            Write-Host 'Test-Package succeeded.'
                        } catch {
                            Write-ActionWarning "Test-Package failed for '${packagePath}': $_"
                        }
                    } else {
                        Write-ActionWarning "test-install is enabled but no .nupkg path was found for '${packagePath}'; skipping."
                    }
                }

                # --- Push ---
                if ($push) {
                    if ([string]::IsNullOrWhiteSpace($apiKey)) {
                        Write-ActionWarning "push is enabled but api-key is empty; skipping push for '${packagePath}'."
                    } elseif (-not $result.NupkgPath) {
                        Write-ActionWarning "push is enabled but no .nupkg path was found for '${packagePath}'; skipping push."
                    } else {
                        Write-Host "Pushing $($result.NupkgPath) to ${chocoServer} ..."
                        choco push $result.NupkgPath --source $chocoServer --key $apiKey
                    }
                }

            } else {
                Write-Host 'No new version found; nothing to do.'
            }

        } finally {
            Pop-Location
        }

    } catch {
        $result.Status = 'Error'
        $result.Error  = $_.ToString()
        $hasErrors     = $true
        Write-ActionError "Failed to process '${packagePath}': $_"
    }

    Close-ActionGroup
    $allResults.Add($result)
}

# ---------------------------------------------------------------------------
# GitHub Step Summary
# ---------------------------------------------------------------------------

$summaryRows = $allResults | ForEach-Object {
    $icon = switch ($_.Status) {
        'Updated'  { ':white_check_mark:' }
        'NoUpdate' { ':fast_forward:' }
        'Error'    { ':x:' }
        default    { ':grey_question:' }
    }
    $ver = if ($_.Version) { $_.Version } else { '—' }
    "| ``$($_.Package)`` | $icon $($_.Status) | $ver |"
}

@(
    '# Chocolatey AU Update Results'
    ''
    '| Package | Status | Version |'
    '|---------|--------|---------|'
    ($summaryRows -join "`n")
) -join "`n" | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

# ---------------------------------------------------------------------------
# GitHub Output
# ---------------------------------------------------------------------------

$resultsJson = $allResults | ConvertTo-Json -Compress -Depth 5
"results=$resultsJson" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append

# ---------------------------------------------------------------------------
# Exit
# ---------------------------------------------------------------------------

if ($hasErrors) {
    Write-ActionError 'One or more packages encountered errors during processing.'
    exit 1
}
