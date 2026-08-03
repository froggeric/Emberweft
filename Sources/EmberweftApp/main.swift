import Foundation
import EmberweftCLI

// Top-level `await` (Swift 6.2): the executable entry point is implicitly
// @MainActor-isolated, so `await run(...)` stays on the main actor — keeping the
// sync subcommands' `MainActor.assumeIsolated` calls valid, while letting the
// async `export` path drive `ExportCoordinator` without blocking the main thread
// (which would deadlock the coordinator's `await MainActor.run` Metal hops).
exit(await EmberweftCLI.run(CommandLine.arguments))
