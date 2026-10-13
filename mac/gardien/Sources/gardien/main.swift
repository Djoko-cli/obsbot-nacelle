import Foundation
import GardienCore

// gardien : voir GardienCore.Gardien (spec B3 § 3.2). Ses lignes vont sur la sortie d'erreur, que PTZBot dirige vers
// go2rtc.log, comme celle de go2rtc.

/// Une ligne du gardien dans le journal.
func say(_ text: String) {
    FileHandle.standardError.write(Data("gardien : \(text)\n".utf8))
}

let options: GardienOptions
do {
    options = try GardienOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    say("options refusées (\(error))\n\(GardienOptions.usage)")
    exit(GardienExit.usage)
}
switch Gardien.run(options, log: say) {
case let .exited(status):
    exit(status)
case let .signaled(number):
    // La même fin que le programme : PTZBot voit go2rtc arrêté par ce signal.
    signal(number, SIG_DFL)
    kill(getpid(), number)
    exit(128 + number)
}
