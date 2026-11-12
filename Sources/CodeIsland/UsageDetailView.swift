import CodeIslandCore
import SwiftUI

struct UsageDetailView: View {
    let monitor: UsageDetailMonitor
    let claudeQuota: ClaudeQuotaMonitor
    let source: UsageDetailSource
    let reservedHeight: CGFloat
    let onSelect: (UsageDetailSource) -> Void
    let onBack: () -> Void

    @AppStorage(SettingsKey.showUsageStats) private var showUsageStats = SettingsDefaults.showUsageStats
    @AppStorage(SettingsKey.showClaudeQuota) private var showClaudeQuota = SettingsDefaults.showClaudeQuota
    @AppStorage(SettingsKey.showCodexQuota) private var showCodexQuota = SettingsDefaults.showCodexQuota
    @Environment(CompletionCardSpace.self) private var panelSpace: CompletionCardSpace?
    @ObservedObject private var l10n = L10n.shared
    @State private var selectedDay: Date?
    @State private var claudeSetupMessage: String?

    private var locale: Locale { Locale(identifier: l10n.effectiveLanguage) }
    private var muted: Color { .white.opacity(0.56) }
    private var maxHeight: CGFloat {
        let windowHeight = panelSpace?.windowHeight ?? 0
        return windowHeight > 0 ? max(0, min(480, windowHeight - reservedHeight)) : 270
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            Divider().overlay(.white.opacity(0.09))
            ViewThatFits(in: .vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                ScrollView { content }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: maxHeight, alignment: .top)
        .foregroundStyle(.white)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .onAppear { refresh() }
        .onChange(of: source) { _, _ in refresh() }
        .onChange(of: showUsageStats) { _, _ in refresh() }
        .onChange(of: showCodexQuota) { _, _ in refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(l10n["back"]))

            Text(l10n["usage_detail_title"])
                .fontWeight(.semibold)
            Spacer(minLength: 6)

            Button {
                refresh(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(l10n["usage_detail_refresh"]))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 4) {
                ForEach(UsageDetailSource.allCases) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        Text(item.title)
                            .foregroundStyle(source == item ? .white : muted)
                            .padding(.horizontal, 10)
                            .frame(minHeight: 24)
                            .background(.white.opacity(source == item ? 0.13 : 0), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(source == item ? .isSelected : [])
                }
            }

            if showUsageStats {
                if let history = monitor.history { historySection(history) }
                else { status(l10n["usage_detail_loading"]) }
            }

            if (showClaudeQuota && source != .codex) || (showCodexQuota && source != .claude) {
                quotaSection
            } else {
                status(l10n["usage_detail_quota_disabled"])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historySection(_ history: UsageHistory) -> some View {
        let total = history.total(for: source)
        let day = selectedDay.flatMap { history.days.contains($0) ? $0 : nil } ?? history.days.last
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(l10n["usage_detail_last_seven"])
                    .foregroundStyle(muted)
                Spacer()
                Text("\(compact(total.recordedTokens)) tokens")
                    .font(.system(size: 19, weight: .semibold, design: .monospaced))
                    .help(total.recordedTokens.formatted(.number.locale(locale)))
            }

            if total.isEmpty {
                status(l10n["usage_detail_no_records"])
            } else {
                dayChart(history, selected: day)
                if let day {
                    let usage = history.usage(on: day, source: source)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(day.formatted(.dateTime.month(.abbreviated).day().locale(locale)))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(muted)
                            Text("\(compact(usage.recordedTokens)) tokens")
                        }
                        Spacer(minLength: 2)
                        metric("usage_detail_input", usage.inputTokens + usage.cacheCreationTokens)
                        metric("usage_detail_output", usage.outputTokens)
                        metric("usage_detail_cache", usage.cacheReadTokens)
                    }
                }
            }
        }
    }

    private func dayChart(_ history: UsageHistory, selected: Date?) -> some View {
        let peak = max(1, history.days.map { history.usage(on: $0, source: source).recordedTokens }.max() ?? 0)
        let providers = source.providers
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                ForEach(history.days, id: \.self) { day in
                    let isSelected = day == selected
                    let label = day.formatted(.dateTime.day().locale(locale))
                    let count = history.usage(on: day, source: source).recordedTokens
                    Button {
                        selectedDay = day
                    } label: {
                        VStack(spacing: 4) {
                            VStack(spacing: 0) {
                                ForEach(providers.reversed()) { provider in
                                    let tokens = history.usage(on: day, source: provider).recordedTokens
                                    if tokens > 0 {
                                        tint(provider).frame(height: 56 * CGFloat(tokens) / CGFloat(peak))
                                    }
                                }
                                if count == 0 { Color.white.opacity(0.2).frame(height: 1) }
                            }
                            .clipShape(.rect(cornerRadius: 2))
                            .frame(maxWidth: 26)
                            .frame(height: 56, alignment: .bottom)
                            Text(label)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(isSelected ? .white : muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(.white.opacity(isSelected ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(day.formatted(.dateTime.month().day().locale(locale))) · \(count.formatted(.number.locale(locale))) tokens")
                    .accessibilityLabel(Text(day.formatted(.dateTime.month().day().locale(locale))))
                    .accessibilityValue(Text("\(count) tokens"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            if source == .all {
                HStack(spacing: 12) {
                    ForEach(providers) { provider in
                        HStack(spacing: 4) {
                            Circle().fill(tint(provider)).frame(width: 5, height: 5)
                            Text(provider.title)
                        }
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(muted)
            }
        }
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(.white.opacity(0.09))
            Text(l10n["usage_detail_plan_limits"])
                .fontWeight(.semibold)

            if showClaudeQuota && showCodexQuota && source == .all {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        claudeQuotaGroup.frame(minWidth: 230, maxWidth: .infinity, alignment: .leading)
                        codexQuotaGroup.frame(minWidth: 230, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        claudeQuotaGroup
                        codexQuotaGroup
                    }
                }
            } else if showClaudeQuota && source != .codex {
                claudeQuotaGroup
            } else {
                codexQuotaGroup
            }
        }
    }

    private var claudeQuotaGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude").foregroundStyle(tint(.claude))
            if let snapshot = claudeQuota.snapshot {
                ForEach(snapshot.ordered, id: \.kind) { limit in
                    quotaRow(limit.scopeLabel ?? ClaudeQuotaFormat.duration(limit.kind.windowSeconds),
                             percent: limit.percent, resetsAt: limit.resetsAt, tint: tint(.claude))
                }
                let timeKey = claudeQuota.isLocalSnapshot ? "usage_detail_local_observed" : "usage_detail_checked_at"
                status(String(format: l10n[timeKey], dateTime(snapshot.fetchedAt)))
                if claudeQuota.lastError != nil { status(l10n["quota_stale"]) }
                else if snapshot.limits.contains(where: { $0.hasReset() }) {
                    status(l10n["usage_detail_window_elapsed"])
                }
            } else if let error = claudeQuota.lastError {
                status(l10n[error == .noCredential || error == .unauthorized ? "quota_login_needed" : "quota_unreachable"])
            } else if !claudeQuota.isLoading && claudeQuota.statuslineSetup != .connect {
                status(l10n["usage_detail_claude_waiting"])
            }
            if claudeQuota.isLoading {
                status(l10n["usage_detail_account_loading"])
            }
            HStack(spacing: 12) {
                claudeStatuslineAction
                Link(l10n["usage_detail_claude_official"], destination: URL(string: "https://claude.ai/settings/usage")!)
            }
            if let message = claudeSetupMessage { status(l10n[message]) }
        }
    }

    @ViewBuilder private var claudeStatuslineAction: some View {
        switch claudeQuota.statuslineSetup {
        case .connect, .connected:
            let connected = claudeQuota.statuslineSetup == .connected
            Button(l10n[connected ? "usage_detail_claude_disconnect" : "usage_detail_claude_connect"]) {
                let changed = ConfigInstaller.setClaudeQuotaStatusline(connected: !connected)
                claudeSetupMessage = changed ? nil : "usage_detail_claude_setup_error"
                claudeQuota.refreshLocal()
            }
        case .custom:
            Button(l10n["usage_detail_claude_copy"]) {
                guard let profile = ClaudeQuotaStatusline.Profile(configDir: ClaudeConfigPaths.configDir()),
                      let command = ConfigInstaller.claudeQuotaStatuslineCommand(profile: profile) else {
                    claudeSetupMessage = "usage_detail_claude_setup_error"
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                claudeSetupMessage = "usage_detail_claude_copy_hint"
            }
        case .unavailable:
            EmptyView()
        }
    }

    private var codexQuotaGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex").foregroundStyle(tint(.codex))
            codexQuota
        }
    }

    @ViewBuilder private var codexQuota: some View {
        if let account = monitor.codexAccount {
            ForEach(Array(account.windows.enumerated()), id: \.offset) { _, window in
                let duration = window.minutes.map { ClaudeQuotaFormat.duration(Double($0) * 60) }
                quotaRow([window.name, duration].compactMap { $0 }.joined(separator: " · "),
                         percent: Double(window.usedPercent), resetsAt: window.resetsAt, tint: tint(.codex))
            }
            if account.windows.isEmpty { status(l10n["usage_detail_codex_unavailable"]) }

            HStack(spacing: 6) {
                Text(l10n["usage_detail_reset_credits"])
                Spacer()
                if let count = account.resetCount { Text(count.formatted(.number.locale(locale))) }
                else { Text(l10n["usage_detail_unavailable"]).foregroundStyle(muted) }
            }
            if let expiry = account.earliestResetExpiry, let count = account.resetCount, count > 0 {
                status(String(format: l10n["usage_detail_credit_expiry"], dateTime(expiry)))
            }
            if let tokens = account.lifetimeTokens {
                HStack(spacing: 6) {
                    Text(l10n["usage_detail_lifetime"])
                    Spacer()
                    Text(tokens.formatted(.number.locale(locale)))
                }
                .help(account.lifetimeAt.map { String(format: l10n["usage_detail_checked_at"], dateTime($0)) } ?? "")
            }
        } else if !monitor.isLoadingCodex {
            status(l10n["usage_detail_codex_unavailable"])
        }
        if monitor.isLoadingCodex {
            status(l10n["usage_detail_account_loading"])
        } else if let fetched = monitor.codexAccount?.windowsAt {
            status(String(format: l10n["usage_detail_checked_at"], dateTime(fetched)))
        }
        if monitor.codexRefreshFailed && monitor.codexAccount != nil { status(l10n["quota_stale"]) }
        else if monitor.codexAccount?.windows.contains(where: { $0.resetsAt.map { $0 <= Date() } ?? false }) == true {
            status(l10n["usage_detail_window_elapsed"])
        }
    }

    private func quotaRow(_ title: String, percent: Double, resetsAt: Date?, tint: Color) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text(title.isEmpty ? l10n["usage_detail_plan_limits"] : title)
                Spacer(minLength: 4)
                if let resetsAt {
                    Text(String(format: l10n["usage_detail_reset_at"], dateTime(resetsAt)))
                        .foregroundStyle(muted)
                }
                Text(ClaudeQuotaFormat.percent(percent))
                    .frame(minWidth: 34, alignment: .trailing)
            }
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule().fill(tint)
                            .frame(width: geometry.size.width * min(max(percent / 100, 0), 1))
                    }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
        }
    }

    private func metric(_ key: String, _ count: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(l10n[key]).font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
            Text(compact(count)).help(count.formatted(.number.locale(locale)))
        }
    }

    private func status(_ message: String) -> some View { Text(message).foregroundStyle(muted) }

    private func compact(_ count: Int) -> String { ClaudeUsageScanner.formatTokens(count) }

    private func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(locale))
    }

    private func tint(_ provider: UsageDetailSource) -> Color {
        provider == .claude ? Color(red: 0.89, green: 0.58, blue: 0.40) : Color(red: 0.49, green: 0.79, blue: 0.68)
    }

    private func refresh(force: Bool = false) {
        monitor.refreshHistory(force: force)
        if source != .claude { monitor.refreshCodex(force: force) }
        if force, source != .codex, showClaudeQuota { claudeQuota.fetchNow() }
    }
}
