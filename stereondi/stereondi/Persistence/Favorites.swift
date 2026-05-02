//  Favorites.swift
//
//  A "favorite" is a named source pair plus the alignment values the
//  operator dialed in for that rig. Applying a favorite at runtime
//  sets both `selection.left/right` and pushes HIT/crop into
//  AlignmentState — one tap brings the rig back to known-good.
//
//  Storage: an array of `Favorite`s rides on `SessionStore.favorites`,
//  serialized as a single JSON blob. Mutation happens via the
//  `FavoritesViewModel` @Observable so SwiftUI views can List + swipe-
//  to-delete + add via the source-picker UI.
//
//  Slice #11 scope:
//   - CRUD (create / read / delete) lives in the source-picker sheet.
//   - Rename / reorder is intentionally not in this slice — operators
//     can delete + re-save to rename. A future polish slice can add
//     proper rename / drag-reorder if it surfaces as a real-world need.
//
//  Per the issue, a favorite carries source identifiers AND alignment
//  values. The alignment-value snapshot is taken at "save" time, so
//  saving from a session where convergence is +50 captures +50;
//  applying that favorite later sets convergence back to +50 exactly.

import Foundation
import Observation

/// Codable, Identifiable favorite. Equatable + Hashable so SwiftUI
/// `ForEach(_, id:)` and selection-binding workflows work without
/// extra plumbing. The `id` is a stable UUID generated at save time —
/// renaming a favorite (a future slice) would keep the same `id` so
/// the row identity is preserved across the rename.
struct Favorite: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String

    var leftSourceName: String
    var leftSourceURL: String
    var rightSourceName: String
    var rightSourceURL: String

    var convergence: Double
    var leftFineHIT: Double
    var rightFineHIT: Double
    var cropMode: CropMode

    init(id: UUID = UUID(),
         name: String,
         leftSourceName: String,
         leftSourceURL: String,
         rightSourceName: String,
         rightSourceURL: String,
         convergence: Double,
         leftFineHIT: Double,
         rightFineHIT: Double,
         cropMode: CropMode) {
        self.id = id
        self.name = name
        self.leftSourceName = leftSourceName
        self.leftSourceURL = leftSourceURL
        self.rightSourceName = rightSourceName
        self.rightSourceURL = rightSourceURL
        self.convergence = convergence
        self.leftFineHIT = leftFineHIT
        self.rightFineHIT = rightFineHIT
        self.cropMode = cropMode
    }
}

/// SwiftUI-facing wrapper around `SessionStore.favorites`. Reads the
/// list once on construction and republishes after every CRUD; each
/// CRUD also writes through to `SessionStore` so the on-disk copy
/// stays current.
///
/// Construction takes a `SessionStore` so tests can inject a per-test
/// store backed by a fresh suite. Production code uses the convenience
/// initializer that pulls from `SessionStore.shared`.
@MainActor
@Observable
final class FavoritesViewModel {
    private(set) var favorites: [Favorite]
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
        self.favorites = store.favorites
    }

    convenience init() {
        self.init(store: .shared)
    }

    /// Snapshot the operator's current source pair + alignment into a
    /// new favorite. Returns the created favorite for the caller's
    /// convenience (for example, to display "Saved 'Stage A'" toast
    /// in a future polish slice). Trims `name`; an empty name after
    /// trimming is rejected (returns nil and does not append).
    @discardableResult
    func saveCurrent(name: String,
                     selection: SourceSelection,
                     alignment: AlignmentState) -> Favorite? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let left = selection.leftSource,
              let right = selection.rightSource else {
            return nil
        }
        let favorite = Favorite(name: trimmed,
                                leftSourceName: left.name,
                                leftSourceURL: left.urlAddress,
                                rightSourceName: right.name,
                                rightSourceURL: right.urlAddress,
                                convergence: alignment.convergence,
                                leftFineHIT: alignment.leftFineHIT,
                                rightFineHIT: alignment.rightFineHIT,
                                cropMode: alignment.cropMode)
        favorites.append(favorite)
        persist()
        return favorite
    }

    /// Set both sides of `selection` and push the favorite's alignment
    /// snapshot into `alignment`. The compositor reads the new HIT /
    /// crop values fresh on the next pairer tick (per slice #6's
    /// no-caching contract) so the rig snaps to the saved alignment
    /// within one frame.
    func apply(_ favorite: Favorite,
               to selection: SourceSelection,
               alignment: AlignmentState) {
        selection.leftSource = NDISource(name: favorite.leftSourceName,
                                         urlAddress: favorite.leftSourceURL)
        selection.rightSource = NDISource(name: favorite.rightSourceName,
                                          urlAddress: favorite.rightSourceURL)
        alignment.convergence = favorite.convergence
        alignment.leftFineHIT = favorite.leftFineHIT
        alignment.rightFineHIT = favorite.rightFineHIT
        alignment.cropMode = favorite.cropMode
    }

    func delete(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
        persist()
    }

    func delete(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        store.favorites = favorites
    }
}
