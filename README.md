# Chocolatey-AU Action

A GitHub Action that runs the [Chocolatey Automatic Package Updater (Chocolatey-AU)](https://github.com/chocolatey-community/chocolatey-au) module to update one or more Chocolatey packages, with optional test, push, and commit support.

Version `2.0` introduces wildcard path support for `package-paths`, so you can target many package directories without listing each one explicitly.

> **Platform:** This action requires a `windows-latest` (or other Windows) runner because Chocolatey and the Chocolatey-AU module are Windows-only.

---

## Usage

```yaml
- uses: chocolatey-community/chocolatey-au-action@2.0
  with:
    package-paths: |
      automatic/mypackage
      automatic/anotherpackage
```

### Full example

```yaml
name: Chocolatey-AU Update

on:
  schedule:
    - cron: '0 0 * * *'
  workflow_dispatch:

defaults:
  run:
    shell: pwsh

jobs:
  update:
    runs-on: windows-latest

    steps:
      - uses: actions/checkout@v4

      - uses: chocolatey-community/chocolatey-au-action@2.0
        with:
          package-paths: |
            automatic/mypackage
            automatic/anotherpackage
          push: true
          api-key: ${{ secrets.CHOCO_API_KEY }}
          test-install: true
          commit-changes: true
          commit-message: 'chore: Chocolatey-AU update [skip ci]'
```

### Wildcard patterns

Instead of listing every package directory individually, you can use a wildcard pattern to match all subdirectories under a given folder:

```yaml
- uses: chocolatey-community/chocolatey-au-action@2.0
  with:
    package-paths: automatic/*
```

This expands to every **immediate subdirectory** of `automatic/` that contains an `update.ps1` script (e.g. `automatic/mypackage`, `automatic/anotherpackage`, etc.). The wildcard is not recursive — `automatic/*` matches one level deep, not nested subdirectories like `automatic/group/pkg`.

You can mix and match explicit paths with wildcard patterns:

```yaml
- uses: chocolatey-community/chocolatey-au-action@2.0
  with:
    package-paths: |
      automatic/*
      manual/specialpackage
```

### Single package, comma-separated paths

```yaml
- uses: chocolatey-community/chocolatey-au-action@2.0
  with:
    package-paths: automatic/mypackage, automatic/anotherpackage
```

---

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `package-paths` | **Yes** | — | Newline-separated or comma-separated list of relative paths to package directories. Wildcard patterns (e.g. `automatic/*`) are supported and expand to all matching subdirectories containing an `update.ps1` script. |
| `push` | No | `false` | Push updated packages to a Chocolatey feed. |
| `api-key` | No | `''` | API key used to authenticate with the Chocolatey feed. Required when `push` is `true`. |
| `choco-server` | No | `https://push.chocolatey.org/` | Chocolatey server URL to push packages to. |
| `test-install` | No | `false` | Run `Test-Package -Install` to verify the package installs correctly before pushing. |
| `commit-changes` | No | `false` | Commit updated `.nuspec` and `.ps1` files back to the repository. Requires the checkout token to have write permission. |
| `commit-message` | No | `chore: apply Chocolatey-AU package updates [skip ci]` | Commit message used when `commit-changes` is `true`. |

---

## Outputs

| Output | Description |
|--------|-------------|
| `results` | JSON array summarising the update result for each package. Each element contains `Package`, `Status` (`Updated` \| `NoUpdate` \| `Error`), `NupkgPath`, `Version`, and `Error`. |

### Using the `results` output

```yaml
- uses: chocolatey-community/chocolatey-au-action@2.0
  id: au
  with:
    package-paths: automatic/mypackage

- run: |
    $results = '${{ steps.au.outputs.results }}' | ConvertFrom-Json
    foreach ($r in $results) {
      Write-Host "$($r.Package): $($r.Status)"
    }
  shell: pwsh
```

---

## Package directory structure

Each path supplied via `package-paths` must be a directory containing an `update.ps1` that follows the standard Chocolatey-AU convention. When using wildcard patterns, only subdirectories that contain an `update.ps1` are included — others are silently skipped.

```
automatic/
  mypackage/
    mypackage.nuspec
    update.ps1          ← required
    tools/
      chocolateyInstall.ps1
```

A minimal `update.ps1`:

```powershell
import-module chocolatey-au

function global:au_GetLatest {
  # return @{ Version = '1.2.3'; URL = '...' }
}

function global:au_SearchReplace { }

update
```

---

## Permissions

When `commit-changes` is `true`, the action commits and pushes using the built-in `github-actions[bot]` identity. Ensure the workflow token has `contents: write` permission:

```yaml
permissions:
  contents: write
```

---

## License

[MIT](LICENSE)
