//  OutputStreamConfigTests.swift
//
//  Pure-Swift tests for OutputStreamConfig — no UIKit, no Metal, no
//  NDI network. Covers default values, the trim-and-fall-back behavior
//  on `effectiveStreamName`, and the trim-or-nil behavior on
//  `effectiveGroups`. Confirms that the comma-separated groups string
//  is passed through verbatim (NDI accepts the raw form natively;
//  parsing into an array is not this slice's job).

import Foundation
import Testing
@testable import stereondi

@MainActor
struct OutputStreamConfigTests {

    @Test
    func defaultsMatchSpec() {
        let config = OutputStreamConfig()
        #expect(config.streamName == "Stereo Preview")
        #expect(config.groups == "Public")
        #expect(config.effectiveStreamName == "Stereo Preview")
        #expect(config.effectiveGroups == "Public")
    }

    @Test
    func streamNameTrimsLeadingAndTrailingWhitespace() {
        let config = OutputStreamConfig()
        config.streamName = "  Stage A 3D  "
        #expect(config.effectiveStreamName == "Stage A 3D")
    }

    @Test
    func emptyStreamNameFallsBackToDefault() {
        let config = OutputStreamConfig()
        config.streamName = ""
        #expect(config.effectiveStreamName == "Stereo Preview")
    }

    @Test
    func whitespaceOnlyStreamNameFallsBackToDefault() {
        let config = OutputStreamConfig()
        config.streamName = "   \t\n"
        #expect(config.effectiveStreamName == "Stereo Preview")
    }

    @Test
    func emptyGroupsBecomesNil() {
        let config = OutputStreamConfig()
        config.groups = ""
        #expect(config.effectiveGroups == nil)
    }

    @Test
    func whitespaceOnlyGroupsBecomesNil() {
        let config = OutputStreamConfig()
        config.groups = "  \n  "
        #expect(config.effectiveGroups == nil)
    }

    @Test
    func commaSeparatedGroupsPassesThroughVerbatim() {
        // NDI accepts the raw comma-separated string for `p_groups`;
        // we don't parse into an array — only trim outer whitespace.
        let config = OutputStreamConfig()
        config.groups = "Public, Studio2"
        #expect(config.effectiveGroups == "Public, Studio2")
    }

    @Test
    func groupsTrimsOuterWhitespaceButPreservesInnerCommaSpacing() {
        let config = OutputStreamConfig()
        config.groups = "  Public,Studio2 , OnAir  "
        #expect(config.effectiveGroups == "Public,Studio2 , OnAir")
    }

    @Test
    func streamNameRoundTripsNonAsciiCharacters() {
        // The NDI sender encodes the stream name as UTF-8 (see
        // NDISender.mm); make sure non-ASCII characters survive the
        // sanitization layer unmolested so a Studio with e.g. "Stéréo"
        // in their stream name list works as expected.
        let config = OutputStreamConfig()
        config.streamName = "Stéréo Préview"
        #expect(config.effectiveStreamName == "Stéréo Préview")
    }
}
