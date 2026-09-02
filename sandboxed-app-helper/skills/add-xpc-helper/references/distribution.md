# Distributing and installing the helper

The app fetches a manifest, downloads an archive, verifies it, and hands placement to the user.

## Contents

- [The manifest](#the-manifest)
- [Hosting requirements](#hosting-requirements)
- [Selection rules](#selection-rules)
- [Integrity](#integrity)
- [The install flow](#the-install-flow)
- [Detecting what is installed](#detecting-what-is-installed)
- [The settings UI](#the-settings-ui)

## The manifest

`GET https://{{DISTRIBUTION_HOST}}/versions.json`, decoded as `[HelperVersion]`:

```json
[
  {
    "version": "2026.2",
    "build": "156",
    "releaseDate": "2026-08-11",
    "minimumSystemVersion": "26.0",
    "minimumAppVersion": "2026.2",
    "url": "https://{{DISTRIBUTION_HOST}}/downloads/{{HELPER_NAME}}-2026.2.zip",
    "size": 4720266,
    "sha256": "340650c0…",
    "notes": "Bug fixes."
  }
]
```

`version` is the helper's `CFBundleShortVersionString` — it is compared directly against what the
installed helper reports, so it must match exactly. `url` is absolute, and ideally immutable per
version. `minimumAppVersion` and `minimumSystemVersion` are the compatibility floors the app filters
on.

## Hosting requirements

- **HTTPS with valid TLS.** The sandboxed app has only `network.client`, and App Transport Security
  applies.
- A plain unauthenticated `GET`, correct `Content-Type`, stable URLs.
- **Serve the stapled archive**, so Gatekeeper passes without a network round trip.
- Keep `versions.json` and the archives in sync, and publish `size` and `sha256` for **every** entry.
- Bump `version` on every release, or update detection never fires.

The reference CI publishes both as assets on a GitHub Release and points a custom domain at them.

## Selection rules

`latestCompatibleVersion()` filters to entries this app and OS support, then takes the **highest**
version and build. Two properties this relies on, both of which have been got wrong before:

- **Order is not trusted.** A host may publish entries in any order. Taking the first entry made an
  oldest-first manifest report the *oldest* release as the latest, so updates were never detected.
- **Comparison is numeric.** `"2026.10" < "2026.2"` as plain strings. Every comparison routes through
  `VersionOrdering` so there is one rule.

Only a *strictly newer* release counts as an update, so a locally built helper running ahead of the
manifest reads as up to date rather than perpetually stale.

## Integrity

`verifyIntegrity` is strict on purpose: a manifest entry missing `size` **or** `sha256` is itself an
integrity failure, and a mismatch discards the download. The artifact runs unsandboxed on the user's
machine — there is no version of "probably fine" that is worth the alternative.

Note where authenticity is actually enforced, though: at **connect** time, by the peer code-signing
requirement. The checksum protects against a corrupted or swapped download; the requirement is what
stops an impostor being talked to at all.

## The install flow

The sandboxed app can't unarchive in-process (no subprocess) or move an app into `/Applications`, so
the last step is the user's:

1. `downloadLatest()` → verified archive in the app's container.
2. The UI presents an `NSSavePanel`, copies the archive to the chosen location, and reveals it in
   Finder.
3. The user unarchives it, moves the `.app` to Applications, and opens it once. The helper registers
   its launch agent.
4. The app connects over the verified transport.

Step 3 is the one users get stuck on. Say what to do in the UI, in order, rather than assuming.

## Detecting what is installed

Whether a helper is installed — and which build — is probed at runtime, not inferred from what was
downloaded. `HelperServiceClient.installedHelperVersion()` opens a throwaway connection and sends
`.helperInfo`; the helper answers from its own `CFBundleShortVersionString`.

Two details that are easy to get wrong:

- **Use a dedicated request, not a general connect/handshake.** If the handshake returns something
  downstream of the helper — the version of a tool it wraps, say — it is the wrong version, and it
  fails whenever that downstream thing isn't running, producing false negatives.
- **The probe needs its own no-op drop handler.** Reusing the live transport's handler means
  cancelling the probe fires the drop logic and tears down the app's real connection.

## The settings UI

Not templated, because a settings tab is inseparable from the app's own design system and string
catalog. The shape that works:

```swift
struct HelperSettingsView: View {
  @State private var status: HelperInstallationStatus = .notInstalled
  @State private var phase: Phase = .idle          // idle / checking / downloading / failed

  var body: some View {
    Form {
      Section {
        switch status {
        case .notInstalled:       Text("The helper isn't installed.")
        case .installed(let v):   Label("Helper \(v) — up to date", systemImage: "checkmark.circle")
        case .outdated(let i, let l): Text("Helper \(i) installed; \(l) available.")
        }
        // Show the latest release's size and notes even when nothing is installed: it answers
        // "what am I about to download?" before the user commits to it.
        Button(status.isInstalled ? "Update Helper" : "Download Helper") { download() }
          .disabled(phase == .downloading)
      }
      Section("Installing") {
        // The four steps above, as text. Users do not guess step 3.
      }
    }
    .task { status = await service.status() }
  }

  private func download() {
    Task {
      phase = .downloading
      do {
        let helper = try await service.downloadLatest()
        // Placement is the user's: a save panel, a copy, then reveal in Finder.
        let panel = NSSavePanel()
        panel.nameFieldStringValue = helper.suggestedFilename
        guard await panel.begin() == .OK, let destination = panel.url else { phase = .idle; return }
        try FileManager.default.copyItem(at: helper.localURL, to: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        phase = .idle
      } catch {
        phase = .failed
        // Log the technical reason; show the user something they can act on.
      }
    }
  }
}
```

Re-check `status()` after the user returns to the app — that is when the helper has usually just been
installed, and a tab still saying "not installed" is the most common complaint.
