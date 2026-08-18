//
//  BlockedContactsView.swift
//  Screens
//
//  Settings → Blocked Contacts (Guideline 1.2 Block). Lists the persisted
//  denylist (petname snapshot + block date), offers Unblock, and opens a
//  READ-ONLY transcript of the preserved conversation — blocking never
//  deletes messages (the user may need the history to report to authorities);
//  it only hides the conversation from the main list.
//
//  The transcript view is deliberately NOT StreamView: no composer, no calls,
//  no PTT, no resend — nothing here can transmit anything. It reads the
//  preserved SwiftData rows and marks inbound as read (display state only) so
//  the app badge can't stick on a blocked thread's pre-block unreads.
//

import SwiftUI
import SwiftData
import UIKit

struct BlockedContactsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(PairingService.self) private var pairing: PairingService?

    @State private var selected: BlockedContact?
    @State private var unblockFailed = false

    private var hairlineColor: Color { Stillwater.Palette.biolume.opacity(0.09) }
    private var entries: [BlockedContact] { pairing?.blockedContacts ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(hairlineColor).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if entries.isEmpty {
                        Text("No blocked contacts.")
                            .font(Stillwater.Serif.italic(15))
                            .foregroundStyle(Stillwater.Palette.mistDim)
                            .padding(.horizontal, 20)
                    } else {
                        listSection
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 44)
            }
        }
        .background(Stillwater.Palette.abyss.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(item: $selected) { entry in
            BlockedTranscriptView(entry: entry)
        }
        .alert("Couldn't unblock", isPresented: $unblockFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong saving the change. Please try again.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Text("‹")
                    .stillwaterSerif(20, color: Stillwater.Palette.biolume)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Blocked Contacts").stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.foam)
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private var listSection: some View {
        SettingsGroup(
            footer: "Blocked contacts can't reach you and can't re-pair. Tap a name to read the preserved conversation. Unblocking restores the conversation to your main list."
        ) {
            ForEach(entries) { entry in
                SettingsRow {
                    HStack(spacing: 12) {
                        Button { selected = entry } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Self.name(for: entry))
                                    .font(Stillwater.Serif.regular(17))
                                    .foregroundStyle(Stillwater.Palette.foam)
                                Text("blocked \(Self.dateText(entry.blockedAt))")
                                    .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDim)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { unblock(entry) } label: {
                            Text("Unblock")
                                .font(Stillwater.Serif.regular(15))
                                .foregroundStyle(Stillwater.Palette.biolume)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .overlay(Capsule().strokeBorder(Stillwater.Palette.biolume.opacity(0.4), lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func unblock(_ entry: BlockedContact) {
        guard let pairing else {
            unblockFailed = true
            return
        }
        Task {
            do {
                try await pairing.unblock(rawKey: entry.rawKey)
            } catch {
                RedactLog.event("unblock: FAILED", "\(type(of: error))")
                unblockFailed = true
            }
        }
    }

    static func name(for entry: BlockedContact) -> String {
        let trimmed = entry.petname?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? "contact" : trimmed
    }

    static func dateText(_ unixMillis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMillis) / 1000)
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }
}

// MARK: - Read-only transcript

/// The preserved conversation of a blocked contact. READ-ONLY by construction:
/// no composer, no resend, no calls — this view has no code path that
/// transmits anything. Marks inbound rows read on appear (display state only).
struct BlockedTranscriptView: View {

    let entry: BlockedContact

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(MessageInbox.self) private var inbox: MessageInbox?

    private var hairlineColor: Color { Stillwater.Palette.biolume.opacity(0.09) }

    /// The preserved Peer row, if it still exists. Small-roster in-memory
    /// lookup — deliberately no #Predicate so nothing here can misfire.
    private var peer: Peer? {
        let all = (try? modelContext.fetch(FetchDescriptor<Peer>())) ?? []
        return all.first { $0.publicKeyData == entry.rawKey }
    }

    private var messages: [Message] {
        let convo = peer?.conversations.first(where: { $0.kind == .direct })
        return (convo?.messages ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM · HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(hairlineColor).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if messages.isEmpty {
                        Text("No messages preserved.")
                            .font(Stillwater.Serif.italic(15))
                            .foregroundStyle(Stillwater.Palette.mistDim)
                    } else {
                        ForEach(messages) { m in
                            row(m)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Stillwater.Palette.abyss.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear(perform: markRead)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Text("‹")
                    .stillwaterSerif(20, color: Stillwater.Palette.biolume)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Text(BlockedContactsView.name(for: entry))
                .stillwaterSerif(17, weight: .medium, color: Stillwater.Palette.foam)
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func row(_ m: Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let data = m.mediaData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if m.mediaMimeRaw != nil {
                Text(m.mediaData == nil ? "media · gone" : "media")
                    .font(Stillwater.Serif.italic(15))
                    .foregroundStyle(Stillwater.Palette.mistDim)
            } else {
                Text(m.content)
                    .font(Stillwater.Serif.regular(16))
                    .foregroundStyle(m.isOutbound ? Stillwater.Palette.mist : Stillwater.Palette.foam)
            }
            Text("\(m.isOutbound ? "you · " : "")\(Self.timeFormatter.string(from: m.timestamp))")
                .stillwaterMono(8.5, trackingEm: 0.18, color: Stillwater.Palette.mistDimmest)
        }
        .frame(maxWidth: .infinity, alignment: m.isOutbound ? .trailing : .leading)
    }

    /// Same predicate StreamView.markInboundRead clears, so pre-block unreads
    /// can't stick on the app badge forever. Display state only.
    private func markRead() {
        guard let convo = peer?.conversations.first(where: { $0.kind == .direct }) else { return }
        var changed = false
        for m in convo.messages where !m.isOutbound && !m.isRead {
            m.isRead = true
            changed = true
        }
        if changed {
            try? modelContext.save()
            inbox?.syncBadgeToUnreadTotal()
        }
    }
}
