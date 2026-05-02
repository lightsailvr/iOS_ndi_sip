//  StatusRowFormattingTests.swift
//
//  Pure-Swift tests for the formatting helpers behind the per-eye
//  StatusRow. The SwiftUI view itself isn't tested (per PRD: no
//  snapshot tests); the strings + dot color it renders are pulled
//  out into `StatusRowFormatter` so we can exercise them without
//  standing up SwiftUI / Metal / NDI.
//
//  Slice #13 contract:
//   - "1920×1080 @ 60.0 fps" for a .live source with frameRate=60.0
//   - "59.9 fps" for fractional rates (one decimal place)
//   - "No source" empty-state label
//   - dot color: live=green, connecting/reconnecting=yellow,
//     stalled/empty distinct, etc.

import SwiftUI
import Testing
@testable import stereondi

@MainActor
struct StatusRowFormattingTests {

    // MARK: - sourceLabel

    @Test
    func sourceLabelForNilNameReturnsNoSource() {
        #expect(StatusRowFormatter.sourceLabel(name: nil) == "No source")
    }

    @Test
    func sourceLabelForEmptyStringReturnsNoSource() {
        #expect(StatusRowFormatter.sourceLabel(name: "") == "No source")
    }

    @Test
    func sourceLabelForNonEmptyNamePassesThroughVerbatim() {
        #expect(StatusRowFormatter.sourceLabel(name: "RIG-A (Cam-L)") == "RIG-A (Cam-L)")
    }

    // MARK: - metricsLabel

    @Test
    func metricsLabelForLiveStatusFormatsResolutionAndFrameRate() {
        let status = ReceiverWatchdog.SideStatus.live(width: 1920,
                                                      height: 1080,
                                                      frameRate: 59.94)
        #expect(StatusRowFormatter.metricsLabel(for: status) == "1920×1080 @ 59.9 fps")
    }

    @Test
    func metricsLabelForLiveStatusWithExact60FpsRendersOneDecimal() {
        let status = ReceiverWatchdog.SideStatus.live(width: 1920,
                                                      height: 1080,
                                                      frameRate: 60.0)
        #expect(StatusRowFormatter.metricsLabel(for: status) == "1920×1080 @ 60.0 fps")
    }

    @Test
    func metricsLabelForLiveStatusWithUnknownFrameRateOmitsFpsClause() {
        // frameRate == 0 is the "haven't observed a rate yet" case
        // surfaced by the watchdog before the first frame arrives.
        let status = ReceiverWatchdog.SideStatus.live(width: 1280,
                                                      height: 720,
                                                      frameRate: 0)
        #expect(StatusRowFormatter.metricsLabel(for: status) == "1280×720")
    }

    @Test
    func metricsLabelForReconnectingIsEmpty() {
        #expect(StatusRowFormatter.metricsLabel(for: .reconnecting) == "")
    }

    @Test
    func metricsLabelForStalledIsEmpty() {
        #expect(StatusRowFormatter.metricsLabel(for: .stalled) == "")
    }

    @Test
    func metricsLabelForEmptyStatusIsEmpty() {
        #expect(StatusRowFormatter.metricsLabel(for: .empty) == "")
    }

    @Test
    func metricsLabelForConnectingIsEmpty() {
        #expect(StatusRowFormatter.metricsLabel(for: .connecting) == "")
    }

    // MARK: - formatFrameRate (one-decimal style, en_US_POSIX)

    @Test
    func frameRateFormatterRoundsToOneDecimal() {
        #expect(StatusRowFormatter.formatFrameRate(59.94) == "59.9")
        #expect(StatusRowFormatter.formatFrameRate(60.0) == "60.0")
        #expect(StatusRowFormatter.formatFrameRate(29.97) == "30.0")
        #expect(StatusRowFormatter.formatFrameRate(23.976) == "24.0")
    }

    @Test
    func frameRateFormatterUsesPeriodDecimalRegardlessOfLocale() {
        // The formatter is pinned to en_US_POSIX so a downstream tool
        // reading the debug log on a comma-decimal locale doesn't
        // misparse "59,9 fps".
        let formatted = StatusRowFormatter.formatFrameRate(59.94)
        #expect(formatted.contains("."))
        #expect(!formatted.contains(","))
    }

    // MARK: - stateLabel

    @Test
    func stateLabelForEachStatus() {
        #expect(StatusRowFormatter.stateLabel(
            for: .live(width: 1920, height: 1080, frameRate: 60)) == "Live")
        #expect(StatusRowFormatter.stateLabel(for: .reconnecting) == "Reconnecting")
        #expect(StatusRowFormatter.stateLabel(for: .stalled) == "Stalled")
        #expect(StatusRowFormatter.stateLabel(for: .connecting) == "Connecting")
        #expect(StatusRowFormatter.stateLabel(for: .empty) == "No source")
    }

    // MARK: - dotColor

    @Test
    func dotColorForLiveIsGreen() {
        #expect(StatusRowFormatter.dotColor(
            for: .live(width: 1920, height: 1080, frameRate: 60)) == .green)
    }

    @Test
    func dotColorForReconnectingIsYellow() {
        #expect(StatusRowFormatter.dotColor(for: .reconnecting) == .yellow)
    }

    @Test
    func dotColorForConnectingIsYellow() {
        #expect(StatusRowFormatter.dotColor(for: .connecting) == .yellow)
    }

    @Test
    func dotColorForStalledIsRed() {
        #expect(StatusRowFormatter.dotColor(for: .stalled) == .red)
    }

    @Test
    func dotColorForEmptyIsGray() {
        #expect(StatusRowFormatter.dotColor(for: .empty) == .gray)
    }

    // MARK: - accessibilityLabel composes the per-eye utterance

    @Test
    func accessibilityLabelForLiveCombinesAllFields() {
        let status = ReceiverWatchdog.SideStatus.live(width: 1920,
                                                      height: 1080,
                                                      frameRate: 60.0)
        let label = StatusRowFormatter.accessibilityLabel(side: .left,
                                                          sourceName: "RIG-A",
                                                          status: status)
        #expect(label == "Left: RIG-A, 1920×1080 @ 60.0 fps, Live")
    }

    @Test
    func accessibilityLabelForEmptyOmitsMetricsClause() {
        let label = StatusRowFormatter.accessibilityLabel(side: .right,
                                                          sourceName: nil,
                                                          status: .empty)
        #expect(label == "Right: No source, No source")
    }
}
