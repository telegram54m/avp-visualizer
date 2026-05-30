//
//  StemCacheAuditSheet.swift
//
//  "Verify stem cache" maintenance sheet, presented from
//  SettingsSourceView (the Visualizers page). Drives
//  [[StemCacheAuditor.runAudit]] with progress UI, then shows the
//  findings list with per-row checkboxes so the user can confirm
//  which corrupted alias rows to delete.
//

#if os(macOS)
import SwiftUI

struct StemCacheAuditSheet: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case idle
        case running
        case finished(StemCacheAuditor.Report)
        case failed(String)
        case deleting(completed: Int, total: Int)
        case deleted(count: Int, remaining: StemCacheAuditor.Report)
    }

    @State private var phase: Phase = .idle
    @State private var progress: StemCacheAuditor.Progress?
    @State private var selectedKeys: Set<String> = []
    @State private var runTask: Task<Void, Never>?
    @State private var confirmDelete = false
    /// Opt-in: also delete the redundant copies from the SHARED CloudKit
    /// public DB. Destructive + outward-facing (affects every user's
    /// cross-user cache), so off by default; only acts on
    /// `cloudPurgeableKeys`.
    @State private var purgeSharedCloud = false
    /// Subset of flagged keys safe to purge from the public DB:
    /// redundant-recording duplicates keyed `shazam-<id>` (local cacheKey
    /// == public record name for those). Survivors never appear here.
    @State private var cloudPurgeableKeys: Set<String> = []

    /// Count of currently-selected keys eligible for shared-cloud purge.
    private var selectedCloudPurgeCount: Int {
        selectedKeys.intersection(cloudPurgeableKeys).count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .onAppear { startAudit() }
        .onDisappear { runTask?.cancel() }
        .confirmationDialog(
            "Remove \(selectedKeys.count) cached row\(selectedKeys.count == 1 ? "" : "s")?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { performDeletion() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if purgeSharedCloud && selectedCloudPurgeCount > 0 {
                Text("Erases the selected rows from the local SQLite cache AND removes \(selectedCloudPurgeCount) redundant copy\(selectedCloudPurgeCount == 1 ? "" : "ies") from the SHARED cloud cache (affects all users). The canonical copy of each recording is kept; local rows recompute on demand.")
            } else {
                Text("These rows will be erased from the local SQLite cache. Any future plays of the affected songs will recompute stems on demand. CloudKit and other devices' caches are not touched.")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "stethoscope.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Verify stem cache")
                    .font(.title3.weight(.semibold))
                Text("\"Likely bad\" rows share identical stem bytes under different titles — strong evidence of an alias bug. \"Info\" rows just don't match any MusicBrainz duration, which often means MB doesn't index your exact release; verify before removing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .running:
            runningView
        case .finished(let report):
            findingsList(report: report, deletedCount: nil)
        case .failed(let message):
            failureView(message: message)
        case .deleting(let completed, let total):
            VStack(spacing: 10) {
                ProgressView(value: Double(completed), total: Double(total))
                    .progressViewStyle(.linear)
                Text("Removing \(completed) / \(total)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 480)
        case .deleted(let count, let remaining):
            findingsList(report: remaining, deletedCount: count)
        }
    }

    private var runningView: some View {
        VStack(spacing: 14) {
            ProgressView()
            if let p = progress {
                Text(progressLabel(p))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if p.total > 0 && p.stage == .checkingMusicBrainz {
                    ProgressView(value: Double(p.completed), total: Double(p.total))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 360)
                    Text("Pacing at MusicBrainz's ~1 req/s rate limit — sit tight.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Starting audit…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: 480)
    }

    private func progressLabel(_ p: StemCacheAuditor.Progress) -> String {
        switch p.stage {
        case .enumerating:
            return "Listing cached rows…"
        case .correlating:
            return "Looking for duplicate stem payloads…"
        case .checkingMusicBrainz:
            return "Checking MusicBrainz — \(p.completed) of \(p.total)…"
        }
    }

    private func failureView(message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Audit failed")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding()
    }

    private func findingsList(
        report: StemCacheAuditor.Report,
        deletedCount: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            summary(report: report, deletedCount: deletedCount)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            if report.findings.isEmpty {
                cleanState
            } else {
                List(report.findings, selection: $selectedKeys) { finding in
                    findingRow(finding)
                }
                .listStyle(.inset)
            }
        }
    }

    private func summary(
        report: StemCacheAuditor.Report,
        deletedCount: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let n = deletedCount {
                Text("Removed \(n) cache row\(n == 1 ? "" : "s"). Re-ran audit; remaining state below.")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            HStack(spacing: 16) {
                summaryStat(label: "Cached rows", value: "\(report.totalRows)")
                summaryStat(label: "Findings", value: "\(report.findings.count)")
                summaryStat(
                    label: "High-confidence",
                    value: "\(report.findings.filter(\.isHighConfidence).count)"
                )
                if report.unmatchedMBLookups > 0 {
                    summaryStat(
                        label: "Not in MusicBrainz",
                        value: "\(report.unmatchedMBLookups)"
                    )
                }
            }
        }
    }

    private func summaryStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.semibold))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var cleanState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("No suspicious cache rows found.")
                .font(.headline)
            Text("Every row's stored duration agreed with MusicBrainz within tolerance, and no duplicate stem payloads carried conflicting metadata.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func findingRow(_ finding: StemCacheAuditor.Finding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            confidenceChip(isHigh: finding.isHighConfidence)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(finding.headline)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(finding.row.cacheKey)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                ForEach(Array(finding.details.enumerated()), id: \.offset) { _, detail in
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .tag(finding.id)
    }

    private func confidenceChip(isHigh: Bool) -> some View {
        Text(isHigh ? "Likely bad" : "Info")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isHigh ? Color.red : Color.gray)
            )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            switch phase {
            case .running:
                Button("Cancel") {
                    runTask?.cancel()
                    dismiss()
                }
            case .finished, .deleted:
                Button("Done") { dismiss() }
                if selectedCloudPurgeCount > 0 {
                    Toggle(isOn: $purgeSharedCloud) {
                        Text("Also purge \(selectedCloudPurgeCount) from shared cloud")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .help("Removes the redundant Shazam-keyed duplicates from the cross-user CloudKit cache. The canonical copy of each recording is kept. Affects all users — leave off unless you're sure.")
                }
                Spacer()
                let count = selectedKeys.count
                Button {
                    confirmDelete = true
                } label: {
                    Text(count == 0
                         ? "Remove selected"
                         : "Remove \(count) row\(count == 1 ? "" : "s")")
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .disabled(selectedKeys.isEmpty)
            case .deleting:
                ProgressView().controlSize(.small)
                Text("Removing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            case .failed:
                Button("Close") { dismiss() }
                Spacer()
                Button("Retry") { startAudit() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Run

    private func startAudit() {
        runTask?.cancel()
        phase = .running
        progress = nil
        selectedKeys = []
        cloudPurgeableKeys = []
        runTask = Task {
            do {
                let provider = await appModel.ensureStemFeatureProvider()
                let report = try await StemCacheAuditor.runAudit(
                    provider: provider
                ) { update in
                    progress = update
                }
                let pre = report.findings.filter(\.isHighConfidence).map(\.id)
                selectedKeys = Set(pre)
                cloudPurgeableKeys = Self.cloudPurgeableKeys(from: report)
                phase = .finished(report)
            } catch is CancellationError {
                // Sheet was dismissed or user cancelled — nothing to
                // surface; the sheet is already gone.
            } catch {
                phase = .failed("\(error)")
            }
        }
    }

    /// Findings safe to also purge from the shared cloud DB: redundant-
    /// recording duplicates keyed `shazam-<id>` (cacheKey == public
    /// record name). Survivors and non-duplicate rows are excluded.
    private static func cloudPurgeableKeys(
        from report: StemCacheAuditor.Report
    ) -> Set<String> {
        var keys: Set<String> = []
        for finding in report.findings {
            guard StemCacheKey.isShazam(finding.id) else { continue }
            let isRedundant = finding.kinds.contains {
                if case .redundantRecordingDuplicate = $0 { return true }
                return false
            }
            if isRedundant { keys.insert(finding.id) }
        }
        return keys
    }

    private func performDeletion() {
        let toDelete = Array(selectedKeys)
        guard !toDelete.isEmpty else { return }
        // Capture cloud-purge list before async work mutates selection.
        let cloudToPurge: [String] = purgeSharedCloud
            ? Array(selectedKeys.intersection(cloudPurgeableKeys))
            : []
        phase = .deleting(completed: 0, total: toDelete.count)
        runTask?.cancel()
        runTask = Task {
            do {
                let provider = await appModel.ensureStemFeatureProvider()
                let removed = try await StemCacheAuditor.deleteRows(
                    provider: provider, cacheKeys: toDelete)
                // Mirror redundant-duplicate deletions to the shared
                // CloudKit public DB (opt-in). Record name == cacheKey
                // for shazam- rows; failures are logged inside.
                if !cloudToPurge.isEmpty {
                    _ = await CloudCacheSync.shared.deleteStemRecords(recordNames: cloudToPurge)
                }
                // Re-run audit so the UI reflects the new state.
                let report = try await StemCacheAuditor.runAudit(
                    provider: provider
                ) { update in
                    progress = update
                }
                selectedKeys = Set(report.findings.filter(\.isHighConfidence).map(\.id))
                cloudPurgeableKeys = Self.cloudPurgeableKeys(from: report)
                phase = .deleted(count: removed, remaining: report)
            } catch is CancellationError {
                // ignored
            } catch {
                phase = .failed("\(error)")
            }
        }
    }
}
#endif
