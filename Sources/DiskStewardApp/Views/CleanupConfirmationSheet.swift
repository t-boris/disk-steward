import DiskStewardCore
import SwiftUI

/// Explicit user confirmation dialog required before ANY cleanup deletion or archived-original removal
/// (REQ-005 AC 5, REQ-006 AC 2–4, DEC-003, DEC-006, DEC-007, plan I-9).
struct CleanupConfirmationSheet: View {
    @EnvironmentObject private var appState: AppState
    @State private var deletionMode: DeletionMode = .moveToTrash

    private var items: [CleanupCandidate] {
        appState.selectedCleanupCandidates
    }

    private var hasFilesystemItems: Bool {
        items.contains { !$0.isDockerArtifact }
    }

    private var hasDockerItems: Bool {
        items.contains(where: \.isDockerArtifact)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Confirm Cleanup")
                        .font(.title3.weight(.bold))
                    Text("Review every item, location, and estimated reclaimable space before confirming deletion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Summary strip
            HStack {
                Text("\(items.count) item(s) selected")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Estimated Reclaimable Space: \(ByteFormatting.string(from: appState.selectedCleanupReclaimableBytes))")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.blue)
            }
            .padding(10)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Explicit list of proposed items & locations
            List(items) { item in
                HStack(spacing: 8) {
                    Image(systemName: item.category.systemImage)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                            Text(item.category.displayName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.07))
                                .clipShape(Capsule())
                        }
                        Text(item.location)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(ByteFormatting.string(from: item.estimatedReclaimableBytes))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                .padding(.vertical, 2)
            }
            .listStyle(.bordered)
            .frame(minHeight: 200)

            // Deletion mode selection (DEC-006: Move to Trash default; Permanent Delete explicit opt-in)
            if hasFilesystemItems {
                GroupBox("File Deletion Mode") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Deletion Mode", selection: $deletionMode) {
                            ForEach(DeletionMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)

                        Text(deletionMode.description)
                            .font(.caption)
                            .foregroundStyle(deletionMode == .permanentDelete ? .red : .secondary)
                    }
                    .padding(4)
                }
            }

            if hasDockerItems {
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox.circle")
                        .foregroundStyle(.orange)
                    Text("Selected Docker artifacts are removed directly via the Docker CLI (Docker resources cannot be moved to macOS Trash).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.green)
                Text("Before deleting, Disk Steward revalidates each item (confirming files have not changed and verifying SHA-256 archive copies for archived originals).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Decline (Leave Data Intact)") {
                    appState.declineCleanupConfirmation()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(role: .destructive) {
                    let chosenMode = deletionMode
                    Task {
                        await appState.confirmAndExecuteCleanup(mode: chosenMode)
                    }
                } label: {
                    Text(confirmButtonTitle)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(items.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 680, height: 560)
    }

    private var confirmButtonTitle: String {
        if hasFilesystemItems && deletionMode == .permanentDelete {
            return "Confirm Permanent Delete (\(items.count))"
        }
        if hasFilesystemItems {
            return "Confirm Move to Trash (\(items.count))"
        }
        return "Confirm Docker Cleanup (\(items.count))"
    }
}
