//
//  NotificationFeed.swift
//  Thresher
//
//  The shape behind GET /notifications (D45 native-delivery hand-off).
//
//  The backend records every alert decision in notification_log; this endpoint
//  returns the subset the NATIVE app should deliver (rows the backend tagged
//  `delivery: "app"` because the app owned delivery when they were decided). Each
//  carries the `message_id` so a delivered notification can deep-link to its
//  message (§4.1.2). `cursor` is the highest log id the server considered — the
//  app stores it and passes it back as `since` so each row fires exactly once.
//

import Foundation

/// One row from GET /notifications — an alert the app should post natively.
struct NotificationItem: Codable, Identifiable, Hashable, Sendable {
    let id: Int                     // notification_log id (monotonic; the cursor)
    let messageID: String?          // nullable: a digest row carries no single message
    let notificationType: String    // 'tier1_alert' | 'tier2_alert' | 'digest'
    let sentAt: String
    let title: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case id, title, text
        case messageID = "message_id"
        case notificationType = "notification_type"
        case sentAt = "sent_at"
    }
}

/// GET /notifications response: `{ notifications: [...], cursor: <int> }`.
struct NotificationFeed: Codable, Sendable {
    let notifications: [NotificationItem]
    let cursor: Int
}