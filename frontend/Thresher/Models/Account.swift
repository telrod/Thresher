//
//  Account.swift
//  Thresher
//
//  Shapes behind Settings §4.1.3 "Email Accounts" and the reusable
//  AccountConnectView (which Onboarding §4.1.4 will import unchanged).
//
//  The account endpoints (map §"Onboarding"/§"Settings"):
//   - GET /accounts        → {accounts: [<email>]}  (Keychain-backed, D41)
//   - POST /accounts       → store the App Password  ({account, app_password})
//   - POST /accounts/verify→ {ok, reason}  (tests the STORED credential only)
//   - DELETE /accounts/<a> → {disconnected}  (Keychain only; messages stay, P1)
//
//  ⚠️ STORE → VERIFY, NOT THE REVERSE (trap §1.8 — confirmed by running):
//  `POST /accounts/verify` takes only {account} and tests the credential ALREADY
//  in the Keychain. Probing it confirmed: it IGNORES any app_password in the body
//  and returns `missing_credential` for an account that hasn't been stored yet.
//  So a NEW account can only go: POST /accounts (store) → POST /accounts/verify
//  (login-test the stored credential). This contradicts a naive reading of D40's
//  "verify first, store on success" — that order only holds for an already-stored
//  account's "test connection." See the work order Open items for the reconcile.
//
//  The App Password is a secret: it appears ONLY as a parameter to the store
//  call (StoreAccountBody) and is dropped the moment the request returns. It is
//  never stored in a model, logged, or echoed (the backend never returns it).
//

import Foundation

/// `GET /accounts` response: `{accounts: [<email>]}` — sorted, unique, may be
/// empty. No secret values (D41: Keychain is the registry).
struct AccountsResponse: Codable, Sendable {
    let accounts: [String]
}

/// Body for `POST /accounts`. The ONLY place the App Password touches app code.
/// `Encodable`-only; never decoded, never persisted.
struct StoreAccountBody: Encodable, Sendable {
    let account: String
    let appPassword: String
    /// D61 initial-backfill bound ("1w"/"1m"/"3m"/"everything"), or nil.
    ///
    /// OMITTED from the JSON when nil, not sent as null: server-side an absent
    /// key means "no cutoff" — the pre-D61 behaviour — so an old caller cannot
    /// accidentally start narrowing what it retrieves. `encodeIfPresent` is what
    /// makes that true, since a synthesised encoder would emit `null`.
    var retrievalWindow: String? = nil

    enum CodingKeys: String, CodingKey {
        case account
        case appPassword = "app_password"
        case retrievalWindow = "retrieval_window"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(account, forKey: .account)
        try c.encode(appPassword, forKey: .appPassword)
        try c.encodeIfPresent(retrievalWindow, forKey: .retrievalWindow)
    }
}

/// Body for `POST /accounts/verify` — `{account}` only. (No password: verify
/// tests the stored credential, trap §1.8.)
struct VerifyAccountBody: Encodable, Sendable {
    let account: String
}

/// `POST /accounts/verify` response: `{ok, reason}`. `reason` is a STABLE 4-value
/// enum (map §"POST /accounts/verify") — safe to switch on. `.unknown` is a
/// decode-only fallback in case the server ever adds a fifth reason.
struct VerifyResult: Decodable, Sendable {
    let ok: Bool
    let reason: VerifyReason

    enum CodingKeys: String, CodingKey { case ok, reason }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        reason = VerifyReason(raw: try c.decode(String.self, forKey: .reason))
    }
}

/// The stable verify-reason vocabulary (map §"POST /accounts/verify").
enum VerifyReason: String, Sendable {
    case ok
    case missingCredential = "missing_credential"
    case authFailed = "auth_failed"
    case networkError = "network_error"
    case unknown

    init(raw: String) { self = VerifyReason(rawValue: raw) ?? .unknown }

    /// User-facing copy for each failure reason. `.ok` returns nil (success has
    /// no error to show). Honors trap §1.8: after a store, `auth_failed` means
    /// the stored password is wrong — guide recovery, never imply "connected."
    var failureMessage: String? {
        switch self {
        case .ok:
            return nil
        case .missingCredential:
            return "No App Password is stored for this account yet."
        case .authFailed:
            return "Gmail rejected the App Password. Check it and try again, or disconnect."
        case .networkError:
            return "Couldn't reach Gmail. Check your connection and try again."
        case .unknown:
            return "Verification failed for an unknown reason."
        }
    }
}