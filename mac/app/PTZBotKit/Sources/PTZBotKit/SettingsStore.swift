import Foundation

/// Les préférences de l'app, derrière un protocole pour les tests.
@MainActor
public protocol SettingsStore: AnyObject {
    func bool(forKey key: String) -> Bool?
    func set(_ value: Bool, forKey key: String)
    func string(forKey key: String) -> String?
    /// nil retire la clé.
    func set(_ value: String?, forKey key: String)
    /// nil retire la clé.
    func set(_ value: [String]?, forKey key: String)
}

/// Implémentation réelle : `UserDefaults`.
@MainActor
public final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func bool(forKey key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    public func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    public func set(_ value: [String]?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
