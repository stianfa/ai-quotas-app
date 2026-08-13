import SwiftUI

extension QuotaWindow.Level {
    var color: Color {
        switch self {
        case .ok: return Color(nsColor: .systemGreen)
        case .warn: return Color(nsColor: .systemOrange)
        case .crit: return Color(nsColor: .systemRed)
        case .unknown: return Color.secondary
        }
    }
}

/// A labelled usage bar: name, percentage, track, and reset countdown.
struct WindowRow: View {
    let window: QuotaWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(window.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.level.color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))
                    Capsule()
                        .fill(window.level.color)
                        .frame(width: max(0, min(1, (window.usedPercent ?? 0) / 100)) * geo.size.width)
                        .animation(.easeOut(duration: 0.45), value: window.usedPercent)
                }
            }
            .frame(height: 6)

            if let reset = relativeReset(window.resetsAt, now: now) {
                Text(reset)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ProviderCard: View {
    let provider: ProviderResult
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(provider.name)
                    .font(.system(size: 13, weight: .semibold))

                ForEach(pills, id: \.text) { pill in
                    Text(pill.text)
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(pill.color.opacity(0.16)))
                        .foregroundStyle(pill.color == .secondary ? Color.secondary : pill.color)
                }
                Spacer()
            }

            if let error = provider.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
                if let hint = provider.hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(provider.windows) { w in
                    WindowRow(window: w, now: now)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var pills: [(text: String, color: Color)] {
        var out: [(String, Color)] = []
        if let plan = provider.plan { out.append((plan, .secondary)) }
        for tag in provider.tags { out.append((tag, .secondary)) }
        if provider.rateLimited { out.append(("rate limited", Color(nsColor: .systemRed))) }
        if provider.isStale { out.append(("cached", Color(nsColor: .systemOrange))) }
        return out
    }
}

struct QuotaPanel: View {
    @ObservedObject var store: QuotaStore
    /// Supplied by StatusItemController, which owns the settings window.
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI Quotas")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshing)
                .help("Refresh now")
            }

            if store.snapshot.providers.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking your quotas…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
            } else {
                ForEach(store.snapshot.providers) { p in
                    ProviderCard(provider: p, now: store.now)
                }
            }

            HStack {
                Text(store.snapshot.fetchedAt == .distantPast
                     ? "—"
                     : "Updated \(store.snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Settings…") { onOpenSettings() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 300)
    }
}
