---
type: plan
feature: disk-steward
title: "Disk Steward: Storage Analysis, Classified Archiving, and Confirmed Cleanup"
issues:
  - id: I-1
    title: Create the menu bar presence and application shell
    summary: Provide a persistent macOS menu bar entry and a full application window that opens from it. Deliver the application shell with English UI text and verify that menu bar access remains available when the full window is closed.
    requirements: [REQ-001]
    decisions: [DEC-005]
  - id: I-2
    title: Monitor capacity across main and additional disks
    summary: Display total, used, and free space for the main disk and connected additional storage disks, refreshing figures during ongoing monitoring. Represent disk connection and disconnection without presenting unavailable disks as current measurements. Define refresh timing and unavailable-state behavior before implementation.
    requirements: [REQ-002]
    decisions: [DEC-005]
  - id: I-3
    title: Scan selected disks and folders for storage usage
    summary: Allow the user to select a disk or folder and collect file and folder sizes for storage exploration. Expose scan progress and incomplete results so inaccessible or interrupted portions are distinguishable from fully analyzed content. Resolve size accounting and traversal rules before implementation.
    requirements: [REQ-003]
    decisions: [DEC-005]
  - id: I-4
    title: Build the treemap explorer and storage filters
    summary: Render analyzed storage as a treemap with areas proportional to item sizes and make the largest items identifiable within the selected scope. Support size-based exploration, file-type and date breakdowns, file-type and date filters, and explained date-color distinctions. Define the date field and size measure used by the visualization before implementation.
    requirements: [REQ-003, REQ-004]
    decisions: [DEC-005]
  - id: I-5
    title: Configure classified archiving rules and routing
    summary: Let the user configure source folders and destination routing by file type, file name, and source folder. Produce a classified archive plan that maps matching files to configured destinations. Resolve rule precedence, unmatched-file behavior, and destination-name collisions before implementation.
    requirements: [REQ-005]
    decisions: [DEC-001, DEC-002, DEC-005]
  - id: I-6
    title: Execute on-demand classified archiving
    summary: Execute classified archiving on demand by copying matching files to their configured destinations while retaining originals. Report completed, failed, and interrupted copies. Define copy verification, retry behavior, and handling of files changed during copying before implementation; archive completion must not authorize source deletion.
    requirements: [REQ-005]
    decisions: [DEC-001, DEC-002, DEC-003, DEC-005]
  - id: I-7
    title: Schedule archive jobs and resume deferred runs
    summary: Allow a user-defined archiving schedule and execute configured archive jobs automatically. Keep runs pending while their destination disk is unavailable and resume when it becomes available. Resolve missed-run consolidation, overlapping runs, and interruption recovery before implementation. Scheduled execution retains originals.
    requirements: [REQ-005]
    decisions: [DEC-001, DEC-003, DEC-004, DEC-005]
  - id: I-8
    title: Detect cleanup candidates and prepare proposals
    summary: Automatically identify cleanup opportunities among user files, caches, Docker artifacts, and node_modules directories, and prepare proposals showing item locations and estimated reclaimable space. Define eligibility and exclusions for each category before implementation. Discovery and proposal preparation must leave data intact.
    requirements: [REQ-006]
    decisions: [DEC-001, DEC-002, DEC-003, DEC-005]
  - id: I-9
    title: Execute user-confirmed cleanup and archived-original removal
    summary: Present proposed cleanup items for user review and require confirmation before every deletion operation, including removal of archived originals. Declining leaves the proposed data intact. Resolve deletion mechanics and archive-verification requirements before implementation, and revalidate selected items before execution so confirmation applies to the data actually deleted. Report partial failures and completed deletions.
    requirements: [REQ-005, REQ-006]
    decisions: [DEC-001, DEC-002, DEC-003, DEC-005]
updated: 2026-11-20
schema: 1
---

# Implementation plan — Disk Steward

## I-1: Create the menu bar presence and application shell

Provide a persistent macOS menu bar entry and a full application window that opens from it. Deliver the application shell with English UI text and verify that menu bar access remains available when the full window is closed.

Requirements: REQ-001
Decisions: DEC-005

## I-2: Monitor capacity across main and additional disks

Display total, used, and free space for the main disk and connected additional storage disks, refreshing figures during ongoing monitoring. Represent disk connection and disconnection without presenting unavailable disks as current measurements. Define refresh timing and unavailable-state behavior before implementation.

Requirements: REQ-002
Decisions: DEC-005

## I-3: Scan selected disks and folders for storage usage

Allow the user to select a disk or folder and collect file and folder sizes for storage exploration. Expose scan progress and incomplete results so inaccessible or interrupted portions are distinguishable from fully analyzed content. Resolve size accounting and traversal rules before implementation.

Requirements: REQ-003
Decisions: DEC-005

## I-4: Build the treemap explorer and storage filters

Render analyzed storage as a treemap with areas proportional to item sizes and make the largest items identifiable within the selected scope. Support size-based exploration, file-type and date breakdowns, file-type and date filters, and explained date-color distinctions. Define the date field and size measure used by the visualization before implementation.

Requirements: REQ-003, REQ-004
Decisions: DEC-005

## I-5: Configure classified archiving rules and routing

Let the user configure source folders and destination routing by file type, file name, and source folder. Produce a classified archive plan that maps matching files to configured destinations. Resolve rule precedence, unmatched-file behavior, and destination-name collisions before implementation.

Requirements: REQ-005
Decisions: DEC-001, DEC-002, DEC-005

## I-6: Execute on-demand classified archiving

Execute classified archiving on demand by copying matching files to their configured destinations while retaining originals. Report completed, failed, and interrupted copies. Define copy verification, retry behavior, and handling of files changed during copying before implementation; archive completion must not authorize source deletion.

Requirements: REQ-005
Decisions: DEC-001, DEC-002, DEC-003, DEC-005

## I-7: Schedule archive jobs and resume deferred runs

Allow a user-defined archiving schedule and execute configured archive jobs automatically. Keep runs pending while their destination disk is unavailable and resume when it becomes available. Resolve missed-run consolidation, overlapping runs, and interruption recovery before implementation. Scheduled execution retains originals.

Requirements: REQ-005
Decisions: DEC-001, DEC-003, DEC-004, DEC-005

## I-8: Detect cleanup candidates and prepare proposals

Automatically identify cleanup opportunities among user files, caches, Docker artifacts, and node_modules directories, and prepare proposals showing item locations and estimated reclaimable space. Define eligibility and exclusions for each category before implementation. Discovery and proposal preparation must leave data intact.

Requirements: REQ-006
Decisions: DEC-001, DEC-002, DEC-003, DEC-005

## I-9: Execute user-confirmed cleanup and archived-original removal

Present proposed cleanup items for user review and require confirmation before every deletion operation, including removal of archived originals. Declining leaves the proposed data intact. Resolve deletion mechanics and archive-verification requirements before implementation, and revalidate selected items before execution so confirmation applies to the data actually deleted. Report partial failures and completed deletions.

Requirements: REQ-005, REQ-006
Decisions: DEC-001, DEC-002, DEC-003, DEC-005
