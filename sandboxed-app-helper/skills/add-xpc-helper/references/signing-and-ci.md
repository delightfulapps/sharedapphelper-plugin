# Signing, notarization, and the release pipeline

## Contents

- [What the helper must be signed with](#what-the-helper-must-be-signed-with)
- [Notarizing locally](#notarizing-locally)
- [The Developer ID certificate for CI](#the-developer-id-certificate-for-ci)
- [Xcode Cloud pipeline](#xcode-cloud-pipeline)
- [Secrets](#secrets)
- [Why each awkward step exists](#why-each-awkward-step-exists)

## What the helper must be signed with

- **Developer ID Application**, team `{{TEAM_ID}}` — *not* an App Store or 3rd-party-Mac identity. It
  is distributed outside the App Store.
- **Hardened Runtime enabled** (`ENABLE_HARDENED_RUNTIME = YES`). Notarization requires it.
- **App Sandbox disabled** (`ENABLE_APP_SANDBOX = NO`). That is the entire reason the helper exists.
- Entitlements limited to what it actually needs. No sandbox key.
- `LSUIElement = YES` — a menubar agent, no dock icon.
- Signed **inside-out** (nested code first, then the `.app`) with `--options runtime --timestamp`.

The helper's xcconfig deliberately sets no `CODE_SIGN_IDENTITY` and no `CODE_SIGN_ENTITLEMENTS`:
Developer ID signing happens outside Xcode's automatic flow. Adding an App Store identity there is the
quickest way to produce a helper that cannot be notarized.

## Notarizing locally

Produce a Developer ID-signed app first — Xcode's Product ▸ Archive ▸ Distribute App ▸ Developer ID,
or `xcodebuild -exportArchive` with the Developer ID options plist — then:

```bash
xcrun notarytool store-credentials {{HELPER_NAME}}-notary \
  --apple-id "you@example.com" --team-id {{TEAM_ID}} --password "<app-specific-password>"
```

```bash
NOTARY_PROFILE={{HELPER_NAME}}-notary scripts/notarize-helper.sh build/{{HELPER_NAME}}.app
```

The script verifies the signature and the Hardened Runtime, zips, submits with `--wait`, staples the
ticket **into the .app**, verifies with `stapler validate` and `spctl`, then re-zips. That last re-zip
matters: the ticket lives inside the bundle, so only an archive made *after* stapling verifies on a
machine with no network.

## The Developer ID certificate for CI

**Xcode Cloud managed signing does not provide a Developer ID Application certificate.** An automatic
Developer ID export fails with *No signing certificate "Developer ID Application" found*. The
certificate has to be exported as a `.p12` and supplied as a secret.

Validate it before uploading:

```bash
scripts/validate-developer-id-p12.sh cert.p12 --emit-base64
```

It confirms the file is a valid PKCS#12 holding both the certificate **and** its private key — the
usual mistake is exporting the certificate alone, which imports cleanly and then signs nothing —
reports the expiry, and prints the exact base64 secret value.

## Xcode Cloud pipeline

On a push to `main`, an **Archive** action on the shared `{{HELPER_NAME}}` scheme runs, then
`ci_scripts/ci_post_xcodebuild.sh`. It guards on archive + `main` + not-a-PR, reads the archived
bundle identifier, and dispatches: `{{HELPER_BUNDLE_ID}}` runs `lib/release-helper.sh`, which

1. imports the Developer ID certificate into a throwaway keychain and exports a Developer ID `.app`
   with `ExportOptions-Helper.plist` (`method: developer-id`, **manual** signing), then **re-signs**
   with `--options runtime --timestamp`;
2. notarizes with `notarytool` using an App Store Connect **API key** (CI has no keychain profile),
   staples, and re-zips;
3. publishes the stapled zip and a generated `versions.json` as GitHub Release assets on the tag
   `<version>-<build>-helper`.

Point `{{DISTRIBUTION_HOST}}` at those assets.

The manifest step publishes a **single-entry array**, replacing the manifest each release. That is
fine — the app filters and sorts, so a one-entry manifest is valid — but it means older versions stop
being offered. To keep them, fetch the existing `versions.json` and merge before uploading.

## Secrets

All marked secret on the workflow:

| Secret | For |
|---|---|
| `GITHUB_ACCESS_TOKEN` | Fine-grained PAT, Contents: Read & write |
| `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_P8_BASE64` | `notarytool` |
| `DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD` | Developer ID signing |

## Why each awkward step exists

Each of these looks like it could be simplified, and each was added because the simple version failed.

- **The certificate import lives in `release-helper.sh`, not a post-clone script.** Xcode Cloud does
  not share keychains created by an earlier build script.
- **The import is diagnosed in three stages.** `security find-identity` without `-v` lists identities
  that are present but untrusted or expired; with `-v` it lists only valid ones. Comparing the two
  distinguishes "the .p12 has no private key" from "the CA chain is missing" from "the certificate is
  expired" — three failures that otherwise present identically. A fresh CI keychain often lacks
  Apple's Developer ID intermediates, so the script downloads and installs them before concluding the
  identity is unusable.
- **The app is re-signed after `-exportArchive`.** `ENABLE_HARDENED_RUNTIME = YES` is set on the
  target, but manual `-exportArchive` does not apply the flag the way the Organizer's automatic
  Developer ID export does — and notarization requires it. The re-sign is one `--deep` pass (so nested
  Mach-Os are stamped inside-out) followed by a non-deep pass reapplying the outer bundle's
  entitlements, because a deep sign would push entitlements onto nested code.
- **The runtime flag is verified by bit-testing the hex `flags=` word**, not by matching the text
  `(runtime)`. The parenthetical wording and the verbosity level at which the flags line appears both
  vary across `codesign` builds, which produced false negatives on the Xcode Cloud toolchain.
- **The manifest is built with `python3`, not a heredoc.** It emits `size` as a real number and can't
  be corrupted by a value containing a quote.
- **`size` and `sha256` are computed after stapling.** Stapling changes the bundle, so a digest taken
  before it describes an archive nobody will download.
