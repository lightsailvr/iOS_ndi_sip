//  NDIAttributionScreen.swift
//
//  Slice #14. Renders the NDI® attribution required by the SDK
//  license. Reads the bundled `ndi_attribution.txt` resource (which
//  carries both the verbatim attribution string mandated by the PRD
//  and the MIT-license header text from `Processing.NDI.Lib.h`)
//  inside a scrollable monospaced text view.
//
//  PRD "Further Notes" → "NDI license attribution":
//     "NDI® is a registered trademark of Vizrt NDI AB; do not modify
//      the trademark presentation."
//  Hence the text is loaded verbatim from disk rather than constructed
//  from interpolated string fragments — there's no place in the path
//  where a stray edit could change the trademark presentation.
//
//  If the bundle resource is somehow missing (build-system mistake,
//  broken target membership), the screen falls back to the required
//  attribution literal so the operator-facing AC still holds. The
//  fallback path is exercised by `NDIAttributionTests` indirectly
//  (the tests assert the bundle resource IS present so the fallback
//  path stays hypothetical in production).

import SwiftUI

struct NDIAttributionScreen: View {

    /// Hard-coded fallback used when the bundle resource is missing.
    /// Matches the verbatim text required by the issue; the bundle
    /// resource carries the same opening paragraph plus the SDK MIT
    /// header.
    static let requiredAttribution: String = """
NDI® is a registered trademark of Vizrt NDI AB.
This application uses the NDI® Software Developer Kit
under license from Vizrt NDI AB. The full SDK license
is available at https://ndi.video/sdk-license/.
"""

    var body: some View {
        ScrollView {
            Text(Self.attributionText)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .accessibilityLabel("NDI attribution and SDK license text")
        }
        .navigationTitle("NDI® attribution")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Loads `ndi_attribution.txt` from the main bundle. Returns the
    /// hard-coded `requiredAttribution` literal as a defensive
    /// fallback if the resource is missing — `NDIAttributionTests`
    /// verifies the resource is bundled so the fallback path is
    /// never hit in shipping builds.
    static var attributionText: String {
        guard let url = Bundle.main.url(forResource: "ndi_attribution",
                                        withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return requiredAttribution
        }
        return contents
    }
}
