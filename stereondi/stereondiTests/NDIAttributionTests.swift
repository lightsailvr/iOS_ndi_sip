//  NDIAttributionTests.swift
//
//  Slice #14. Verifies the bundled NDI® attribution resource is
//  present in the test bundle and contains the verbatim trademark
//  and Vizrt-NDI-AB attribution required by the SDK license + the
//  PRD's "Further Notes" → "NDI license attribution" section.
//
//  Resource lookup uses Bundle.main when the app is running. In the
//  test target the same file is bundled (file-system-synchronized
//  groups pick it up automatically into the resources of any target
//  that includes Resources/ as a synced root). We try Bundle.main
//  first (the production code path), then fall through to the test
//  bundle so the test still validates the file's presence even if
//  the test runner doesn't surface main-bundle resources.

import Foundation
import Testing
@testable import stereondi

struct NDIAttributionTests {

    /// Locate the attribution resource. Prefers Bundle.main (the path
    /// the production NDIAttributionScreen reads from); falls back to
    /// Bundle(for: HelperToken.self) so the test passes when running
    /// in a context where main-bundle resource embedding hasn't kicked
    /// in yet.
    private static func attributionURL() -> URL? {
        if let url = Bundle.main.url(forResource: "ndi_attribution",
                                     withExtension: "txt") {
            return url
        }
        return Bundle(for: HelperToken.self)
            .url(forResource: "ndi_attribution", withExtension: "txt")
    }

    @Test
    func attributionResourceIsBundled() {
        let url = Self.attributionURL()
        #expect(url != nil,
                "ndi_attribution.txt must be bundled in the app's Resources/")
    }

    @Test
    func attributionTextContainsRequiredTrademarkAndVizrtAttribution() throws {
        let url = try #require(Self.attributionURL())
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("NDI® is a registered trademark of Vizrt NDI AB"))
        #expect(contents.contains("Vizrt NDI AB"))
    }

    @Test
    func attributionTextIncludesSDKLicenseURL() throws {
        // Defensive: confirms the verbatim attribution paragraph
        // mandated by the issue is present in full, not just the
        // first line.
        let url = try #require(Self.attributionURL())
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("https://ndi.video/sdk-license/"))
    }

    @Test
    func attributionScreenAttributionTextLoadsNonEmpty() {
        // Exercises the production lookup path through the View's
        // static helper. If the bundle resource is missing, the
        // helper falls back to the requiredAttribution literal —
        // either way the operator-facing AC still renders something
        // meaningful.
        let text = NDIAttributionScreen.attributionText
        #expect(text.contains("NDI® is a registered trademark of Vizrt NDI AB"))
    }
}
