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

    /// Speeds measured on this phone by the in-app benchmark. The context planner uses them to bound time-to-first-token; never a guess.
    func measuredSpeed(for modelID: String) -> (prefill: Double?, decode: Double?) {
        let p = d.double(forKey: "prefillTPS.\(modelID)"), q = d.double(forKey: "decodeTPS.\(modelID)")
        return (p > 0 ? p : nil, q > 0 ? q : nil)
    }
    func storeMeasuredSpeed(for modelID: String, prefill: Double?, decode: Double?) {
        if let p = prefill, p > 0 { d.set(p, forKey: "prefillTPS.\(modelID)") }
        if let q = decode, q > 0 { d.set(q, forKey: "decodeTPS.\(modelID)") }
    }

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
