# Chocolatey-AU Action

A GitHub Action that runs the [Chocolatey Automatic Package Updater (Chocolatey-AU)](https://github.com/chocolatey-community/chocolatey-au) module to update one or more Chocolatey packages, with optional test, push, and commit support.

> **Platform:** This action requires a `windows-latest` (or other Windows) runner because Chocolatey and the Chocolatey-AU module are Windows-only.

---

## Usage

```yaml
- uses: your-org/chocolatey-au-action@v1
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

      - uses: your-org/chocolatey-au-action@v1
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

### Single package, comma-separated paths

```yaml
- uses: your-org/chocolatey-au-action@v1
  with:
    package-paths: automatic/mypackage, automatic/anotherpackage
```

---

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `package-paths` | **Yes** | — | Newline-separated or comma-separated list of relative paths to package directories. Each directory must contain an `update.ps1` script. |
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
- uses: your-org/chocolatey-au-action@v1
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

Each path supplied via `package-paths` must be a directory containing an `update.ps1` that follows the standard Chocolatey-AU convention:

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
