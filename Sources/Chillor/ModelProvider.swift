import Foundation
import Security

/// Which engine serves this Mac's requests. Persisted so a switch survives relaunch.
/// Local stays the default: a cloud provider is only used after the user picks one.
enum ModelProvider:String,CaseIterable {
    case local
    case deepseek
}

struct RemoteModelChoice:Identifiable,Equatable {
    let id:String
    let title:String
    let detail:String
    static let deepseek = [
        RemoteModelChoice(id:"deepseek-flash",title:"DeepSeek · Flash",detail:"Faster and cheaper · everyday chat and tasks"),
        RemoteModelChoice(id:"deepseek-v4-pro",title:"DeepSeek · V4 Pro",detail:"More capable · longer reasoning and harder tasks")]
}

/// Keychain, never UserDefaults: the key must not sit in a readable plist and
/// must never be written into source, the repository or a distributed bundle.
enum ModelCredentials {
    static let service = "com.chillor.mac.deepseek"
    private static let account = "api-key"
    private static func query(_ extra:[CFString:Any] = [:])->[CFString:Any] {
        var base:[CFString:Any] = [kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecAttrAccount:account]
        for (key,value) in extra {base[key] = value}
        return base
    }
    static func read()->String? {
        var item:CFTypeRef?
        guard SecItemCopyMatching(query([kSecReturnData:true,kSecMatchLimit:kSecMatchLimitOne]) as CFDictionary,&item) == errSecSuccess,
              let data = item as? Data,let value = String(data:data,encoding:.utf8),!value.isEmpty else {return nil}
        return value
    }
    /// Presence only; the secret itself is never cached outside the keychain.
    nonisolated(unsafe) private static var presence:Bool?
    static func hasKey()->Bool {
        if let presence {return presence}
        let value = read() != nil
        presence = value
        return value
    }
    static func invalidate() {presence = nil}
    @discardableResult static func write(_ value:String)->Bool {
        defer {invalidate()}
        let trimmed = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty else {return remove()}
        let attributes:[CFString:Any] = [kSecValueData:Data(trimmed.utf8),
                                         kSecAttrAccessible:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemCopyMatching(query([kSecMatchLimit:kSecMatchLimitOne]) as CFDictionary,nil) == errSecSuccess {
            return SecItemUpdate(query() as CFDictionary,attributes as CFDictionary) == errSecSuccess
        }
        return SecItemAdd(query(attributes) as CFDictionary,nil) == errSecSuccess
    }
    @discardableResult static func remove()->Bool {
        defer {invalidate()}
        let status = SecItemDelete(query() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    /// Shown in settings instead of the secret itself.
    static func masked()->String? {
        guard let value = read() else {return nil}
        return value.count <= 10 ? String(repeating:"•",count:value.count)
            : value.prefix(6)+String(repeating:"•",count:6)+value.suffix(4)
    }
}

enum ModelRouting {
    static let defaultsKey = "modelProvider"
    static let remoteModelKey = "remoteModelName"
    static var provider:ModelProvider {
        guard let raw = UserDefaults.standard.string(forKey:defaultsKey),
              let value = ModelProvider(rawValue:raw) else {return .local}
        // A configured provider without a usable credential must not silently
        // fail every request; fall back to the local engine and say so in settings.
        if value == .deepseek,!ModelCredentials.hasKey() {return .local}
        return value
    }
    /// The provider exactly as the user selected it, ignoring credential state.
    static var selectedProvider:ModelProvider {
        guard let raw = UserDefaults.standard.string(forKey:defaultsKey),
              let value = ModelProvider(rawValue:raw) else {return .local}
        return value
    }
    static var remoteModelName:String {
        let saved = UserDefaults.standard.string(forKey:remoteModelKey) ?? ""
        return RemoteModelChoice.deepseek.contains(where:{$0.id == saved}) ? saved:RemoteModelChoice.deepseek[0].id
    }
    static func select(provider:ModelProvider,remoteModel:String? = nil) {
        UserDefaults.standard.set(provider.rawValue,forKey:defaultsKey)
        if let remoteModel,RemoteModelChoice.deepseek.contains(where:{$0.id == remoteModel}) {
            UserDefaults.standard.set(remoteModel,forKey:remoteModelKey)
        }
    }
    static var endpoint:URL {URL(string:"https://api.deepseek.com")!}
    static var usesCloud:Bool {provider != .local}
    /// Name shown in settings and used by every request for the active provider.
    static var activeModelName:String {provider == .local ? LocalModel.modelName:remoteModelName}
    static var providerLabel:String {provider == .local ? "On this Mac":"DeepSeek API"}
}
