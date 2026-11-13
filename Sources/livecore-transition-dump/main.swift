// Writes the wrapped Metal source of every built-in custom transition (and the user template)
// to a folder, so scripts/check_shaders.sh can compile them offline with the Metal compiler.
//   Usage: livecore-transition-dump <output-dir>
import Foundation
import LiveCoreCore

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: livecore-transition-dump <output-dir>\n".data(using: .utf8)!)
    exit(2)
}
let dir = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
var items = BuiltInTransition.all.map { ($0.key, $0.code) }
items.append(("template", BuiltInTransition.template))
for (key, code) in items {
    if let problem = CustomTransitionSource.validate(code) {
        print("\(key): rejected by validation: \(problem)"); exit(1)
    }
    try CustomTransitionSource.wrap(code).write(to: dir.appendingPathComponent("transition-\(key).metal"), atomically: true, encoding: .utf8)
    print("wrote transition-\(key).metal")
}
