# Disk Steward

Disk Steward is a native macOS SwiftUI disk-health application with a persistent menu bar presence and a full application window for visualizing storage usage, performing classified archiving across disks, and reclaiming space with user-confirmed cleanup.

## Capabilities

- **Menu bar presence & full window (`REQ-001`)**: Persistent macOS menu bar icon (`MenuBarExtra`) displaying live disk usage, pending archive alerts, and cleanup proposals; opens the full window on demand and stays running when the window is closed.
- **Multi-disk capacity monitoring (`REQ-002`)**: Monitors total, used, and free space across the main disk and connected external/additional volumes with configurable refresh intervals and live mount/unmount updates. Disconnected disks are explicitly shown as `Unavailable` without presenting stale figures as live measurements.
- **Visual storage explorer (`REQ-003`)**: Select any disk or folder, scan asynchronously with progress and explicit incomplete/permission-restricted reporting, inspect a proportional squarified treemap with folder drill-down, and identify the largest items in scope.
- **Breakdowns, filters, and explained date colors (`REQ-004`)**: Inspect storage by size, file type, and modification date; filter by file type, date presets or custom date ranges, minimum size, and search text; toggle between Date Age and File Type color modes with an always-visible color legend.
- **On-demand & scheduled classified archiving (`REQ-005`)**: Configure source folders, ordered classification rules (by file type, custom extensions, filename patterns, and source folder), optional fallback destination for unmatched files, and schedules. Copies are verified with SHA-256 checksums, duplicate files with matching SHA-256 are skipped, differing filename collisions are preserved with numeric suffixes (never overwritten), deferred scheduled runs wait when a destination disk is offline and resume automatically upon reconnection, and original files are always retained until confirmed cleanup.
- **User-confirmed disk cleanup (`REQ-006`)**: Automatically discovers cleanup candidates (read-only) across verified archived originals, large/old user files, safe user & developer caches, Docker artifacts (stopped containers, unused images, dangling volumes, build cache), and `node_modules` directories. Every deletion requires explicit review and confirmation, defaults to moving files to macOS Trash (with an explicit permanent-delete option in the confirmation dialog), removes Docker artifacts via the Docker CLI, and revalidates files and SHA-256 archive copies immediately before deletion.

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
