# Disk Steward

Disk Steward is a native macOS SwiftUI disk-health application with a persistent menu bar presence and a full application window for visualizing storage usage, performing classified archiving across disks, and reclaiming space with user-confirmed cleanup.

## Capabilities

- **Menu bar presence & full window (`REQ-001`)**: Persistent macOS menu bar icon (`MenuBarExtra`) displaying live disk usage, pending archive alerts, and cleanup proposals; opens the full window on demand and stays running when the window is closed.
- **Multi-disk capacity monitoring (`REQ-002`)**: Monitors total, used, and free space across the main disk and connected external/additional volumes with configurable refresh intervals and live mount/unmount updates. Disconnected disks are explicitly shown as `Unavailable` without presenting stale figures as live measurements.
- **Visual storage explorer (`REQ-003`, `DEC-010`, `DEC-012`)**: Select any disk or folder, scan asynchronously with a parallel POSIX scanner and persistent LZFSE scan cache with live incremental `FSEvents` folder updates, inspect a single-level proportional structural treemap sized strictly by allocated bytes with contrasting adjacent colors and instant folder drill-down, and identify the largest items in scope.
- **Breakdowns and folder filters (`REQ-004`, `DEC-010`)**: Inspect storage by size, file type, and modification date; filter any disk or drilled-down folder by single or combined file types, custom extensions (e.g. `zip, mp4`), date presets or custom date ranges, minimum size, and search text.
- **On-demand & scheduled classified archiving (`REQ-005`)**: Configure source folders, ordered classification rules (by file type, custom extensions, filename patterns, and source folder), optional fallback destination for unmatched files, and schedules. Copies are verified with SHA-256 checksums, duplicate files with matching SHA-256 are skipped, differing filename collisions are preserved with numeric suffixes (never overwritten), deferred scheduled runs wait when a destination disk is offline and resume automatically upon reconnection, and original files are always retained until confirmed cleanup.
- **User-confirmed & rule-based disk cleanup (`REQ-006`, `DEC-011`, `DEC-013`)**: Run targeted recursive folder cleanup rules (pick any folder and match files by category such as Code, Videos, or Archives, custom extensions like `.zip`, filename pattern, age, or minimum size; save reusable rules; or launch directly from any folder in Storage Explorer), alongside automatic read-only discovery of verified archived originals, large/old user files, safe user & developer caches, Docker artifacts, and `node_modules` directories. Unwanted proposals or entire folders can be persistently dismissed/ignored and restored at any time from the Ignored list. Every deletion requires explicit review and confirmation, defaults to moving files to macOS Trash (with an explicit permanent-delete option in the confirmation dialog), removes Docker artifacts via the Docker CLI, and revalidates files and SHA-256 archive copies immediately before deletion.

## Versioning Policy

Disk Steward follows **Semantic Versioning** (`MAJOR.MINOR.PATCH`), tracked in:

- [`VERSION`](VERSION)
- `Sources/DiskStewardCore/DiskStewardVersion.swift` (`fallbackVersion` and `fallbackBuild`)
- Generated `Contents/Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`)

Use the version bump script before releasing:

```bash
./scripts/bump-version.sh 1.0.0
```

## Build, Test, and Local Release / Deployment

Requires macOS 14+ and Swift 6 / Xcode Command Line Tools.

```bash
# Run automated unit tests
swift test

# Build debug binary
swift build

# Build, test, sign, deploy to /Applications/Disk Steward.app, and verify deployed version
./scripts/release.sh
```

## Specification

The product specification, approved requirements, accepted decisions, and implementation plan are maintained in [`docs/features/disk-steward/`](docs/features/disk-steward/overview.md).

### Requirements

- `REQ-001` Menu bar access
- `REQ-002` Disk space monitoring
- `REQ-003` Visual storage exploration
- `REQ-004` Storage breakdowns and filters
- `REQ-005` Selective folder backups
- `REQ-006` Disk cleanup
