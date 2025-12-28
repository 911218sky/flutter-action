<#
.SYNOPSIS
  Create and push release tags for this GitHub Action.

.DESCRIPTION
  - Creates an annotated version tag (e.g. v1.0.0) and pushes it to remote.
  - Updates a floating major tag (default: v1) to point at that version and pushes it (force-with-lease).

  This matches the common GitHub Actions versioning style:
    uses: owner/repo@v1

.PARAMETER Version
  Version string like 1.0.0 or v1.0.0

.PARAMETER Remote
  Git remote name to push to (default: origin)

.PARAMETER MajorTag
  Floating major tag name to update (default: v1)

.PARAMETER Commit
  Commit-ish to tag (default: HEAD)

.PARAMETER SkipCleanCheck
  Skip checking for a clean working tree

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\release.ps1 -Version v1.0.0 -SkipCleanCheck

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\release.ps1 -Version v1.0.0

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\release.ps1 -Version 1.0.1 -MajorTag v1
#>

param(
  [Parameter(Mandatory = $true)]
  [string]$Version,

  [string]$Remote = "origin",

  [string]$MajorTag = "",

  [string]$Commit = "HEAD",

  [switch]$SkipCleanCheck
)

$ErrorActionPreference = "Stop"

function Exec {
  param([Parameter(Mandatory=$true)][string]$Cmd)
  Write-Host "==> $Cmd"
  & powershell -NoProfile -Command $Cmd
  if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Cmd" }
}

function ExecGit {
  param([Parameter(Mandatory=$true)][string[]]$Args)
  Write-Host ("==> git " + ($Args -join " "))
  & git @Args
  if ($LASTEXITCODE -ne 0) { throw ("git failed ($LASTEXITCODE): " + ($Args -join " ")) }
}

function GitOut {
  param([Parameter(Mandatory=$true)][string[]]$Args)
  Write-Host ("==> git " + ($Args -join " "))
  $out = & git @Args
  if ($LASTEXITCODE -ne 0) { throw ("git failed ($LASTEXITCODE): " + ($Args -join " ")) }
  return ($out | Out-String).Trim()
}

# Normalize version tag to vX.Y.Z
$v = $Version.Trim()
if (-not $v.StartsWith("v")) { $v = "v$Version" }

if ($v -notmatch '^v\d+\.\d+\.\d+([\-+].+)?$') {
  throw "Version must look like v1.2.3 (optionally with -suffix). Got: '$v'"
}

# Compute floating major tag if not provided (v1 from v1.2.3)
if ([string]::IsNullOrWhiteSpace($MajorTag)) {
  if ($v -match '^v(\d+)\.') {
    $MajorTag = "v$($Matches[1])"
  } else {
    throw "Unable to derive major tag from version: $v"
  }
}

# Ensure git exists
ExecGit @("--version") | Out-Null

# Basic sanity checks
ExecGit @("rev-parse", "--is-inside-work-tree") | Out-Null

if (-not $SkipCleanCheck) {
  $dirty = (git status --porcelain)
  if ($LASTEXITCODE -ne 0) { throw "git status failed" }
  if ($dirty) {
    throw "Working tree is not clean. Commit/stash changes first, or pass -SkipCleanCheck."
  }
}

# Ensure remote exists
$remotes = git remote
if ($LASTEXITCODE -ne 0) { throw "git remote failed" }
if (-not ($remotes -contains $Remote)) {
  throw "Remote '$Remote' not found. Existing remotes: $($remotes -join ', ')"
}

ExecGit @("fetch", "--tags", "--force", "--prune", $Remote)

# Resolve the target commit hash (so we can compare if tag already exists)
$targetCommit = GitOut @("rev-parse", $Commit)

# Create annotated tag (or reuse if it already exists and points to the same commit)
$existingCommit = ""
try {
  # For annotated tags, `refs/tags/<tag>^{}` dereferences to the underlying commit.
  $existingCommit = GitOut @("rev-parse", "refs/tags/$v^{}")
} catch {
  $existingCommit = ""
}

if (-not [string]::IsNullOrWhiteSpace($existingCommit)) {
  if ($existingCommit -ne $targetCommit) {
    throw "Tag '$v' already exists but points to a different commit ($existingCommit != $targetCommit). Choose a new version, or delete/move the tag intentionally."
  }
  Write-Host "Tag '$v' already exists and matches target commit ($targetCommit). Skipping tag creation."
} else {
  ExecGit @("tag", "-a", $v, $Commit, "-m", "release $v")
}

# Push the version tag (safe, not forced)
ExecGit @("push", $Remote, $v)

# Update floating major tag to point at this version
# Use force-with-lease to reduce risk of overwriting someone else's move.
ExecGit @("tag", "-f", $MajorTag, $v)
# For tags, plain `--force-with-lease` can fail with "(stale info)" because tags don't have remote-tracking refs.
# We explicitly read the remote tag value and pass it as the expected old value.
$remoteLine = (& git ls-remote --tags $Remote "refs/tags/$MajorTag") 2>$null
$remoteHash = ""
if ($LASTEXITCODE -eq 0 -and $remoteLine) {
  foreach ($line in ($remoteLine -split "`r?`n")) {
    $parts = $line -split "\s+"
    if ($parts.Length -ge 2 -and $parts[1] -eq "refs/tags/$MajorTag") {
      $remoteHash = $parts[0]
      break
    }
  }
}

if ([string]::IsNullOrWhiteSpace($remoteHash)) {
  ExecGit @("push", "--force", $Remote, $MajorTag)
} else {
  ExecGit @("push", "--force-with-lease=refs/tags/$MajorTag`:$remoteHash", $Remote, $MajorTag)
}

Write-Host ""
Write-Host "Done."
Write-Host "Version tag pushed: $v"
Write-Host "Floating tag updated: $MajorTag -> $v"
Write-Host ""
Write-Host "Users can reference:"
Write-Host "  uses: <owner>/<repo>@$MajorTag"


