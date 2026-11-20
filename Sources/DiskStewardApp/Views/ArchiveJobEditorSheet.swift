import DiskStewardCore
import SwiftUI

/// Modal editor for configuring an ArchiveJob's sources, classification rules, fallback folder, and schedule (REQ-005).
struct ArchiveJobEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let existingJob: ArchiveJob?
    let onSave: (ArchiveJob) -> Void

    @State private var name: String = ""
    @State private var sourceFolders: [String] = []
    @State private var rules: [ArchiveRule] = []
    @State private var fallbackDestinationPath: String = ""
    @State private var includeSubdirectories: Bool = true
    @State private var skipHiddenFiles: Bool = true
    @State private var schedule: ArchiveSchedule = ArchiveSchedule()

    // Inline new/edit rule draft state
    @State private var ruleDraftName: String = ""
    @State private var ruleDraftCategories: Set<FileCategory> = [.images]
    @State private var ruleDraftExtensions: String = ""
    @State private var ruleDraftMatchMode: FileNameMatchMode = .any
    @State private var ruleDraftPattern: String = ""
    @State private var ruleDraftSourceFolder: String = ""
    @State private var ruleDraftDestination: String = ""
    @State private var ruleDraftPreserveSubpath: Bool = false

    private let weekdayNames = [
        (1, "Sunday"), (2, "Monday"), (3, "Tuesday"), (4, "Wednesday"),
        (5, "Thursday"), (6, "Friday"), (7, "Saturday")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(existingJob == nil ? "New Classified Archive Job" : "Edit Archive Job")
                    .font(.title3.weight(.bold))
                Spacer()
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Basic info
                    GroupBox("Job Details") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Job Name (e.g., Downloads Organizer)", text: $name)
                                .textFieldStyle(.roundedBorder)
                            HStack(spacing: 20) {
                                Toggle("Include subdirectories", isOn: $includeSubdirectories)
                                Toggle("Skip hidden files", isOn: $skipHiddenFiles)
                            }
                        }
                        .padding(6)
                    }

                    // Source Folders
                    GroupBox("Source Folders") {
                        VStack(alignment: .leading, spacing: 8) {
                            if sourceFolders.isEmpty {
                                Text("Add one or more folders to archive (for example, Downloads, Documents, or Projects).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(sourceFolders, id: \.self) { folder in
                                    HStack {
                                        Text(folder).font(.caption.monospaced())
                                        Spacer()
                                        Button(role: .destructive) {
                                            sourceFolders.removeAll { $0 == folder }
                                        } label: {
                                            Image(systemName: "minus.circle")
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }
                            }
                            HStack {
                                Button {
                                    if let picked = appState.chooseFolder(title: "Choose Source Folder") {
                                        if !sourceFolders.contains(picked) {
                                            sourceFolders.append(picked)
                                        }
                                    }
                                } label: {
                                    Label("Add Source Folder…", systemImage: "folder.badge.plus")
                                }
                                .buttonStyle(.bordered)

                                let downloads = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
                                if FileManager.default.fileExists(atPath: downloads) && !sourceFolders.contains(downloads) {
                                    Button("Add ~/Downloads") {
                                        sourceFolders.append(downloads)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(6)
                    }

                    // Classification Rules
                    GroupBox("Classification Rules (Priority Order: First Match Wins)") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("\(rules.count) rule(s) configured")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    if let root = appState.chooseFolder(title: "Choose Archive Destination Root for Starter Rules") {
                                        let starter = ArchiveRuleEngine.starterRules(destinationRoot: root)
                                        rules.append(contentsOf: starter)
                                    }
                                } label: {
                                    Label("Add Starter Rules (Pictures, Movies, Installers…)", systemImage: "wand.and.stars")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            ForEach(Array(rules.enumerated()), id: \.element.id) { idx, rule in
                                HStack(spacing: 8) {
                                    Text("#\(idx + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rule.name).font(.subheadline.weight(.medium))
                                        Text("→ \(rule.destinationFolderPath)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.blue)
                                    }
                                    Spacer()
                                    Button {
                                        if idx > 0 { rules.swapAt(idx, idx - 1) }
                                    } label: {
                                        Image(systemName: "arrow.up")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(idx == 0)

                                    Button {
                                        if idx < rules.count - 1 { rules.swapAt(idx, idx + 1) }
                                    } label: {
                                        Image(systemName: "arrow.down")
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(idx == rules.count - 1)

                                    Button(role: .destructive) {
                                        rules.remove(at: idx)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(6)
                                .background(Color.primary.opacity(0.04))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }

                            Divider()

                            // Add custom rule builder
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Add Classification Rule")
                                    .font(.caption.weight(.semibold))

                                HStack {
                                    TextField("Rule Name (e.g., Screenshots or Project PDFs)", text: $ruleDraftName)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("Extra Extensions (e.g., dmg, pkg, iso)", text: $ruleDraftExtensions)
                                        .textFieldStyle(.roundedBorder)
                                }

                                // File Categories checkboxes
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(FileCategory.allCases) { cat in
                                            let active = ruleDraftCategories.contains(cat)
                                            Button {
                                                if active {
                                                    ruleDraftCategories.remove(cat)
                                                } else {
                                                    ruleDraftCategories.insert(cat)
                                                }
                                            } label: {
                                                Text(cat.displayName)
                                                    .font(.caption)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 3)
                                                    .background(active ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
                                                    .clipShape(Capsule())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }

                                HStack {
                                    Picker("Filename", selection: $ruleDraftMatchMode) {
                                        ForEach(FileNameMatchMode.allCases) { mode in
                                            Text(mode.displayName).tag(mode)
                                        }
                                    }
                                    .frame(width: 210)

                                    if ruleDraftMatchMode != .any {
                                        TextField("Pattern (e.g., Screenshot* or Invoice)", text: $ruleDraftPattern)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }

                                HStack {
                                    TextField("Optional Source Folder Restriction (blank = any source)", text: $ruleDraftSourceFolder)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Choose…") {
                                        if let picked = appState.chooseFolder(title: "Optional Source Folder Filter") {
                                            ruleDraftSourceFolder = picked
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }

                                HStack {
                                    TextField("Destination Folder Path", text: $ruleDraftDestination)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Choose…") {
                                        if let picked = appState.chooseFolder(title: "Choose Destination Folder") {
                                            ruleDraftDestination = picked
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }

                                HStack {
                                    Toggle("Preserve relative subfolders inside destination", isOn: $ruleDraftPreserveSubpath)
                                        .font(.caption)
                                    Spacer()
                                    Button {
                                        addDraftRule()
                                    } label: {
                                        Label("Add Rule", systemImage: "plus.circle.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(ruleDraftDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                        }
                        .padding(6)
                    }

                    // Optional Fallback Folder (DEC-008)
                    GroupBox("Unmatched Files (Optional Fallback Folder)") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Files not matching any rule above will be sent here if configured; otherwise they remain untouched in the source folder.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                TextField("Optional Fallback Destination Folder (leave blank to skip unmatched)", text: $fallbackDestinationPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Choose…") {
                                    if let picked = appState.chooseFolder(title: "Choose Optional Fallback Folder") {
                                        fallbackDestinationPath = picked
                                    }
                                }
                                .buttonStyle(.bordered)
                                if !fallbackDestinationPath.isEmpty {
                                    Button("Clear") {
                                        fallbackDestinationPath = ""
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .padding(6)
                    }

                    // Schedule Configuration (DEC-004, REQ-005)
                    GroupBox("Automated Archiving Schedule") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Enable scheduled automated archiving", isOn: $schedule.isEnabled)

                            if schedule.isEnabled {
                                Picker("Frequency", selection: $schedule.frequency) {
                                    ForEach(ArchiveScheduleFrequency.allCases.filter { $0 != .manual }) { freq in
                                        Text(freq.displayName).tag(freq)
                                    }
                                }
                                .frame(width: 240)

                                if schedule.frequency == .weekly {
                                    Picker("Day of Week", selection: $schedule.weekday) {
                                        ForEach(weekdayNames, id: \.0) { day in
                                            Text(day.1).tag(day.0)
                                        }
                                    }
                                    .frame(width: 240)
                                }

                                if schedule.frequency == .daily || schedule.frequency == .weekly {
                                    HStack {
                                        Stepper("Hour: \(String(format: "%02d", schedule.hour))", value: $schedule.hour, in: 0...23)
                                        Stepper("Minute: \(String(format: "%02d", schedule.minute))", value: $schedule.minute, in: 0...59, step: 5)
                                    }
                                } else if schedule.frequency == .customIntervalMinutes {
                                    Stepper("Every \(schedule.intervalMinutes) minutes", value: $schedule.intervalMinutes, in: 5...1440, step: 5)
                                }

                                Text("If a destination disk is disconnected at the scheduled time, the run remains pending and automatically resumes once the disk reconnects.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(existingJob == nil ? "Create Archive Job" : "Save Changes") {
                    saveJob()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sourceFolders.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 720, height: 680)
        .onAppear {
            if let existing = existingJob {
                name = existing.name
                sourceFolders = existing.sourceFolders
                rules = existing.rules
                fallbackDestinationPath = existing.fallbackDestinationPath ?? ""
                includeSubdirectories = existing.includeSubdirectories
                skipHiddenFiles = existing.skipHiddenFiles
                schedule = existing.schedule
            } else {
                name = "Downloads Archive"
                let downloads = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
                if FileManager.default.fileExists(atPath: downloads) {
                    sourceFolders = [downloads]
                }
                schedule = ArchiveSchedule(isEnabled: false, frequency: .daily, hour: 2, minute: 0)
            }
        }
        .onChange(of: schedule.isEnabled) { _, enabled in
            if enabled && schedule.frequency == .manual {
                schedule.frequency = .daily
            }
        }
    }

    private func addDraftRule() {
        let dest = ruleDraftDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return }
        let exts = ruleDraftExtensions
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let ruleName = ruleDraftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = ruleName.isEmpty
            ? (ruleDraftCategories.isEmpty ? "Custom Rule" : ruleDraftCategories.map(\.displayName).sorted().joined(separator: ", "))
            : ruleName

        let rule = ArchiveRule(
            name: resolvedName,
            fileCategories: Array(ruleDraftCategories),
            customExtensions: exts,
            fileNameMatchMode: ruleDraftMatchMode,
            fileNamePattern: ruleDraftPattern,
            sourceFolderPath: ruleDraftSourceFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ruleDraftSourceFolder.trimmingCharacters(in: .whitespacesAndNewlines),
            destinationFolderPath: dest,
            preserveRelativeSubpath: ruleDraftPreserveSubpath
        )
        rules.append(rule)
        ruleDraftName = ""
        ruleDraftExtensions = ""
        ruleDraftPattern = ""
        ruleDraftDestination = ""
    }

    private func saveJob() {
        let trimmedFallback = fallbackDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = ArchiveJob(
            id: existingJob?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceFolders: sourceFolders,
            rules: rules,
            fallbackDestinationPath: trimmedFallback.isEmpty ? nil : trimmedFallback,
            includeSubdirectories: includeSubdirectories,
            skipHiddenFiles: skipHiddenFiles,
            schedule: schedule,
            createdAt: existingJob?.createdAt ?? Date(),
            lastRunAt: existingJob?.lastRunAt
        )
        onSave(job)
        dismiss()
    }
}
