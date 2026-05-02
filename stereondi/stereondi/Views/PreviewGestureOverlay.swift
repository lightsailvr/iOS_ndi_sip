//  PreviewGestureOverlay.swift
//
//  Transparent overlay sitting above the MetalPreviewView in
//  ContentView's ZStack. Captures three gestures:
//
//   - Two-finger horizontal drag → adjusts AlignmentState.convergence.
//     Sensitivity: ~0.5 px convergence per logical point of horizontal
//     drag (PRD: ~1 px per ~2 logical points). Drag direction follows
//     the operator's finger — dragging right increases convergence.
//
//   - Pinch (MagnificationGesture) → zoomScale ∈ [1.0, 2.0]. Slice #6
//     models zoom as a SwiftUI .scaleEffect on the MTKView, not a
//     compositor change — slice #11 may bake it into the shader if the
//     2× UI scale ever produces visible aliasing on the iPad screen.
//
//   - Double-tap → reset zoomScale to 1.0.
//
//   - Slice #13: optional `onSingleTap` — invoked on a single-finger
//     tap. ContentView wires this to bump the chrome-visibility
//     timer (auto-hide-after-3s, PRD user story 23). A two-finger
//     drag does NOT call this — alignment sessions want hidden
//     chrome (issue sanity-check section).
//
//  The two-finger drag is implemented with a UIKit
//  UIPanGestureRecognizer (`minimum/maximumNumberOfTouches = 2`)
//  bridged via UIViewRepresentable, because SwiftUI's DragGesture
//  cannot distinguish two-finger from single-finger pans. The
//  recognizer is configured (via its delegate) to recognize
//  simultaneously with other gestures so the SwiftUI MagnificationGesture
//  on the same overlay still works on a true pinch — UIKit's pan
//  recognizer fails out of its own accord when the two touches move
//  divergently rather than in parallel.

import SwiftUI
import UIKit

struct PreviewGestureOverlay: View {
    let alignment: AlignmentState
    @Binding var zoom: CGFloat
    /// Slice #13: invoked on a single-finger tap on the preview area.
    /// ContentView uses this to bump the chrome-visibility timer.
    /// Two-finger drag does NOT call this — see file header.
    var onSingleTap: (() -> Void)? = nil

    private static let minZoom: CGFloat = 1.0
    private static let maxZoom: CGFloat = 2.0

    /// Pixels of convergence per logical-point of two-finger drag.
    /// PRD guidance: ~1 px convergence per ~2 logical points.
    private static let convergencePxPerDragPoint: Double = 0.5

    var body: some View {
        // Color.clear with contentShape gives the SwiftUI gestures a
        // hit-testable surface across the full overlay rect. The
        // UIKit two-finger pan lives in the overlay() above it.
        //
        // Order matters: the double-tap gesture is registered before
        // the single-tap, so a double-tap doesn't ALSO fire the
        // single-tap chrome bump (TapGesture(count:1) loses its
        // exclusivity to count:2 when both are present).
        Color.clear
            .contentShape(Rectangle())
            .gesture(magnification)
            .gesture(doubleTap)
            .gesture(singleTap)
            .overlay(
                TwoFingerPanGesture(alignment: alignment,
                                    pixelsPerPoint: Self.convergencePxPerDragPoint)
            )
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let next = max(Self.minZoom, min(Self.maxZoom, value))
                if zoom != next { zoom = next }
            }
    }

    private var doubleTap: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                if zoom != Self.minZoom {
                    zoom = Self.minZoom
                }
            }
    }

    /// Single-tap → bump the chrome-visibility timer in ContentView.
    /// `.exclusively(before: doubleTap)` would be the textbook chain
    /// but SwiftUI's TapGesture(count:2) already takes precedence
    /// over count:1 when both are attached via `.gesture(...)`, so
    /// the single-tap callback only fires after the double-tap window
    /// has elapsed without a second tap.
    private var singleTap: some Gesture {
        TapGesture(count: 1)
            .onEnded {
                onSingleTap?()
            }
    }
}

// MARK: - Two-finger pan (UIKit bridge)

/// A transparent UIView hosting a UIPanGestureRecognizer that requires
/// exactly two touches. Translations are converted to convergence
/// deltas applied to the @MainActor AlignmentState.
private struct TwoFingerPanGesture: UIViewRepresentable {
    let alignment: AlignmentState
    let pixelsPerPoint: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(alignment: alignment, pixelsPerPoint: pixelsPerPoint)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handle(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        // cancelsTouchesInView = false so SwiftUI's MagnificationGesture
        // (UIPinchGestureRecognizer under the hood) continues to receive
        // the same touches and can succeed if the operator's gesture
        // turns out to be a pinch rather than a parallel pan.
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.alignment = alignment
        context.coordinator.pixelsPerPoint = pixelsPerPoint
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var alignment: AlignmentState
        var pixelsPerPoint: Double

        private var startConvergence: Double = 0

        init(alignment: AlignmentState, pixelsPerPoint: Double) {
            self.alignment = alignment
            self.pixelsPerPoint = pixelsPerPoint
        }

        @objc func handle(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                startConvergence = alignment.convergence
            case .changed:
                let translation = recognizer.translation(in: view)
                let delta = Double(translation.x) * pixelsPerPoint
                alignment.convergence = AlignmentMath.clampHIT(startConvergence + delta)
            case .ended, .cancelled, .failed:
                break
            default:
                break
            }
        }

        nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith
                                           otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
