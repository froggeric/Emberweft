// Sources/FlameFlock/ListXmlExporter.swift
import Foundation

/// Emits the ES `<list>` XML interchange for a shard (spec §9).
///
/// `export(shard:flockRoot:edgesDb:)` writes `<shard>.xml` **beside** the shard
/// directory (at the flock root), with one
/// `<sheep id=… first=… last=… url=…/>` per cataloged artifact, in deterministic
/// `(a_gen,a_id,b_gen,b_id)` order (rule #2). For ES-sourced edges (both
/// endpoints real ES, same gen) the real ES `edge_id` is recovered from
/// `edges.sqlite` via `EdgePairsOracle` (lowest on duplicates); non-ES /
/// cross-gen / minted edges get a synthesized, stable, collision-free id
/// `minted-<aGen>-<aId>-<bGen>-<bId>`.
///
/// This is a **derived** artifact (D5): `flock.sqlite` stays the only primary
/// catalog. The `gen` attribute is omitted from `<list>` — a flock shard can
/// mix ES / minted / cross-gen sheep, so there is no single ES gen to advertise.
public struct ListXmlExporter: Sendable {
    public init() {}

    /// Write `<shard>.xml` beside the shard dir; returns the XML URL.
    ///
    /// - Parameters:
    ///   - shard: shard name (its row supplies the `size="W H"`).
    ///   - flockRoot: flock directory (holds `flock.sqlite` + `<shard>/`).
    ///   - edgesDb: `edges.sqlite` URL for ES `edge_id` recovery, or nil to
    ///     synthesize every id (best-effort interchange, D1).
    public func export(shard: String, flockRoot: URL, edgesDb: URL?) async throws -> URL {
        let cat = try FlockCatalog(root: flockRoot)
        guard let spec = try await cat.shard(named: shard) else {
            throw ListXmlError.shardNotFound(shard)
        }
        let rows = try await cat.artifactsIn(shard: shard)
        // Open the oracle only if a DB was supplied; a corrupt/unopenable DB
        // surfaces as an error (the caller asked for recovery and can't get it).
        var oracle: EdgePairsOracle? = nil
        if let edgesDb { oracle = try EdgePairsOracle(url: edgesDb) }

        var lines: [String] = []
        lines.reserveCapacity(rows.count)
        for row in rows {
            let id = try resolvedId(for: row, oracle: oracle)
            lines.append("<sheep id=\"\(esc(id))\" first=\"\(esc(row.aGen))/\(esc(row.aId))\" last=\"\(esc(row.bGen))/\(esc(row.bId))\" url=\"\(esc(row.file))\"/>")
        }
        let header = "<?xml version=\"1.0\"?>\n<list size=\"\(spec.width) \(spec.height)\">"
        let xml = header + "\n" + lines.joined(separator: "\n") + "\n</list>\n"
        let xmlURL = flockRoot.appendingPathComponent("\(shard).xml")
        try xml.write(to: xmlURL, atomically: true, encoding: .utf8)
        return xmlURL
    }

    /// Recover the ES `edge_id` for an ES-sourced edge (same-gen, non-minted);
    /// synthesize `minted-<aGen>-<aId>-<bGen>-<bId>` otherwise, or when the
    /// oracle is absent / the pair isn't in `edges.sqlite`. The full quad makes
    /// the synthesized id collision-free across cross-gen combinations and
    /// stable across re-exports (deterministic from the row).
    private func resolvedId(for row: ArtifactRow,
                            oracle: EdgePairsOracle?) throws -> String {
        let isEsSourced = (row.aGen == row.bGen) && (row.aGen != "900000")
        if isEsSourced, let oracle {
            if let recovered = try oracle.edgeId(aGen: row.aGen, aId: row.aId,
                                                 bGen: row.bGen, bId: row.bId) {
                return recovered
            }
        }
        return "minted-\(row.aGen)-\(row.aId)-\(row.bGen)-\(row.bId)"
    }

    /// XML-escape an attribute value: `&` first (so it isn't double-encoded by
    /// the later entities), then `<`, `>`, `"`. Pure string function
    /// (rule-#2-safe).
    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Local errors for `ListXmlExporter`.
public enum ListXmlError: Error, Equatable {
    /// The shard isn't cataloged in `flock.sqlite` (no `size` to emit).
    case shardNotFound(String)
}
