//
//  PairRefusalCopy.swift
//  Beacon
//
//  The pairing screen's refusal lines for a blocked or reported identity
//  (Guideline 1.2), shared by the tapped-invite, scan and paste paths. A
//  reported contact can never be unblocked, so its refusal must not tell the
//  user to unblock them. Lowercase, like the screen's other status lines.
//
//  Lives in Beacon/ (a synchronized folder), not Screens/ (a classic group).
//

enum PairRefusalCopy {
    static let blocked = "this contact is blocked — unblock them in Settings to pair again"
    static let reported = "you reported this contact — they can never pair with you again"
}
