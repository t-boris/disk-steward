# Disk Steward

Build a personal macOS disk-health application with a menu bar presence and a full window for understanding storage usage, backing up selected folders, and reclaiming space across the main disk and additional storage disks.

## Problem

Files, backups, caches, and development artifacts consume space across multiple disks. The user lacks a unified visual way to understand that usage, identify cleanup opportunities, and coordinate backups with freeing space.

## Scope

Proposed first version, pending confirmation: a personal macOS application with menu bar access, monitoring of the main and additional connected disks, a treemap explorer, size/type/date analysis, on-demand backups of selected folders, and user-confirmed cleanup of files and development artifacts. Proposed deferrals: automatic backup triggers, automatic cleanup, and automatic backup retention management. The requirements below capture the stated product intent; deferred capabilities are not yet commitments for the first release.

## Specification

The confirmed brief, decisions and requirements are in [`docs/features/disk-steward/`](docs/features/disk-steward/overview.md). Open this folder in MarkView to continue them.

### Requirements

- REQ-001 Menu bar access
- REQ-002 Disk space monitoring
- REQ-003 Visual storage exploration
- REQ-004 Storage breakdowns and filters
- REQ-005 Selective folder backups
- REQ-006 Disk cleanup
