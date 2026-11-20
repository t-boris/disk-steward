import DiskStewardCore
import SwiftUI

/// Modal editor for configuring an ArchiveJob's sources, classification rules, fallback folder, and schedule (REQ-005).
struct ArchiveJobEditorSheet: View {
    private struct EditableSourceFolder: Identifiable {
        let id: UUID = UUID()
        var path: String
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let existingJob: ArchiveJob?
    let initialEditingRuleID: UUID?
    let onSave: (ArchiveJob) -> Void

    init(
        existingJob: ArchiveJob?,
        initialEditingRuleID: UUID? = nil,
        onSave: @escaping (ArchiveJob) -> Void
    ) {
        self.existingJob = existingJob
        self.initialEditingRuleID = initialEditingRuleID
        self.onSave = onSave
    }

    @State private var name: String = ""
    @State private var sourceFolders: [EditableSourceFolder] = []
    @State private var rules: [ArchiveRule] = []
    @State private var fallbackDestinationPath: String = ""
    @State private var includeSubdirectories: Bool = true
    @State private var preserveFolderStructure: Bool = true
    @State private var skipHiddenFiles: Bool = true
    @State private var schedule: ArchiveSchedule = ArchiveSchedule()

    // Inline new/edit rule draft state
    @State private var editingRuleID: UUID? = nil
    @State private var ruleDraftName: String = ""
    @State private var ruleDraftEnabled: Bool = true
    @State private var ruleDraftCategories: Set<FileCategory> = [.images]
    @State private var ruleDraftExtensions: String = ""
    @State private var ruleDraftMatchMode: FileNameMatchMode = .any
    @State private var ruleDraftPattern: String = ""
    @State private var ruleDraftSourceFolder: String = ""
    @State private var ruleDraftDestination: String = ""
    @State private var ruleDraftPreserveSubpath: Bool = true

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
                                Toggle("Preserve folder structure", isOn: $preserveFolderStructure)
                                Toggle("Skip hidden files", isOn: $skipHiddenFiles)
                            }
                            Text("When 'Preserve folder structure' is enabled, subdirectories inside each source folder are recreated inside the destination (applies to the fallback folder and new rules). Turn it off to flatten archived files into a single target folder.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                                ForEach($sourceFolders) { $folder in
                                    HStack(spacing: 8) {
                                        TextField("Source folder path", text: $folder.path)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.caption.monospaced())
                                        Button("Choose…") {
                                            if let picked = appState.chooseFolder(
                                                title: "Change Source Folder",
                                                initialPath: folder.path
                                            ) {
                                                folder.path = picked
                                            }
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        Button(role: .destructive) {
                                            let targetID = folder.id
                                            sourceFolders.removeAll { $0.id == targetID }
                                        } label: {
                                            Image(systemName: "minus.circle")
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Remove source folder")
                                    }
                                }
                            }
                            HStack {
                                Button {
                                    if let picked = appState.chooseFolder(title: "Choose Source Folder") {
                                        if !sourceFolders.contains(where: { $0.path == picked }) {
                                            sourceFolders.append(EditableSourceFolder(path: picked))
                                        }
                                    }
                                } label: {
                                    Label("Add Source Folder…", systemImage: "folder.badge.plus")
                                }
                                .buttonStyle(.bordered)

                                let downloads = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
                                if FileManager.default.fileExists(atPath: downloads) && !sourceFolders.contains(where: { $0.path == downloads }) {
                                    Button("Add ~/Downloads") {
                                        sourceFolders.append(EditableSourceFolder(path: downloads))
                                    }
                                    .buttonStyle(.bordered)
                                }

                                let documents = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
                                if FileManager.default.fileExists(atPath: documents) && !sourceFolders.contains(where: { $0.path == documents }) {
                                    Button("Add ~/Documents") {
                                        sourceFolders.append(EditableSourceFolder(path: documents))
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
                                        let starter = ArchiveRuleEngine.starterRules(
                                            destinationRoot: root,
                                            preserveRelativeSubpath: preserveFolderStructure
                                        )
                                        rules.append(contentsOf: starter)
                                    }
                                } label: {
                                    Label("Add Starter Rules (Pictures, Movies, Installers…)", systemImage: "wand.and.stars")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            ForEach(Array(rules.enumerated()), id: \.element.id) { idx, rule in
                                let isBeingEdited = editingRuleID == rule.id
                                HStack(spacing: 8) {
                                    Toggle("", isOn: Binding(
                                        get: { idx < rules.count ? rules[idx].isEnabled : true },
                                        set: { newValue in
                                            guard idx < rules.count else { return }
                                            rules[idx].isEnabled = newValue
                                            if editingRuleID == rules[idx].id {
                                                ruleDraftEnabled = newValue
                                            }
                                        }
                                    ))
                                    .labelsHidden()
                                    .help("Enable or disable this classification rule")

                                    Text("#\(idx + 1)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(rule.name)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                                            if isBeingEdited {
                                                Text("Editing")
                                                    .font(.caption2.weight(.semibold))
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 1)
                                                    .background(Color.accentColor.opacity(0.2))
                                                    .foregroundStyle(Color.accentColor)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(ruleConditionBrief(rule))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Text("→ \(rule.destinationFolderPath)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.blue)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer()

                                    Button {
                                        guard idx < rules.count else { return }
                                        rules[idx].preserveRelativeSubpath.toggle()
                                        if editingRuleID == rules[idx].id {
                                            ruleDraftPreserveSubpath = rules[idx].preserveRelativeSubpath
                                        }
                                    } label: {
                                        Text(rule.preserveRelativeSubpath ? "Keep Subfolders" : "Flat")
                                            .font(.caption2.weight(.medium))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(rule.preserveRelativeSubpath ? Color.blue.opacity(0.14) : Color.primary.opacity(0.08))
                                            .foregroundStyle(rule.preserveRelativeSubpath ? .blue : .secondary)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Toggle whether this rule preserves relative subfolders or writes files flat into the destination")

                                    Button {
                                        beginEditingRule(rule)
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                    .help("Edit this rule's name, types, pattern, source filter, and destination")

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
                                        let removedID = rule.id
                                        rules.remove(at: idx)
                                        if editingRuleID == removedID {
                                            resetRuleDraft()
                                        }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(6)
                                .background(isBeingEdited ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(isBeingEdited ? Color.accentColor : Color.clear, lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }

                            Divider()

                            // Add / Edit classification rule builder
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    if editingRuleID != nil {
                                        Label("Editing Classification Rule", systemImage: "pencil.circle.fill")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.blue)
                                        Toggle("Enabled", isOn: $ruleDraftEnabled)
                                            .font(.caption)
                                        Spacer()
                                        Button("Cancel Edit") {
                                            resetRuleDraft()
                                        }
                                        .buttonStyle(.borderless)
                                        .font(.caption)
                                    } else {
                                        Text("Add Classification Rule")
                                            .font(.caption.weight(.semibold))
                                        Spacer()
                                    }
                                }

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
                                        if let picked = appState.chooseFolder(
                                            title: "Optional Source Folder Filter",
                                            initialPath: ruleDraftSourceFolder.isEmpty ? nil : ruleDraftSourceFolder
                                        ) {
                                            ruleDraftSourceFolder = picked
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    if !ruleDraftSourceFolder.isEmpty {
                                        Button("Clear") {
                                            ruleDraftSourceFolder = ""
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                }

                                HStack {
                                    TextField("Destination Folder Path", text: $ruleDraftDestination)
                                        .textFieldStyle(.roundedBorder)
                                    Button("Choose…") {
                                        if let picked = appState.chooseFolder(
                                            title: "Choose Destination Folder",
                                            initialPath: ruleDraftDestination.isEmpty ? nil : ruleDraftDestination
                                        ) {
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
                                        commitDraftRule()
                                    } label: {
                                        Label(
                                            editingRuleID == nil ? "Add Rule" : "Save Rule Changes",
                                            systemImage: editingRuleID == nil ? "plus.circle.fill" : "checkmark.circle.fill"
                                        )
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(ruleDraftDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                            .padding(editingRuleID != nil ? 8 : 0)
                            .background(editingRuleID != nil ? Color.accentColor.opacity(0.05) : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(editingRuleID != nil ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
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
                                    if let picked = appState.chooseFolder(
                                        title: "Choose Optional Fallback Folder",
                                        initialPath: fallbackDestinationPath.isEmpty ? nil : fallbackDestinationPath
                                    ) {
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
                            Toggle("Preserve source folder hierarchy inside fallback folder", isOn: $preserveFolderStructure)
                                .font(.caption)
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
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !sourceFolders.contains(where: { !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                )
            }
            .padding(16)
        }
        .frame(width: 740, height: 700)
        .onAppear {
            if let existing = existingJob {
                name = existing.name
                sourceFolders = existing.sourceFolders.map { EditableSourceFolder(path: $0) }
                rules = existing.rules
                fallbackDestinationPath = existing.fallbackDestinationPath ?? ""
                includeSubdirectories = existing.includeSubdirectories
                preserveFolderStructure = existing.preserveFolderStructure
                ruleDraftPreserveSubpath = existing.preserveFolderStructure
                skipHiddenFiles = existing.skipHiddenFiles
                schedule = existing.schedule
                if let targetID = initialEditingRuleID,
                   let ruleToEdit = existing.rules.first(where: { $0.id == targetID }) {
                    beginEditingRule(ruleToEdit)
                }
            } else {
                name = "Downloads Archive"
                let downloads = (NSHomeDirectory() as NSString).appendingPathComponent("Downloads")
                if FileManager.default.fileExists(atPath: downloads) {
                    sourceFolders = [EditableSourceFolder(path: downloads)]
                }
                preserveFolderStructure = true
                ruleDraftPreserveSubpath = true
                schedule = ArchiveSchedule(isEnabled: false, frequency: .daily, hour: 2, minute: 0)
            }
        }
        .onChange(of: preserveFolderStructure) { _, newValue in
            if editingRuleID == nil {
                ruleDraftPreserveSubpath = newValue
            }
        }
        .onChange(of: schedule.isEnabled) { _, enabled in
            if enabled && schedule.frequency == .manual {
                schedule.frequency = .daily
            }
        }
    }

    private func beginEditingRule(_ rule: ArchiveRule) {
        editingRuleID = rule.id
        ruleDraftName = rule.name
        ruleDraftEnabled = rule.isEnabled
        ruleDraftCategories = Set(rule.fileCategories)
        ruleDraftExtensions = rule.customExtensions.joined(separator: ", ")
        ruleDraftMatchMode = rule.fileNameMatchMode
        ruleDraftPattern = rule.fileNamePattern
        ruleDraftSourceFolder = rule.sourceFolderPath ?? ""
        ruleDraftDestination = rule.destinationFolderPath
        ruleDraftPreserveSubpath = rule.preserveRelativeSubpath
    }

    private func resetRuleDraft() {
        editingRuleID = nil
        ruleDraftName = ""
        ruleDraftEnabled = true
        ruleDraftCategories = [.images]
        ruleDraftExtensions = ""
        ruleDraftMatchMode = .any
        ruleDraftPattern = ""
        ruleDraftSourceFolder = ""
        ruleDraftDestination = ""
        ruleDraftPreserveSubpath = preserveFolderStructure
    }

    private func commitDraftRule() {
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
        let trimmedSource = ruleDraftSourceFolder.trimmingCharacters(in: .whitespacesAndNewlines)

        let updatedRule = ArchiveRule(
            id: editingRuleID ?? UUID(),
            name: resolvedName,
            isEnabled: ruleDraftEnabled,
            fileCategories: FileCategory.allCases.filter { ruleDraftCategories.contains($0) },
            customExtensions: exts,
            fileNameMatchMode: ruleDraftMatchMode,
            fileNamePattern: ruleDraftPattern,
            sourceFolderPath: trimmedSource.isEmpty ? nil : trimmedSource,
            destinationFolderPath: dest,
            preserveRelativeSubpath: ruleDraftPreserveSubpath
        )

        if let editID = editingRuleID, let idx = rules.firstIndex(where: { $0.id == editID }) {
            rules[idx] = updatedRule
        } else {
            rules.append(updatedRule)
        }
        resetRuleDraft()
    }

    private func ruleConditionBrief(_ rule: ArchiveRule) -> String {
        var parts: [String] = []
        if !rule.fileCategories.isEmpty {
            parts.append(rule.fileCategories.map(\.displayName).joined(separator: ", "))
        }
        if !rule.customExtensions.isEmpty {
            parts.append(rule.customExtensions.map { ".\($0)" }.joined(separator: ", "))
        }
        if rule.fileNameMatchMode != .any && !rule.fileNamePattern.isEmpty {
            parts.append("\(rule.fileNameMatchMode.displayName) '\(rule.fileNamePattern)'")
        }
        if let src = rule.sourceFolderPath {
            parts.append("From \(URL(fileURLWithPath: src).lastPathComponent)")
        }
        return parts.isEmpty ? "All files" : parts.joined(separator: " • ")
    }

    private func saveJob() {
        // Automatically commit any active rule edits so clicking Save Changes never drops unsaved rule modifications.
        if editingRuleID != nil && !ruleDraftDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitDraftRule()
        }

        var cleanedSources: [String] = []
        for entry in sourceFolders {
            let trimmed = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !cleanedSources.contains(trimmed) {
                cleanedSources.append(trimmed)
            }
        }
        guard !cleanedSources.isEmpty else { return }

        let trimmedFallback = fallbackDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = ArchiveJob(
            id: existingJob?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceFolders: cleanedSources,
            rules: rules,
            fallbackDestinationPath: trimmedFallback.isEmpty ? nil : trimmedFallback,
            includeSubdirectories: includeSubdirectories,
            preserveFolderStructure: preserveFolderStructure,
            skipHiddenFiles: skipHiddenFiles,
            schedule: schedule,
            createdAt: existingJob?.createdAt ?? Date(),
            lastRunAt: existingJob?.lastRunAt
        )
        onSave(job)
        dismiss()
    }
}
