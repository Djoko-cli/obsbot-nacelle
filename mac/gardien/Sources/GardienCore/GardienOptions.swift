import Foundation

/// Les options du gardien : `gardien --parent <pid> --arret <secondes> -- <programme> [arguments…]` (spec B3 § 3.2).
public struct GardienOptions: Equatable, Sendable {
    /// Le processus surveillé (PTZBot) : s'il disparaît, le programme est arrêté.
    public var parent: pid_t
    /// Le délai laissé au programme entre SIGTERM et SIGKILL, en secondes.
    public var stopDelay: TimeInterval
    /// Le programme, par son chemin absolu.
    public var program: String
    public var arguments: [String]

    public init(parent: pid_t, stopDelay: TimeInterval, program: String, arguments: [String]) {
        self.parent = parent
        self.stopDelay = stopDelay
        self.program = program
        self.arguments = arguments
    }

    public static let usage = "usage : gardien --parent <pid> --arret <secondes> -- <programme> [arguments…]"
    /// Le plus long délai d'arrêt accepté.
    public static let maximumStopDelay: TimeInterval = 300

    public enum ParseError: Error, Equatable {
        case unknownOption(String)
        case missingValue(String)
        case invalidValue(option: String, value: String)
        case duplicate(String)
        case missingOption(String)
        case missingProgram
    }

    /// Lit `--parent` et `--arret`, chacun une fois, dans n'importe quel ordre, puis `--` : tout ce qui suit est au
    /// programme, même ce qui ressemble à une option. Le PID est un entier strictement positif ; le délai, un nombre de
    /// secondes entre 0 et `maximumStopDelay` ; le programme, un chemin absolu.
    public static func parse(_ arguments: [String]) throws(ParseError) -> GardienOptions {
        var parent: pid_t?
        var stopDelay: TimeInterval?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let option = arguments[index]
            if option == "--" {
                let rest = arguments[arguments.index(after: index)...]
                guard let program = rest.first else { throw .missingProgram }
                guard program.hasPrefix("/") else { throw .invalidValue(option: "--", value: program) }
                guard let parent else { throw .missingOption("--parent") }
                guard let stopDelay else { throw .missingOption("--arret") }
                return GardienOptions(parent: parent, stopDelay: stopDelay, program: program, arguments: Array(rest.dropFirst()))
            }
            guard option == "--parent" || option == "--arret" else { throw .unknownOption(option) }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex else { throw .missingValue(option) }
            let value = arguments[next]
            if option == "--parent" {
                guard parent == nil else { throw .duplicate(option) }
                guard let pid = pid_t(value), pid > 0 else { throw .invalidValue(option: option, value: value) }
                parent = pid
            } else {
                guard stopDelay == nil else { throw .duplicate(option) }
                guard let seconds = TimeInterval(value), seconds.isFinite, (0...maximumStopDelay).contains(seconds) else {
                    throw .invalidValue(option: option, value: value)
                }
                stopDelay = seconds
            }
            index = arguments.index(after: next)
        }
        throw .missingProgram
    }
}
