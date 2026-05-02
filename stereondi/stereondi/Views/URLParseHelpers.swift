//  URLParseHelpers.swift
//
//  Pure URL-parsing helpers extracted from SourcePickerSheet so the
//  parsing logic is unit-testable without touching SwiftUI.
//
//  The accepted input format for the manual-entry row is
//      ndi://HOST[:PORT]/STREAMNAME
//  with STREAMNAME percent-encoded only if the user pastes a URL their
//  source software produced; bare names with spaces are accepted as-is
//  for operator convenience.

import Foundation

enum URLParseHelpers {

    static func parseNDIURL(_ raw: String) -> (host: String, port: Int?, name: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ndi://"
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }

        let rest = trimmed.dropFirst(prefix.count)
        guard let firstSlash = rest.firstIndex(of: "/") else { return nil }

        let authority = String(rest[..<firstSlash])
        let nameRaw = String(rest[rest.index(after: firstSlash)...])
        guard !authority.isEmpty, !nameRaw.isEmpty else { return nil }

        let name = nameRaw.removingPercentEncoding ?? nameRaw

        let host: String
        let port: Int?

        if authority.hasPrefix("[") {
            // IPv6 literal: [::1] or [::1]:5960
            guard let closeBracket = authority.firstIndex(of: "]") else { return nil }
            host = String(authority[authority.index(after: authority.startIndex)..<closeBracket])
            let afterClose = authority[authority.index(after: closeBracket)...]
            if afterClose.isEmpty {
                port = nil
            } else if afterClose.hasPrefix(":") {
                guard let parsed = Int(afterClose.dropFirst()), parsed > 0, parsed <= 65535 else {
                    return nil
                }
                port = parsed
            } else {
                return nil
            }
        } else if let colon = authority.lastIndex(of: ":") {
            host = String(authority[..<colon])
            let portStr = authority[authority.index(after: colon)...]
            guard let parsed = Int(portStr), parsed > 0, parsed <= 65535 else {
                return nil
            }
            port = parsed
        } else {
            host = authority
            port = nil
        }

        guard !host.isEmpty else { return nil }
        return (host, port, name)
    }
}
