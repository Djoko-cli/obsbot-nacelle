import Foundation

/// Les emplacements de l'app, de ses utilitaires et des fichiers de l'utilisateur (spec ptzd dans l'app § 5.1 et § 5.2).
public struct AppPaths: Equatable, Sendable {
    /// `~/Library/Application Support/ObsbotNacelle`.
    public var support: URL
    /// `~/Library/Logs/obsbot-nacelle`.
    public var logs: URL
    /// `PTZBot.app/Contents/Helpers`.
    public var helpers: URL

    public init(bundle: URL, home: URL) {
        support = home.appending(path: "Library/Application Support/ObsbotNacelle")
        logs = home.appending(path: "Library/Logs/obsbot-nacelle")
        helpers = bundle.appending(path: "Contents/Helpers")
    }

    /// Les emplacements réels : l'app en cours et le dossier de l'utilisateur. Pour l'app seulement ; les tests
    /// passent des dossiers temporaires.
    public static func system() -> AppPaths {
        AppPaths(bundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public var config: URL {
        support.appending(path: "config.json")
    }

    public var sdkDirectory: URL {
        support.appending(path: "sdk")
    }

    public var ptzdLog: URL {
        logs.appending(path: "ptzd.log")
    }

    public var ptzd: URL {
        helpers.appending(path: "ptzd")
    }

    public var obsbotAI: URL {
        helpers.appending(path: "obsbot-ai")
    }

    /// Ce que le superviseur donne à ptzd.
    public var service: ServiceSupervisor.Paths {
        ServiceSupervisor.Paths(ptzd: ptzd, ai: obsbotAI, sdkDirectory: sdkDirectory, log: ptzdLog)
    }
}

extension SDKInstaller {
    /// L'installateur de l'app : `sdk/` de l'utilisateur, vérifié par l'obsbot-ai du paquet.
    public static func system(paths: AppPaths) -> SDKInstaller {
        let obsbotAI = paths.obsbotAI
        return SDKInstaller(
            sdkDirectory: paths.sdkDirectory,
            verifier: obsbotAIVerifier(executableURL: obsbotAI),
            executableAvailable: { FileManager.default.isExecutableFile(atPath: obsbotAI.path) }
        )
    }
}
