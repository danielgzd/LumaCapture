import Foundation

@main
enum PortableTests {
    static func main() {
        var failures = 0
        for check in CoreChecks.all {
            do {
                try check.run()
                print("PASS \(check.name)")
            } catch {
                failures += 1
                fputs("FAIL \(check.name): \(error)\n", stderr)
            }
        }
        print("\(CoreChecks.all.count - failures)/\(CoreChecks.all.count) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
