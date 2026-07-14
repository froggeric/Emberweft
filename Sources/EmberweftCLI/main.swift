// emberweft — command-line tool. Placeholder for milestone M1 / slice S4.
// Planned verbs: render, animate, validate, info. See docs/engineering/development-approach.md.

import Foundation
import FlameKit

let argv = CommandLine.arguments
let prog = (argv.first as String?).map { ($0 as NSString).lastPathComponent } ?? "emberweft"

if argv.contains("--version") {
    print("emberweft \(FlameKit.version)")
} else {
    print("emberweft \(FlameKit.version) — pre-alpha (no commands yet)")
    print("Usage: \(prog) [--version]")
    print("Planned: render | animate | validate | info  (see docs/engineering/roadmap.md)")
}
