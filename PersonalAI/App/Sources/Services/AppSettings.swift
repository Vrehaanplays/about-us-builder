import Foundation
import Observation

/// User-controlled behaviour. Everything defaults to the most private choice.
@MainActor @Observable
final class AppSettings {
    private let d = UserDefaults.standard
    var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }
    var chatModelID: String { didSet { d.set(chatModelID, forKey: "chatModelID") } }
    var embedderID: String { didSet { d.set(embedderID, forKey: "embedderID") } }
    /// 0 = automatic (planner decides from memory, thermal state and the question). Otherwise a hard ceiling in tokens.
    var contextCap: Int { didSet { d.set(contextCap, forKey: "contextCap") } }
    var temperature: Double { didSet { d.set(temperature, forKey: "temperature") } }
    var useArchiveInChat: Bool { didSet { d.set(useArchiveInChat, forKey: "useArchiveInChat") } }
    var learnMemoriesAutomatically: Bool { didSet { d.set(learnMemoriesAutomatically, forKey: "learnMemories") } }
    var indexOnlyWhileCharging: Bool { didSet { d.set(indexOnlyWhileCharging, forKey: "indexCharging") } }
    var showRetrievalDetails: Bool { didSet { d.set(showRetrievalDetails, forKey: "showRetrieval") } }
    var allowModelDownloads: Bool { didSet { d.set(allowModelDownloads, forKey: "allowDownloads") } }
    var autoLoadModelOnLaunch: Bool { didSet { d.set(autoLoadModelOnLaunch, forKey: "autoLoad") } }

    init() {
        let d = UserDefaults.standard
        onboarded = d.bool(forKey: "onboarded")
        chatModelID = d.string(forKey: "chatModelID") ?? ""
        embedderID = d.string(forKey: "embedderID") ?? ""
        contextCap = d.integer(forKey: "contextCap")
        temperature = d.object(forKey: "temperature") as? Double ?? 0.6
        useArchiveInChat = d.object(forKey: "useArchiveInChat") as? Bool ?? true
        learnMemoriesAutomatically = d.object(forKey: "learnMemories") as? Bool ?? true
        indexOnlyWhileCharging = d.object(forKey: "indexCharging") as? Bool ?? true
        showRetrievalDetails = d.object(forKey: "showRetrieval") as? Bool ?? true
        allowModelDownloads = d.object(forKey: "allowDownloads") as? Bool ?? true
        autoLoadModelOnLaunch = d.object(forKey: "autoLoad") as? Bool ?? true
    }
}
