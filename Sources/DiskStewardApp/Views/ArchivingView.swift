import DiskStewardCore
import SwiftUI

/// Classified archiving management view supporting rules, schedules, dry-run previews,
/// on-demand runs, and deferred-run visibility (REQ-005, DEC-001, DEC-002, DEC-003, DEC-004, DEC-007, DEC-008).
struct ArchivingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var editingJob: ArchiveJob?
    @State private var editingRuleID: UUID?
    @State private var isCreatingNewJob: Bool = false

    private var selectedJob: ArchiveJob? {
        if let id = appState.selectedArchiveJobID {
            return appState.configuration.archiveJobs.first { $0.id == id }
        }
        return appState.configuration.archiveJobs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            // Pending deferred runs banner (DEC-004, plan I-7)
            if !appState.pendingArchiveRuns.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Scheduled Archive Runs Waiting for Destination Disk", systemImage: "clock.badge.exclamationmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Check Disks Now") {
                            Task { await appState.evaluateArchiveSchedules() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    ForEach(appState.pendingArchiveRuns) { pending in
                        Text("• \(pending.jobName): waiting for \(pending.requiredVolumeRoots.joined(separator: ", ")) (missed runs consolidated: \(pending.missedRunCount); first scheduled \(pending.firstScheduledAt.formatted(date: .abbreviated, time: .shortened))). Resumes automatically on reconnect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.11))
                Divider()
            }

            // Safety reminder banner (DEC-003, DEC-007)
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("Classified archiving copies files using SHA-256 verification and never overwrites existing archived files. Original files are retained until you review and confirm removal in Cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.green.opacity(0.07))
            Divider()

            HSplitView {
                // Left: Archive Jobs List
                VStack(spacing: 0) {
                    HStack {
                        Text("Archive Jobs")
                            .font(.headline)
                        Spacer()
                        Button {
                            isCreatingNewJob = true
                        } label: {
                            Label("New Job", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(12)

                    Divider()

                    if appState.configuration.archiveJobs.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "archivebox")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No archive jobs configured.")
                                .font(.subheadline.weight(.medium))
                            Text("Create a job to classify files from folders like Downloads or Documents onto your storage disks.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Create Archive Job") {
                                isCreatingNewJob = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(appState.configuration.archiveJobs, selection: $appState.selectedArchiveJobID) { job in
                            let isPending = appState.pendingArchiveRuns.contains { $0.jobID == job.id }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(job.name)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    if isPending {
                                        Text("Pending Disk")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.orange.opacity(0.2))
                                            .foregroundStyle(.orange)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(job.sourceFolders.count) source(s) • \(job.rules.filter(\.isEnabled).count) rule(s)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(job.schedule.summaryDescription)
                                    .font(.caption2)
                                    .foregroundStyle(job.schedule.isEnabled ? .blue : .secondary)
                            }
                            .padding(.vertical, 4)
                            .tag(job.id)
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)

                // Right: Selected Job Details & Live Plan Preview
                if let job = selectedJob {
                    jobDetailView(job)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("Select or create an Archive Job")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(isPresented: $isCreatingNewJob) {
            ArchiveJobEditorSheet(existingJob: nil) { newJob in
                appState.addArchiveJob(newJob)
            }
            .environmentObject(appState)
        }
        .sheet(item: $editingJob, onDismiss: {
            editingRuleID = nil
        }) { job in
            ArchiveJobEditorSheet(existingJob: job, initialEditingRuleID: editingRuleID) { updated in
                appState.updateArchiveJob(updated)
            }
            .environmentObject(appState)
        }
    }

    private func jobDetailView(_ job: ArchiveJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header & Action buttons
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.name)
                            .font(.title2.weight(.bold))
                        HStack(spacing: 12) {
                            Label(job.schedule.summaryDescription, systemImage: "calendar.badge.clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let lastRun = job.lastRunAt {
                                Text("Last run: \(lastRun.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Button {
                        appState.previewArchiveJob(job)
                    } label: {
                        Label("Preview Plan", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.isBuildingPlan || appState.isArchiving)

                    if appState.isArchiving {
                        Button("Cancel Archive") {
                            appState.cancelActiveArchive()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else {
                        Button {
                            Task { await appState.runArchiveJob(job, trigger: .onDemand) }
                        } label: {
                            Label("Archive Now", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Edit") {
                        editingRuleID = nil
                        editingJob = job
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        appState.deleteArchiveJob(id: job.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help("Delete archive job configuration (does not delete any files)")
                }

                // Active progress bar if running
                if appState.isArchiving, let prog = appState.activeArchiveProgress, prog.jobID == job.id {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: Double(prog.completedItems), total: Double(max(1, prog.totalItems)))
                        Text("Copying \(prog.completedItems)/\(prog.totalItems): \(prog.currentFileName) (\(ByteFormatting.string(from: prog.bytesCopied)) copied)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Sources & Fallback
                GroupBox("Source Folders & Unmatched File Policy") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(job.sourceFolders, id: \.self) { folder in
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(folder)
                                    .font(.caption.monospaced())
                                Spacer()
                            }
                        }
                        Divider()
                        HStack {
                            Text("Unmatched files:")
                                .font(.caption.weight(.semibold))
                            if let fallback = job.fallbackDestinationPath {
                                Text("Route to fallback folder \(fallback)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.blue)
                            } else {
                                Text("Leave untouched in source folder (no fallback configured)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack {
                            Text("Folder structure:")
                                .font(.caption.weight(.semibold))
                            Text(job.preserveFolderStructure ? "Preserve relative subfolders inside destination" : "Flatten files directly into destination folder")
                                .font(.caption)
                                .foregroundStyle(job.preserveFolderStructure ? .green : .secondary)
                        }
                    }
                    .padding(6)
                }

                // Ordered Classification Rules
                GroupBox("Classification Rules (Evaluated Top to Bottom — First Match Wins)") {
                    if job.rules.isEmpty {
                        Text("No rules defined. Add rules to classify files by type, filename pattern, or source folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(8)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(job.rules.enumerated()), id: \.element.id) { idx, rule in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("#\(idx + 1)")
                                        .font(.caption.weight(.bold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 26, alignment: .leading)

                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(rule.name)
                                                .font(.subheadline.weight(.semibold))
                                            if !rule.isEnabled {
                                                Text("Disabled")
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        Text(ruleConditionSummary(rule))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.right")
                                                .font(.caption2)
                                                .foregroundStyle(.blue)
                                            Text(rule.destinationFolderPath)
                                                .font(.caption.monospaced())
                                                .foregroundStyle(.blue)
                                            Text(rule.preserveRelativeSubpath ? "• Keep Subfolders" : "• Flat")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    let available = VolumeMonitor.isDestinationVolumeAvailable(
                                        rule.destinationFolderPath,
                                        mountedVolumePaths: appState.mountedVolumePathSet
                                    )
                                    Text(available ? "Disk Ready" : "Disk Offline")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(available ? Color.green.opacity(0.15) : Color.orange.opacity(0.18))
                                        .foregroundStyle(available ? .green : .orange)
                                        .clipShape(Capsule())

                                    Button {
                                        editingRuleID = rule.id
                                        editingJob = job
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .help("Edit this classification rule")
                                }
                                if idx < job.rules.count - 1 {
                                    Divider()
                                }
                            }
                        }
                        .padding(6)
                    }
                }

                // Live Preview Plan (Dry Run)
                if appState.isBuildingPlan {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Building classified archive plan (computing SHA-256 for collision checks)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let plan = appState.previewPlan, plan.jobID == job.id {
                    planPreviewCard(plan)
                }
            }
            .padding(20)
        }
    }

    private func planPreviewCard(_ plan: ArchivePlan) -> some View {
        GroupBox("Classified Archive Plan Preview (\(plan.entries.count) file(s))") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    statPill(label: "Copy", value: "\(plan.copyCount)", color: .blue)
                    statPill(label: "Copy (Rename)", value: "\(plan.copyWithSuffixCount)", color: .purple)
                    statPill(label: "Duplicate (Skip)", value: "\(plan.duplicateCount)", color: .green)
                    statPill(label: "Unmatched (Skip)", value: "\(plan.unmatchedCount)", color: .gray)
                    if plan.unavailableCount > 0 {
                        statPill(label: "Disk Unavailable", value: "\(plan.unavailableCount)", color: .orange)
                    }
                    Spacer()
                    Text("To copy: \(ByteFormatting.string(from: plan.totalBytesToCopy))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                }

                if !plan.unavailableDestinations.isEmpty {
                    Text("Unavailable destination(s): \(plan.unavailableDestinations.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()

                ForEach(plan.entries.prefix(150)) { entry in
                    HStack(spacing: 8) {
                        actionBadge(entry.action)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.fileName)
                                .font(.caption.weight(.medium))
                            if let dest = entry.destinationPath {
                                Text("→ \(dest)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else if let note = entry.note {
                                Text(note)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let rule = entry.matchedRuleName {
                            Text(rule)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(ByteFormatting.string(from: entry.fileSize))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                if plan.entries.count > 150 {
                    Text("Showing first 150 of \(plan.entries.count) files.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private func statPill(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private func actionBadge(_ action: ArchivePlannedAction) -> some View {
        let (title, color): (String, Color) = switch action {
        case .copy: ("Copy", .blue)
        case .copyWithSuffix: ("Rename", .purple)
        case .skipDuplicate: ("Duplicate", .green)
        case .skipUnmatched: ("Unmatched", .gray)
        case .destinationUnavailable: ("Pending", .orange)
        }
        return Text(title)
            .font(.caption2.weight(.semibold))
            .frame(width: 72)
            .padding(.vertical, 2)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func ruleConditionSummary(_ rule: ArchiveRule) -> String {
        var parts: [String] = []
        if !rule.fileCategories.isEmpty {
            parts.append("Types: " + rule.fileCategories.map(\.displayName).joined(separator: ", "))
        }
        if !rule.customExtensions.isEmpty {
            parts.append("Extensions: " + rule.customExtensions.map { ".\($0)" }.joined(separator: ", "))
        }
        if rule.fileNameMatchMode != .any && !rule.fileNamePattern.isEmpty {
            parts.append("\(rule.fileNameMatchMode.displayName) '\(rule.fileNamePattern)'")
        }
        if let src = rule.sourceFolderPath {
            parts.append("Source folder: \(src)")
        }
        return parts.isEmpty ? "Matches all files" : parts.joined(separator: " • ")
    }
}
