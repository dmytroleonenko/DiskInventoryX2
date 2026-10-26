# Disk Inventory X2

A native **Swift 6 / AppKit** adaptation of Disk Inventory X for **Apple Silicon and macOS 14 or later**. Scan a folder or mounted volume, inspect its file tree and cushion treemap, and find what occupies disk space.

[Download the latest release](https://github.com/dmytroleonenko/DiskInventoryX2/releases/latest) — Apple Silicon, macOS 14 or later. Release builds are ad-hoc signed, not notarized by Apple.

This is an independent derivative project, not an official release by the original Disk Inventory X author. It preserves the original visualization while replacing the application's implementation and adding modern filesystem handling and interactions.

## Based on

- **[Disk Inventory X](https://gitlab.com/tderlien/disk-inventory-x)** by **Tjark Derlien**. This repository retains the original Objective-C sources and Git history. The starting revision is [`4da1371b14f1158e2d923c95f645523b7c05c0bf`](https://gitlab.com/tderlien/disk-inventory-x/-/commit/4da1371b14f1158e2d923c95f645523b7c05c0bf), dated March 16, 2022.
- **[TreeMapView](https://gitlab.com/tderlien/treemapview-framework)**, also by Tjark Derlien. Its fixed-orientation strip layout, inherited cushion surfaces, lighting equations and color normalization were ported to Swift. The reference checkout used revision [`e04d93925ca201eb021ed0ce830bdc042e35096f`](https://gitlab.com/tderlien/treemapview-framework/-/commit/e04d93925ca201eb021ed0ce830bdc042e35096f). Ported files retain their original attribution.
- **[OmniGroup frameworks](https://github.com/omnigroup/OmniGroup)** were dependencies of the original application. They are not linked by the native edition and are not needed to build it.

The original application also informed file-kind classification, ranked colors, package presentation, physical-size defaults, toolbar and external statistics drawer. The new treemap is a port of the original algorithm, not a replacement based on a different layout algorithm.

## What changed from the original

| Area | Disk Inventory X2 |
| --- | --- |
| Application implementation | Standalone Swift 6 / AppKit executable, built with Command Line Tools; no OmniGroup or legacy TreeMapView runtime binaries. |
| Scan representation | Compact numeric index, pooled component names and shared cached views instead of a heavyweight object for every retained file. |
| Small files | More than 50 immediate regular files smaller than 1 MB in a directory are grouped with exact totals and kind/size histograms. An explicit detail view scans their individual names. Hardlinked files remain individual. |
| Scanning lifecycle | Background scanning with progress and cancellation. Partial progress does not replace the last completed tree or map. Startup shows a mounted-volume picker instead of immediately scanning the disk. |
| Filesystem handling | Device/inode hardlink accounting, separate allocated/logical sizes, mount boundaries, reserved-root-path exclusion, and explicit unreadable, partial, cloud-only and automount states. |
| Volume selection and accounting | Mounted-volume picker with capacity/used/free information; a whole-volume footer distinguishes scanned allocation from unaccounted or excess allocation. |
| Privacy access | Scope-aware filesystem permission preflight before traversal, localized purpose descriptions, actual denied-path reporting and manual Privacy Settings guidance. |
| Permanent deletion | Confirmed Shift–Delete and menu deletion, followed by index/map/statistics reconciliation without a full rescan on success. Surviving expansion, selection and viewport state are preserved. |
| Trash | Restored Move to Trash in File and context menus, with Command–Delete. Uses macOS's real Trash API, preserves file contents and reconciles the completed tree; it never falls back to permanent deletion. |
| Selection refresh | Restored Refresh Selection in File and context menus. Rescans the selected directory and replaces that branch in the existing index, retaining surviving expansion, selection, viewport and zoom history. |
| Map-to-tree navigation | A map click closes previously expanded branches, including remembered hidden expansions, and reveals only the selected item's ancestry. Manual tree expansion is unchanged. |
| Path copying | Click an underlined item or overview path to copy its full filesystem path. Green inline confirmation shows that copying succeeded. |
| Presentation and installation | English/Russian interface, Disk Inventory X2 branding, miniature multicolor treemap icon, and an automatically refreshed drag-install DMG with an Applications link and arrow background. |

### Deliberate limits

- The native build targets **arm64 only**. Intel Macs and macOS versions older than 14 are not supported by the supplied build script.
- This is not full feature parity with the original. The legacy preferences, inspector/help bundles, selection-list functionality and creator-code options are not implemented in the native application. Free/other-space treemap tiles are not implemented; volume differences appear in a separate footer.
- Scans are snapshots. There is no persistent scan cache, filesystem watcher or automatic incremental refresh. Ordinary folder zoom reuses the completed index; Rescan performs a new scan.
- Logical/allocated totals are not a measurement of uniquely reclaimable APFS storage. Clones, snapshots, metadata, shared-container volumes, inaccessible files and concurrent changes can prevent totals from matching Finder. Unaccounted space is not labeled as an exact snapshot size.
- The original external statistics drawer uses `NSDrawer`. Apple deprecated it, so the compiler emits a deprecation warning; it is retained intentionally for the original layout.

## Build

Requirements:

- Apple Silicon Mac running macOS 14 or later.
- Apple Command Line Tools with **Swift 6 or later**. Full Xcode is not required.
- **Python 3.10 or later**, available as `python3`, for DMG packaging only.
- Network access on the first build to install the pinned packaging tools.

```sh
git clone git@github.com:dmytroleonenko/DiskInventoryX2.git
cd DiskInventoryX2
./build-native.sh
open "build/Disk Inventory X2.dmg"
```

`./BuildRelease.sh` invokes the same native build. Every successful build refreshes:

- `build/Disk Inventory X2.app`
- `build/Disk Inventory X2.dmg`

The scripts compile Swift directly, copy resources, generate the bundled icon, ad-hoc sign the application and package a checksum-verified, read-only DMG. Packaging tools are pinned in [Packaging/requirements.txt](Packaging/requirements.txt) and installed into `build/.dmg-tools`; neither those tools nor Python are included in the installed application. Finder layout is generated without requesting Finder Automation access. A failed packaging operation retains the previous usable DMG.

To repackage an existing signed build without recompiling:

```sh
./package-dmg.sh
```

The old `.xcodeproj` and Objective-C sources are retained for provenance, not as the supported build entry point. Optional local reference checkouts under `Dependencies/` are ignored by Git and are not required by the native build or smoke suite.

## Automated GitHub releases

The [release workflow](.github/workflows/release.yml) runs on a GitHub-hosted macOS 15 ARM64 machine whenever a stable `vX.Y.Z` tag is pushed. It runs the complete native/AppKit smoke suite, stamps the tag version and workflow build number into the app before signing, then builds and publishes:

- `DiskInventoryX2-X.Y.Z-arm64.dmg` — drag-and-drop installer.
- `DiskInventoryX2-X.Y.Z-arm64.app.zip` — the complete application bundle, including its executable, icon, privacy descriptions and localizations.
- `SHA256SUMS.txt` — SHA-256 checksums for both downloads.

GitHub also provides source archives for the tag. The app ZIP is the binary distribution; the bare Mach-O executable alone is not a replacement for the app bundle.

To publish the next release after committing and pushing the reviewed sources:

```sh
git tag -a v2.0.1 -m "Disk Inventory X2 2.0.1"
git push origin v2.0.1
```

The workflow can also be launched manually from Actions by providing an existing release tag. Tags/releases are not overwritten automatically. The release is created as a draft and made public only after its assets are uploaded. If an interrupted upload leaves an unpublished draft, remove that draft before retrying; do not move a published version tag.

Publishing uses GitHub's built-in `GITHUB_TOKEN` with `contents: write`; no personal access token or Apple signing secrets are required for the current ad-hoc builds. Developer ID signing and notarization would require a separate Apple Developer setup. Workflow actions are pinned to immutable commit SHAs.

To exercise exactly the same versioned packaging locally:

```sh
./release-native.sh v2.0.0 1
```

Assets are written to `build/release/`. Local builds can also override `APP_VERSION=X.Y.Z` and `APP_BUILD=N`; the checked-in plist is not rewritten by the build. Verify downloaded files from their directory with `shasum -a 256 -c SHA256SUMS.txt`.


## Install and use

1. Open the DMG and drag **Disk Inventory X2** onto **Applications**, following the arrow.
2. Quit any running copy before replacing it. Launch `/Applications/Disk Inventory X2.app`, then eject the image.
3. Choose a mounted volume, or use **File → Open Folder…**. The startup volume `/` includes the merged System/Data namespace; its physical Data mount is not scanned a second time.
4. Click map tiles to locate files in the tree. Click an underlined path beneath the map to copy it; the full path is copied even if its display is truncated.
5. Use **View → Use Physical File Sizes** or **Show Package Contents** to change the completed presentation without rescanning. **File → Rescan All** starts a fresh scan.

To scan a specific folder at launch:

```sh
open "build/Disk Inventory X2.app" --args "$HOME/Downloads"
```

**Shift–Delete and File → Delete Permanently… bypass the Trash.** A confirmation names the exact target; deleting a directory removes its contents. The scan/view root, synthetic groups, mounted-volume placeholders and incomplete/unmeasured entries cannot be deleted. Deletion does not use elevated privileges.

**Move to Trash** is available in the tree/map context menus, the File menu and with **Command–Delete**. It uses the system Trash location and collision handling, without a permanent-delete fallback. If Trash is inside the scanned scope, its destination branch is refreshed too; moving an item to Trash does not imply disk space was freed.

**Refresh Selection** updates a selected directory inside the existing document, including newly added, removed and resized files. Selecting a file refreshes its containing directory; if a selected directory has disappeared, its nearest surviving parent is refreshed. Unrelated branches remain snapshots. Permission checks and cancellation use the same scan flow, and in-progress results do not replace the completed document. Cached small-file detail views are refreshed with their exact member names.

A newly observed hardlink can refer to an outside file whose inode was not retained in the old compact snapshot. In that case the application explains the broader refresh and rescans the original scope rather than double-counting the new alias. **Rescan All** (`Command–R`) remains available for an explicit full refresh.

The local build is **ad-hoc signed, not Developer ID signed or notarized**. This is not an Apple-notarized distribution. Packaging does not install anything into `/Applications` automatically.

## Permissions and scan safety

Before filesystem traversal, the application checks relevant standard protected locations inside the selected scope: Desktop, Documents, Downloads, photo/media libraries, contact/calendar/reminder files, cloud providers, application containers and known protected application data. Whole-disk and `/Users` scans also discover immediate local home directories. Checks run serially off the UI thread, allowing macOS to ask for access at the beginning of the scan.

macOS remembers permission decisions and may not ask again. **Full Disk Access cannot be granted by the app.** Add the installed copy in **System Settings → Privacy & Security → Full Disk Access**, restart it if macOS requests that, then scan again. A Unix permission or ACL denial is not proof that Full Disk Access is missing. Denied paths remain explicit; the user can cancel, scan available files for an incomplete result, or open Privacy Settings.

Preflight discovery is shallow, not a second recursive disk scan. Apple does not publish an exhaustive stable list of protected paths, so a deeply nested nonstandard library can still prompt when traversal reaches it. An already displayed system consent dialog must be answered; cancelling the app's scan cannot forcibly dismiss that dialog.

The scanner does not read file contents or request Photos/Contacts/EventKit API access to personal records. Symbolic links and special files are excluded. Kernel I/O policy prevents dataless materialization and implicit automount; nested mounted filesystems remain visible for explicit separate scanning. Cloud-only and inaccessible directories are not presented as empty. Permission decisions are never reset by the application.

## Verification

Run the native scanner and AppKit smoke suite from a logged-in graphical session:

```sh
./test-native.sh
```

For captures of the native views:

```sh
./test-native.sh build/deletion-tree-state.png
```

This also writes `scan-presentation.png`, `permission-preflight.png` and `selection-interactions.png` beside the requested image. Tests use temporary filesystem fixtures and actual AppKit windows/events. They cover hardlinks, mount/path boundaries, sparse files, access denials, scoped permission handling, map/tree selection, path copying, selection refresh and removal-state preservation. Clipboard checks use an isolated named pasteboard. Trash tests make real file/directory/package moves, verify the preserved bytes and clean up only exact UUID-owned Trash entries; they never empty the user's Trash. Refresh checks cover unchanged siblings, cached zoom/detail views, disappeared directories, status recovery and new-hardlink full-scan reconciliation.

The suite does not reset TCC, approve real OS consent prompts, mount remote shares or download cloud-only files. Native backing-view captures are not full-screen recordings. Local build outputs, captures and measurements are intentionally not checked into this repository.

## Repository layout

- [`Native/`](Native/) — standalone Swift application, filesystem index/scanner, rendering, UI and localized resources.
- [`Tests/`](Tests/) — executable native scanner/AppKit smoke scenarios.
- [`Packaging/`](Packaging/) — source icon representations, DMG background/layout and pinned packaging requirements.
- [`build-native.sh`](build-native.sh), [`package-dmg.sh`](package-dmg.sh), [`release-native.sh`](release-native.sh), [`test-native.sh`](test-native.sh) — build, installer/release packaging and verification entry points.
- Original Objective-C sources, resources and Xcode project at the repository root — retained upstream implementation and copyright notices.

## License and attribution

Disk Inventory X2 is distributed under **GNU GPL version 3 or later (`GPL-3.0-or-later`)**, following the original program's version-3-or-later notices. See [LICENSE](LICENSE), the GPLv3 text selected for this repository, and the original [COPYING](COPYING). The upstream copyright and attribution notices are retained.

Original Disk Inventory X and the ported TreeMapView algorithms: **Copyright Tjark Derlien**. Third-party code and resources retain their respective notices and licenses; inclusion in the historical source tree does not replace those terms.
