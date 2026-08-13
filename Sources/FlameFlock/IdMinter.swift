// Sources/FlameFlock/IdMinter.swift
import Foundation
import CryptoKit

/// Reserved-flock `900000` id minting for non-Electric-Sheep genomes (spec §7).
///
/// ES-sourced genomes pass through with their real `(gen,id)` (no minting).
/// Anything else gets a stable, deduped id in the reserved flock `900000`:
/// the identity is keyed on a SHA-256 of the source bytes, so minting the
/// same source twice returns the SAME `(gen,id)` — no regeneration, no
/// counter consumption. Idempotent + deterministic (rule #2).
public struct IdMinter: Sendable {
    public init() {}

    /// Resolve a genome to its stable `(gen,id)`.
    ///
    /// - ES passthrough: `origin == .es` with a real `(esGen, esId)` returns it
    ///   verbatim; no sheep row is touched, no counter consumed.
    /// - Otherwise: mint in flock `900000`, deduped on `sourceSha`. The first
    ///   mint for a given sha allocates the next 6-digit id (`nextMintedId`)
    ///   and writes a `sheep` row; subsequent mints for the same sha reuse it.
    /// - `sourceBytes == nil` ⇒ `sourceSha == ""` (a single shared bucket —
    ///   callers should pass real bytes to get per-source identity).
    public func resolve(catalog: FlockCatalog, esGen: String?, esId: String?,
                        origin: Sheep.Origin, sourceRef: URL?,
                        sourceBytes: Data?) async throws -> (gen: String, id: String) {
        // ES passthrough — no minting, no counter consumption.
        if origin == .es, let g = esGen, let i = esId { return (g, i) }

        // SHA-256 hex of the source bytes (mirrors ExportCoordinator's pattern).
        let sha: String = sourceBytes.map {
            SHA256.hash(data: $0).map { String(format: "%02x", Int($0)) }.joined()
        } ?? ""

        // Dedupe on source_sha: reuse the existing (gen,id) if present.
        if let existing = try await catalog.sheepBySourceSha(sha) {
            return (existing.gen, existing.id)
        }

        // New source ⇒ mint the next id in flock 900000 + persist the row.
        let id = try await catalog.nextMintedId()
        try await catalog.upsertSheep(gen: "900000", id: id, origin: origin,
                                      sourceRef: sourceRef, sourceSha: sha,
                                      displayName: nil)
        return ("900000", id)
    }
}
