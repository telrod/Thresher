//
//  NotificationPrefs.swift
//  Thresher
//
//  The TYPED notification-preferences surface (Settings §4.1.3 "Notification
//  Preferences") — `GET`/`PUT /preferences/notifications`.
//
//  This is one of TWO preference surfaces the screen touches (trap §1.4): the
//  typed one (here) for quiet-hours + audio, and the generic `[String:String]`
//  map (Preferences.swift, GeneralPrefs view) for operating mode / digest time /
//  ceiling / poll interval. Do NOT read `audio_alerts` off the generic map or
//  `operating_mode` off this one — they are deliberately separate.
//
//  Per docs/api-contract-map.md (confirmed by running): this endpoint returns
//  COERCED types — `audio_alerts` is a real JSON bool, quiet hours are `"HH:MM"`
//  or `null`. The PUT is strict (trap §1.5): patch semantics; `""` UNSETS a
//  quiet-hour (→ null); `audio_alerts` must be a real bool (`"true"`/`1` are
//  rejected 400); an unknown key → 400. Hence a separate write DTO.
//

import Foundation

/// `GET /preferences/notifications` — the typed read. `audio_alerts` defaults
/// `false` server-side when unset, so it is non-optional; quiet hours are nil
/// when unset.
struct NotificationPrefs: Codable, Hashable, Sendable {
    let quietHoursStart: String?    // "HH:MM" or nil
    let quietHoursEnd: String?      // "HH:MM" or nil
    let audioAlerts: Bool           // real bool; defaults false when unset

    enum CodingKeys: String, CodingKey {
        case quietHoursStart = "quiet_hours_start"
        case quietHoursEnd = "quiet_hours_end"
        case audioAlerts = "audio_alerts"
    }
}

/// Body for `PUT /preferences/notifications`. Patch semantics — only the keys
/// present are written. `Encodable`-only.
///
/// ⚠️ The empty-string-unsets contract (trap §1.5) lives at the call site, not
/// here: to UNSET a quiet-hour, the caller sends `""` (not nil — nil would omit
/// the key and leave it intact). So a quiet-hour field is `String??`:
///   - `.none`        → omit the key (leave the stored value intact)
///   - `.some("")`    → send `""` → server unsets it (→ null)
///   - `.some("9:00")`→ send the time → server normalizes/stores it
/// `audio_alerts` is a plain `Bool?` — present only when the toggle is written.
struct NotificationPrefsWrite: Encodable, Sendable {
    var quietHoursStart: String?? = .none
    var quietHoursEnd: String?? = .none
    var audioAlerts: Bool?

    enum CodingKeys: String, CodingKey {
        case quietHoursStart = "quiet_hours_start"
        case quietHoursEnd = "quiet_hours_end"
        case audioAlerts = "audio_alerts"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(audioAlerts, forKey: .audioAlerts)
        // Doubly-optional quiet hours: .some(x) encodes x (incl. ""); .none omits.
        if let quietHoursStart { try c.encode(quietHoursStart, forKey: .quietHoursStart) }
        if let quietHoursEnd { try c.encode(quietHoursEnd, forKey: .quietHoursEnd) }
    }
}