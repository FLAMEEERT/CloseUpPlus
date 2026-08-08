# CloseUpPlus Release Runbook

CloseUpPlus currently ships from GitHub Releases without an Apple Developer
membership. Release apps receive an ad-hoc code signature because macOS bundles
and embedded frameworks require coherent signing, but they are not Developer-ID
signed or Apple-notarized.

## Release contents

Each stable release contains five assets:

- `CloseUpPlus-<version>-arm64.dmg`
- `CloseUpPlus-<version>-x86_64.dmg`
- `CloseUpPlus-<version>-arm64.zip`
- `CloseUpPlus-<version>-x86_64.zip`
- `SHA256SUMS.txt`

The two app bundles are single-architecture products. The workflow verifies the
main executable, the embedded Sparkle framework, and the ad-hoc signature before
creating a draft release.

## Cut a stable release

1. Merge the intended changes to `main` and wait for CI to pass.
2. Open Actions → **Release** → **Run workflow** on `main`.
3. Enter an explicit semantic version such as `1.0.0`, or leave it empty to bump
   the latest stable tag.
4. The reusable publish workflow builds arm64 and x86_64 apps, creates both DMGs
   and ZIPs, writes SHA-256 checksums, and uploads everything to a draft release.
5. The workflow verifies all five assets before making the release public and
   marking a stable build as Latest.

No repository secrets, Apple certificate, notarization credential, Sparkle
EdDSA key, GitHub Pages branch, or Homebrew tap are required for this pipeline.

## User installation

Download the asset matching the Mac's CPU, open the DMG, and drag CloseUpPlus to
Applications. Because this build is not Apple-notarized, first launch may require
right-clicking CloseUpPlus and choosing **Open**, or approving it under System
Settings → Privacy & Security.

Users should verify a download from the directory containing the assets with:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## Automatic updates

Sparkle remains linked so a signed update channel can be restored later, but
`CLOSEUPPLUS_UNSIGNED_RELEASE` keeps its controller inert and hides the Updates
pane. Every current update is a manual GitHub Release download.

When an Apple Developer identity becomes available, adding Developer ID signing,
notarization, and a dedicated Sparkle EdDSA key is a separate release migration.
Do not enable the updater until that chain has been implemented and verified
end-to-end.

## Manual beta

`nightly.yml` is manual-only. It publishes the same ad-hoc, non-notarized assets
as a GitHub prerelease. There is no scheduled nightly or automatic beta feed.
