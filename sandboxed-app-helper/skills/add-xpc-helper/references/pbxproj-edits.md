# Project file edits

Adding a target, a copy-files phase and a package dependency cannot be done in an xcconfig — those are
structural, and they live in `project.pbxproj`. This is the one step where the skill leaves plain-text
build settings behind, so it is worth being careful.

## Contents

- [Before editing](#before-editing)
- [1. Product file reference](#1-product-file-reference)
- [2. Source group](#2-source-group)
- [3. Build configurations](#3-build-configurations)
- [4. Launch agent file reference and copy phase](#4-launch-agent-file-reference-and-copy-phase)
- [5. Package product dependency](#5-package-product-dependency)
- [6. The target itself](#6-the-target-itself)
- [7. Register it in the project](#7-register-it-in-the-project)
- [8. Shared scheme](#8-shared-scheme)
- [Verifying](#verifying)
- [Doing it in Xcode instead](#doing-it-in-xcode-instead)

## Before editing

- **Quit Xcode.** It can crash on an externally modified project file, and it may overwrite the edit.
- **Commit or stash first.** `git checkout -- *.xcodeproj/project.pbxproj` is the recovery path, and
  it only works if there is something to go back to.
- **Note the project's `objectVersion`.** The stanzas below are for `objectVersion = 90` (Xcode 26),
  which supports `PBXFileSystemSynchronizedRootGroup` — a folder reference that picks up files
  automatically, with no per-file entries. For older projects, see the note in step 2.
- **Object identifiers are 24 uppercase hex characters** and must be unique within the file. Generate
  them rather than inventing them by hand:
  ```bash
  for i in $(seq 8); do openssl rand -hex 12 | tr 'a-f' 'A-F'; done
  ```

Each stanza goes inside the `/* Begin … section */` … `/* End … section */` block for its `isa` type.
Create the section if the project has none.

## 1. Product file reference

`PBXFileReference` section:

```
		HELPERPRODUCTREF00000000 /* {{HELPER_NAME}}.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = {{HELPER_NAME}}.app; sourceTree = BUILT_PRODUCTS_DIR; };
```

Add it to the `Products` group's `children` list too.

## 2. Source group

Create the directory `{{HELPER_NAME}}/` next to the app's sources and put the helper's Swift files in
it. Then, in the `PBXFileSystemSynchronizedRootGroup` section:

```
		HELPERGROUP000000000000 /* {{HELPER_NAME}} */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = {{HELPER_NAME}};
			sourceTree = "<group>";
		};
```

Add `HELPERGROUP000000000000` to the project's main group `children`.

> **Older projects** (`objectVersion` below 77, or a project not otherwise using synchronized groups):
> use a plain `PBXGroup` with explicit `PBXFileReference` children, and list each source file as a
> `PBXBuildFile` in the target's `Sources` phase. Match whatever the app target already does — a
> project that mixes both styles confuses Xcode's own migration.

## 3. Build configurations

`XCBuildConfiguration` section — note the **empty** `buildSettings`. Everything comes from the
xcconfig; an inline value here would silently override it.

```
		HELPERDEBUGCONFIG000000 /* Debug */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = HELPERXCCONFIGREF000000 /* {{HELPER_NAME}}.xcconfig */;
			buildSettings = {
			};
			name = Debug;
		};
		HELPERRELEASECONFIG0000 /* Release */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = HELPERXCCONFIGREF000000 /* {{HELPER_NAME}}.xcconfig */;
			buildSettings = {
			};
			name = Release;
		};
```

`HELPERXCCONFIGREF000000` is a `PBXFileReference` for `Config/{{HELPER_NAME}}.xcconfig`, alongside the
project's other xcconfig references:

```
		HELPERXCCONFIGREF000000 /* {{HELPER_NAME}}.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; name = {{HELPER_NAME}}.xcconfig; path = Config/{{HELPER_NAME}}.xcconfig; sourceTree = "<group>"; };
```

Then the list, in `XCConfigurationList`:

```
		HELPERCONFIGLIST0000000 /* Build configuration list for PBXNativeTarget "{{HELPER_NAME}}" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				HELPERDEBUGCONFIG000000 /* Debug */,
				HELPERRELEASECONFIG0000 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
```

## 4. Launch agent file reference and copy phase

The plist must end up at `Contents/Library/LaunchAgents/{{SERVICE_NAME}}.plist` inside the helper's
`.app`, because that is where `SMAppService.agent(plistName:)` looks. A copy-files phase puts it there.

`PBXFileReference`:

```
		LAUNCHAGENTREF00000000 /* {{SERVICE_NAME}}.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; name = {{SERVICE_NAME}}.plist; path = LaunchAgents/{{SERVICE_NAME}}.plist; sourceTree = "<group>"; };
```

`PBXBuildFile`:

```
		LAUNCHAGENTBUILDFILE000 /* {{SERVICE_NAME}}.plist in Embed Launch Agents */ = {isa = PBXBuildFile; fileRef = LAUNCHAGENTREF00000000 /* {{SERVICE_NAME}}.plist */; };
```

`PBXCopyFilesBuildPhase`:

```
		EMBEDLAUNCHAGENTS00000 /* Embed Launch Agents */ = {
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = Contents/Library/LaunchAgents;
			dstSubfolder = Wrapper;
			files = (
				LAUNCHAGENTBUILDFILE000 /* {{SERVICE_NAME}}.plist in Embed Launch Agents */,
			);
			name = "Embed Launch Agents";
			runOnlyForDeploymentPostprocessing = 0;
		};
```

`dstSubfolder = Wrapper` with that `dstPath` is what lands the file inside `Contents/Library`. Older
projects spell this `dstSubfolderSpec = 16`; match the project's existing copy phases.

Add this phase **only to the helper target**. The app can't register an agent, so a copy on the app
target does nothing but confuse the next reader.

## 5. Package product dependency

`XCSwiftPackageProductDependency`:

```
		HELPERPKGDEP0000000000 /* {{PACKAGE_NAME}} */ = {
			isa = XCSwiftPackageProductDependency;
			productName = {{PACKAGE_NAME}};
		};
```

`PBXBuildFile`, for the target's `Frameworks` phase:

```
		HELPERPKGBUILDFILE00000 /* {{PACKAGE_NAME}} in Frameworks */ = {isa = PBXBuildFile; productRef = HELPERPKGDEP0000000000 /* {{PACKAGE_NAME}} */; };
```

The package directory itself is a plain folder reference in the main group:

```
		PACKAGEFOLDERREF0000000 /* {{PACKAGE_NAME}} */ = {isa = PBXFileReference; lastKnownFileType = wrapper; path = {{PACKAGE_NAME}}; sourceTree = "<group>"; };
```

Repeat the dependency and build-file entries (with fresh identifiers) for the **app** target — both
processes need the contract. If the app already gets the package transitively through another local
package, that is enough; a second direct dependency is harmless but redundant.

## 6. The target itself

`PBXNativeTarget`:

```
		HELPERTARGET0000000000 /* {{HELPER_NAME}} */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = HELPERCONFIGLIST0000000 /* Build configuration list for PBXNativeTarget "{{HELPER_NAME}}" */;
			buildPhases = (
				HELPERSOURCESPHASE0000 /* Sources */,
				HELPERFRAMEWORKSPHASE0 /* Frameworks */,
				HELPERRESOURCESPHASE00 /* Resources */,
				EMBEDLAUNCHAGENTS00000 /* Embed Launch Agents */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				HELPERGROUP000000000000 /* {{HELPER_NAME}} */,
			);
			name = {{HELPER_NAME}};
			packageProductDependencies = (
				HELPERPKGDEP0000000000 /* {{PACKAGE_NAME}} */,
			);
			productName = {{HELPER_NAME}};
			productReference = HELPERPRODUCTREF00000000 /* {{HELPER_NAME}}.app */;
			productType = "com.apple.product-type.application";
		};
```

The three phases it references are ordinary empty ones — `PBXSourcesBuildPhase`,
`PBXFrameworksBuildPhase` (holding `HELPERPKGBUILDFILE00000` in its `files`), `PBXResourcesBuildPhase`.
With a synchronized group the sources and resources phases stay empty; the group supplies the files.

The product type is **`com.apple.product-type.application`**, not `xpc-service`. It is a real app: it
has a menubar item, the user launches and quits it, and it is distributed on its own.

## 7. Register it in the project

In the `PBXProject` object, add the target to `targets`, and add an entry to
`TargetAttributes` if the project uses one:

```
				HELPERTARGET0000000000 = {
					CreatedOnToolsVersion = 26.0;
				};
```

## 8. Shared scheme

Create `{{APP_NAME}}.xcodeproj/xcshareddata/xcschemes/{{HELPER_NAME}}.xcscheme` with the helper's
`BuildableReference` pointing at `HELPERTARGET0000000000` and `{{HELPER_NAME}}.app`, and the **Archive
action set to the Release configuration**. Xcode Cloud can only archive a *shared* scheme, so without
this the release pipeline has nothing to run. The quickest correct way to get one is to let Xcode
generate it (Product ▸ Scheme ▸ Manage Schemes ▸ tick *Shared*) after the target exists.

## Verifying

Immediately after editing, before anything else:

```bash
plutil -lint {{APP_NAME}}.xcodeproj/project.pbxproj
xcodebuild -project {{APP_NAME}}.xcodeproj -list
```

`-list` should show `{{HELPER_NAME}}` as both a target and a scheme. If `plutil` reports a syntax
error, revert rather than trying to repair it by hand — a half-parsed project file fails in confusing
ways much later.

Then confirm the settings resolve and the target builds:

```bash
xcodebuild -project {{APP_NAME}}.xcodeproj -target {{HELPER_NAME}} -configuration Release -showBuildSettings | grep -E 'ENABLE_APP_SANDBOX|ENABLE_HARDENED_RUNTIME|PRODUCT_BUNDLE_IDENTIFIER'
xcodebuild -project {{APP_NAME}}.xcodeproj -scheme {{HELPER_NAME}} -configuration Release build
```

Finally, confirm the plist landed where `SMAppService` will look for it:

```bash
ls "$(xcodebuild -project {{APP_NAME}}.xcodeproj -scheme {{HELPER_NAME}} -configuration Release -showBuildSettings \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2}')/{{HELPER_NAME}}.app/Contents/Library/LaunchAgents/"
```

## Doing it in Xcode instead

Every edit above has a UI equivalent, and for a project that is open and being actively worked on, the
UI is the safer path:

| Edit | Xcode |
|---|---|
| Target, product, group, phases | File ▸ New ▸ Target ▸ macOS App, named `{{HELPER_NAME}}` |
| xcconfig attachment | Project ▸ Info ▸ Configurations, set the target's Debug and Release |
| Copy phase | Target ▸ Build Phases ▸ + ▸ New Copy Files Phase; Destination *Wrapper*, Subpath `Contents/Library/LaunchAgents` |
| Package dependency | Target ▸ General ▸ Frameworks, Libraries, and Embedded Content ▸ + |
| Shared scheme | Product ▸ Scheme ▸ Manage Schemes ▸ tick *Shared* |

After using the UI, delete any settings Xcode wrote inline into the new target's `buildSettings` — it
adds a starter set, and each one silently overrides the xcconfig.
