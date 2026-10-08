import Foundation

/// Les emplacements de l'app, de ses utilitaires et des fichiers de l'utilisateur (spec ptzd dans l'app § 5.1 et § 5.2,
/// spec distribution § 5.1 et § 6).
public struct AppPaths: Equatable, Sendable {
    /// `~/Library/Application Support/ObsbotNacelle`.
    public var support: URL
    /// `~/Library/Logs/obsbot-nacelle`.
    public var logs: URL
    /// `PTZBot.app/Contents/Helpers`.
    public var helpers: URL
    /// `PTZBot.app/Contents/Resources`.
    public var resources: URL

    public init(bundle: URL, home: URL) {
        support = home.appending(path: "Library/Application Support/ObsbotNacelle")
        logs = home.appending(path: "Library/Logs/obsbot-nacelle")
        helpers = bundle.appending(path: "Contents/Helpers")
        resources = bundle.appending(path: "Contents/Resources")
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

    /// obsbot-ai, compilé chez l'utilisateur à côté du SDK (spec distribution § 6.4) : jamais dans l'app.
    public var obsbotAI: URL {
        sdkDirectory.appending(path: "obsbot-ai")
    }

    /// La source d'obsbot-ai livrée dans l'app, identique à `mac/ai/main.cpp`.
    public var obsbotAISource: URL {
        resources.appending(path: "obsbot-ai.cpp")
    }

    /// La sortie de clang++ quand la compilation d'obsbot-ai échoue.
    public var obsbotAIBuildLog: URL {
        logs.appending(path: "obsbot-ai-compilation.log")
    }

    /// Ce que le superviseur donne à ptzd.
    public var service: ServiceSupervisor.Paths {
        ServiceSupervisor.Paths(ptzd: ptzd, ai: obsbotAI, sdkDirectory: sdkDirectory, log: ptzdLog)
    }
}

extension SDKInstaller {
    /// L'installateur de l'app : `sdk/` de l'utilisateur, la source livrée dans l'app, les outils d'Apple.
    public static func system(paths: AppPaths) -> SDKInstaller {
        SDKInstaller(
            sdkDirectory: paths.sdkDirectory,
            sourceURL: paths.obsbotAISource,
            toolchain: SystemToolchain.system(),
            verifier: obsbotAIVerifier(),
            buildLog: paths.obsbotAIBuildLog
        )
    }
}
