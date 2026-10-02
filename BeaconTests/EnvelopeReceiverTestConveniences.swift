//
//  EnvelopeReceiverTestConveniences.swift
//  BeaconTests
//
//  TEST TARGET ONLY. The tests that hand an envelope straight to a receiver
//  (no transport) call `receive(_:)` with no relay send time, as a Bluetooth
//  arrival would have. Production has no such overload: every production call
//  passes `relaySentAtSeconds` explicitly (the router, from the transport).
//

@testable import Beacon

extension EnvelopeReceiver {
    /// An envelope with no relay send time (as from Bluetooth).
    func receive(_ envelope: Envelope) async {
        await receive(envelope, relaySentAtSeconds: nil)
    }
}
