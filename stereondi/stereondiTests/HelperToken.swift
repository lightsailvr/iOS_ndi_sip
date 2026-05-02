//  HelperToken.swift
//
//  Empty marker class used solely as a `Bundle(for:)` argument so the
//  golden-image test code can resolve the test bundle without needing
//  to live inside an XCTestCase subclass. Swift Testing's @Test
//  free functions don't carry a class context, so we need a stable
//  Objective-C-visible class to anchor the bundle lookup.

import Foundation

final class HelperToken {}
