//
//  LaunchGate.swift
//  Beacon
//
//  The first decision at launch, ahead of `BootRouter`: an erase in this
//  process means relaunch; otherwise the Terms of Use must be accepted (the
//  current version, on this install) before ANYTHING boots. `boot` — which
//  loads the identity and builds the model/session stack (sockets, router,
//  Bluetooth) — is invoked only after both checks pass, so nothing starts
//  behind the terms. No exemptions: the boot-failed door sits behind the
//  terms too. Pure, so LaunchGateTests can pin the order with a spy `boot`.
//

import Foundation

enum LaunchStep<Booted> {
    case restartRequired
    case terms
    case booted(Booted)
}

@MainActor
enum LaunchGate {

    static func run<Booted>(retirement: StackRetirementLatch.Decision,
                            termsAccepted: () -> Bool,
                            boot: () -> Booted) -> LaunchStep<Booted> {
        guard retirement == .build else { return .restartRequired }
        guard termsAccepted() else { return .terms }
        return .booted(boot())
    }
}
