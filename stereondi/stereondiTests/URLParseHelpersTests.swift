//  URLParseHelpersTests.swift

import Testing
@testable import stereondi

struct URLParseHelpersTests {

    @Test func parsesHostPortAndName() {
        let parsed = URLParseHelpers.parseNDIURL("ndi://10.0.0.5:5960/Cam-A")
        #expect(parsed?.host == "10.0.0.5")
        #expect(parsed?.port == 5960)
        #expect(parsed?.name == "Cam-A")
    }

    @Test func parsesHostWithoutPort() {
        let parsed = URLParseHelpers.parseNDIURL("ndi://192.168.1.10/Quest-Receiver")
        #expect(parsed?.host == "192.168.1.10")
        #expect(parsed?.port == nil)
        #expect(parsed?.name == "Quest-Receiver")
    }

    @Test func decodesNameWithSpaces() {
        let parsed = URLParseHelpers.parseNDIURL("ndi://10.0.0.5:5960/Cam A With Spaces")
        #expect(parsed?.host == "10.0.0.5")
        #expect(parsed?.port == 5960)
        #expect(parsed?.name == "Cam A With Spaces")
    }

    @Test func decodesPercentEncodedName() {
        let parsed = URLParseHelpers.parseNDIURL("ndi://10.0.0.5:5960/Cam%20A%20With%20Spaces")
        #expect(parsed?.host == "10.0.0.5")
        #expect(parsed?.port == 5960)
        #expect(parsed?.name == "Cam A With Spaces")
    }

    @Test func rejectsNonNDIScheme() {
        #expect(URLParseHelpers.parseNDIURL("http://x") == nil)
    }

    @Test func rejectsGarbage() {
        #expect(URLParseHelpers.parseNDIURL("not a url") == nil)
    }

    @Test func rejectsMissingStreamName() {
        #expect(URLParseHelpers.parseNDIURL("ndi://10.0.0.5:5960/") == nil)
    }

    @Test func rejectsMissingHost() {
        #expect(URLParseHelpers.parseNDIURL("ndi:///Cam-A") == nil)
    }

    @Test func rejectsInvalidPort() {
        #expect(URLParseHelpers.parseNDIURL("ndi://10.0.0.5:notaport/Cam-A") == nil)
    }

    @Test func acceptsLeadingTrailingWhitespace() {
        let parsed = URLParseHelpers.parseNDIURL("  ndi://10.0.0.5:5960/Cam-A  ")
        #expect(parsed?.host == "10.0.0.5")
        #expect(parsed?.port == 5960)
        #expect(parsed?.name == "Cam-A")
    }
}
