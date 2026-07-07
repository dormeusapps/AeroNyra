//
//  LocalNotifier.swift
//  Core/Notifications
//
//  N1 — serverless local notifications. A thin, @MainActor UserNotifications
//  façade: banner + sound + badge fired BY THIS APP via UNUserNotificationCenter.
//  No server, no push, no APNs, and therefore no aps-environment entitlement,
//  no Info.plist key, and no pod — UserNotifications is a system framework.
//
//  BOUNDARY: this type holds NO crypto and NO transport. It never sees a
//  ciphertext, an Envelope, or a session — only the raw 32-byte peer identity
//  key (`Peer.publicKeyData`, the same `Data` form every key crossing the
//  inbox boundary uses) and an unread count. The receive-path wiring that
//  CALLS `messageArrived` is N2 and lives in MessageInbox, downstream of
//  decryption and the wireID dedup (`alreadyStored`) — never here.
//
//  DELEGATE: installed as the UNUserNotificationCenter delegate in
//  BeaconApp.init(), before launch completes, so a notification tap that
//  cold-launches the app reaches `didReceive` instead of being dropped.
//
//  PRIVACY: the banner is deliberately generic ("New message") — no plaintext,
//  no petname. Notification content is rendered by the system on the lock
//  screen; putting message text there would leak what the whole app is built
//  to protect. N2 revisits what (if anything) the banner may say.
//

import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class LocalNotifier: NSObject, UNUserNotificationCenterDelegate {

    /// The conversation currently on screen, keyed the same way the receive
    /// path keys a thread: the peer's raw 32-byte identity key
    /// (`Peer.publicKeyData`). ConversationView sets/clears this (N3) so a
    /// message for the thread the user is already reading never banners.
    var activeConversationID: Data?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()

    // MARK: - Authorization

    /// Ask for banner + sound + badge permission — once, ever. The system
    /// prompt only appears while `authorizationStatus == .notDetermined`, so
    /// gating on that makes this idempotent: after the user answers (either
    /// way), every later call is a no-op and the prompt can never re-appear.
    /// The composition root calls this the first time the app is foreground
    /// with at least one contact — never on a fresh, contactless install.
    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            let granted = try await center.requestAuthorization(
                options: [.alert, .sound, .badge])
            print("notifier: authorization \(granted ? "granted" : "denied")")
        } catch {
            print("notifier: authorization request failed: \(error)")
        }
    }

    // MARK: - Message arrival (N2 calls this; nothing is wired yet)

    /// Fire a banner + sound for a genuinely new inbound message and stamp the
    /// app badge with the total unread count. Suppressed when the conversation
    /// is the one on screen. `conversationID` is the peer's raw 32-byte identity
    /// key (the receive-path thread key, used ONLY for the on-screen suppression
    /// check); `threadKey` is the Conversation's random UUID, used for grouping.
    func messageArrived(conversationID: Data, threadKey: UUID, unreadTotal: Int) async {
        guard conversationID != activeConversationID else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "AeroNyra"
        content.body = "New message"
        content.sound = .default
        content.badge = NSNumber(value: unreadTotal)
        // Same-thread banners group together in Notification Center. Keyed by the
        // Conversation's random UUID — NOT the peer identity-key hex, which would
        // persist a stable device identifier in the system notification store.
        content.threadIdentifier = threadKey.uuidString

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)   // deliver now
        do { try await center.add(request) }
        catch { print("notifier: add failed: \(error)") }
    }

    /// Reconcile the app-icon badge with the store's unread total (e.g. after
    /// the user reads a conversation). iOS 17 API — NOT the deprecated
    /// `applicationIconBadgeNumber`.
    func syncBadge(_ unreadTotal: Int) {
        center.setBadgeCount(unreadTotal) { error in
            if let error { print("notifier: setBadgeCount failed: \(error)") }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate (async variants, Swift 6-ready)

    /// Stub (N1): present everywhere, so a delivery while the app is
    /// foreground is visible. `messageArrived` already suppresses the active
    /// conversation before a request is ever scheduled; N2 refines what (if
    /// anything) beyond that is filtered here.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    /// Stub (N1): the tap is accepted and dropped. N3 routes it to the
    /// matching conversation via the request's threadIdentifier.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
    }

}
