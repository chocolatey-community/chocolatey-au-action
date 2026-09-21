[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helper: Resolve package paths, expanding wildcard patterns
# ---------------------------------------------------------------------------

function Resolve-PackagePaths {
    param(
        [string[]]$Patterns
    )

    $results = @()

    foreach ($pattern in $Patterns) {
        $directories = Get-ChildItem -Path $pattern -Directory -ErrorAction SilentlyContinue

        if (-not $directories) {
            Write-Host "::warning::Pattern '$pattern' did not match any directories; skipping."
            continue
        }

        foreach ($dir in $directories) {
            $hasUpdateScript = Test-Path -LiteralPath (Join-Path $dir.FullName 'update.ps1') -PathType Leaf

            if (-not $hasUpdateScript) {
                Write-Host "::warning::Pattern '$pattern' matched directory '$($dir.FullName)' but no update.ps1 script was found; skipping."
                continue
            }

            $results += $dir.FullName
        }
    }

    return $results
}

function Clear-AUFunction {
    [CmdletBinding()]
    Param(
        [Parameter()]
        [String[]]
        $FunctionList = @('au_GetLatest', 'au_SearchReplace', 'au_BeforeUpdate', 'au_AfterUpdate')
    )
     
    $FunctionList |
    ForEach-Object { 
        Remove-Item -Path "Function:\$_" -ErrorAction SilentlyContinue 
    }
}

# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

$rawPaths = ($env:AU_PACKAGE_PATHS -split '[\r\n,]+') |
ForEach-Object { $_.Trim() } |
Where-Object { $_ -ne '' }

if (-not $rawPaths) {
    Write-Output '::error::No package paths were provided via the package-paths input.'
    exit 1
}

$packagePaths = @(Resolve-PackagePaths -Patterns $rawPaths)

if ($packagePaths.Count -eq 0) {
    Write-Output '::error::No valid package directories found after resolving paths.'
    exit 1
}

$push = $env:AU_PUSH -eq 'true'
$apiKey = $env:AU_API_KEY
$chocoServer = if ([string]::IsNullOrWhiteSpace($env:AU_CHOCO_SERVER)) {
    'https://push.chocolatey.org/'
}
else {
    $env:AU_CHOCO_SERVER
}
$testInstall = $env:AU_TEST_INSTALL -eq 'true'

# ---------------------------------------------------------------------------
# Process each package
# ---------------------------------------------------------------------------

$allResults = [System.Collections.Generic.List[object]]::new()
$hasErrors = $false

foreach ($packagePath in $packagePaths) {

    $result = [ordered]@{
        Package   = $packagePath
        Status    = 'NoUpdate'
        NupkgPath = $null
        Version   = $null
        Error     = $null
    }

    Write-Output "::group::Updating: $packagePath"

    try {
        Push-Location -LiteralPath $packagePath

        try {
            Clear-AUFunction
            $updateOutput = & .\update.ps1

            # AU returns an AUPackage object with a .Result string array.
            # Fall back to treating the raw output as text if .Result is absent.
            $resultLines = if ($null -ne $updateOutput -and $null -ne $updateOutput.Result) {
                @($updateOutput.Result)
            }
            else {
                @($updateOutput | ForEach-Object { "$_" })
            }

            Write-Output ($resultLines -join "`n")

            # Determine whether the package was actually updated.
            $isUpdated = if ($null -ne $updateOutput.Updated) {
                [bool]$updateOutput.Updated
            }
            else {
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
                }
                else {
                    # Fallback: regex match for any .nupkg path in quotes
                    $match = $resultLines | ForEach-Object {
                        if ($_ -match "['\`"]([^'\`"]+\.nupkg)['\`"]") { $Matches[1] }
                    } | Select-Object -First 1
                    $result.NupkgPath = $match
                }

                # Extract version from AU object properties.
                if ($null -ne $updateOutput.NuspecVersion) {
                    $result.Version = $updateOutput.NuspecVersion.ToString()
                }
                elseif ($null -ne $updateOutput.RemoteVersion) {
                    $result.Version = $updateOutput.RemoteVersion.ToString()
                }

                $versionSuffix = if ($result.Version) { " to v$($result.Version)" } else { '' }
                Write-Output "Package updated${versionSuffix}."

                # --- Test install ---
                if ($testInstall) {
                    if ($result.NupkgPath) {
                        Write-Output 'Running Test-Package...'
                        try {
                            Test-Package -Install -Nu $result.NupkgPath
                            Write-Output 'Test-Package succeeded.'
                        }
                        catch {
                            Write-Output "::warning::Test-Package failed for '${packagePath}': $_"
                        }
                    }
                    else {
                        Write-Output "::warning::test-install is enabled but no .nupkg path was found for '${packagePath}'; skipping."
                    }
                }

                # --- Push ---
                if ($push) {
                    if ([string]::IsNullOrWhiteSpace($apiKey)) {
                        Write-Output "::warning::push is enabled but api-key is empty; skipping push for '${packagePath}'."
                    }
                    elseif (-not $result.NupkgPath) {
                        Write-Output "::warning::push is enabled but no .nupkg path was found for '${packagePath}'; skipping push."
                    }
                    else {
                        Write-Output "Pushing $($result.NupkgPath) to ${chocoServer} ..."
                        choco push $result.NupkgPath --source $chocoServer --key $apiKey
                    }
                }

            }
            else {
                Write-Output 'No new version found; nothing to do.'
            }

        }
        finally {
            Pop-Location
        }

    }
    catch {
        $result.Status = 'Error'
        $result.Error = $_.ToString()
        $hasErrors = $true
        Write-Output "::error::Failed to process '${packagePath}': $_"
    }

    Write-Output '::endgroup::'
    $allResults.Add($result)
}

# ---------------------------------------------------------------------------
# GitHub Step Summary
# ---------------------------------------------------------------------------

$summaryRows = $allResults | ForEach-Object {
    $icon = switch ($_.Status) {
        'Updated' { ':white_check_mark:' }
        'NoUpdate' { ':fast_forward:' }
        'Error' { ':x:' }
        default { ':grey_question:' }
    }
    $ver = if ($_.Version) { $_.Version } else { '—' }
    "| ``$($_.Package)`` | $icon $($_.Status) | $ver |"
}

@(
    '# Chocolatey-AU Update Results'
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
    Write-Output '::error::One or more packages encountered errors during processing.'
    exit 1
}
