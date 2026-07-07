//
//  BeaconApp.swift
//  Beacon
//
//  Created by Rubins Dormeus on 6/25/26.
//

import SwiftUI
import UserNotifications

@main
struct BeaconApp: App {

    /// The app-lifetime local-notification façade (N1). Constructed — and
    /// installed as the UNUserNotificationCenter delegate — HERE, in App.init,
    /// i.e. before launch completes: a notification tap that cold-launches the
    /// app is only delivered to `didReceive` if the delegate is already in
    /// place, so setting it lazily in a child view would drop that tap.
    @State private var notifier: LocalNotifier

    init() {
        let notifier = LocalNotifier()
        UNUserNotificationCenter.current().delegate = notifier
        _notifier = State(initialValue: notifier)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(notifier)
        }
    }
}
