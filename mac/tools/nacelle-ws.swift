// Client WebSocket de test pour ptzd : envoie des messages, affiche les réponses.
//
// Usage : swift mac/tools/nacelle-ws.swift ws://<adresse>:<port> [étape]…
//   '<json>'                 envoie ce message
//   wait <s>                 attend <s> secondes
//   hold <s> <pan> <tilt>    envoie move toutes les 100 ms pendant <s> secondes, puis move 0,0
//
// Exemple : swift mac/tools/nacelle-ws.swift ws://127.0.0.1:1985 '{"type":"takeControl"}' wait 6 hold 1 0.5 0
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first, let url = URL(string: first), url.scheme == "ws" else {
    print("usage : swift nacelle-ws.swift ws://<adresse>:<port> ['<json>' | wait <s> | hold <s> <pan> <tilt>]…")
    exit(2)
}

func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

let task = URLSession.shared.webSocketTask(with: url)
task.resume()

Task {
    while true {
        do {
            if case let .string(text) = try await task.receive() {
                print("← \(stamp()) \(text)")
            }
        } catch {
            print("Connexion fermée : \(error.localizedDescription)")
            exit(1)
        }
    }
}

func send(_ text: String, quiet: Bool = false) async throws {
    if !quiet {
        print("→ \(stamp()) \(text)")
    }
    try await task.send(.string(text))
}

var steps = arguments.dropFirst()[...]
while let step = steps.popFirst() {
    switch step {
    case "wait":
        let seconds = Double(steps.popFirst() ?? "") ?? 1
        try await Task.sleep(for: .seconds(seconds))
    case "hold":
        let seconds = Double(steps.popFirst() ?? "") ?? 1
        let pan = Double(steps.popFirst() ?? "") ?? 0
        let tilt = Double(steps.popFirst() ?? "") ?? 0
        print("→ \(stamp()) move \(pan),\(tilt) pendant \(seconds) s")
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await send(#"{"type":"move","pan":\#(pan),"tilt":\#(tilt)}"#, quiet: true)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await send(#"{"type":"move","pan":0,"tilt":0}"#)
    default:
        try await send(step)
    }
}
try await Task.sleep(for: .seconds(1))
task.cancel(with: .normalClosure, reason: nil)
