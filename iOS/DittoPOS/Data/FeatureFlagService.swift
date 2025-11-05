///
//  FeatureFlagService.swift
//  DittoPOS
/*
App Launch
    ↓
Try LaunchDarkly (5s timeout)
    ↓
    ├─ SUCCESS: 
    │   ├─ Use LaunchDarkly for flag values
    │   ├─ Check if Ditto is empty (first run)
    │   └─ If yes: Seed Ditto with current LD values ← SEED HERE
    │
    └─ FAILED/Timeout:
        ├─ Check if Ditto has values
        ├─ If yes: Use Ditto values (from previous successful LD session)
        └─ If no: Use hardcoded defaults ← NO SEEDING HERE
 DITTO_APP_ID=
 DITTO_PLAYGROUND_TOKEN=
 LAUNCH_DARKLY_MOBILE_KEY=
 
*/



import Combine
import LaunchDarkly
import SwiftUI
import DittoSwift

// MARK: - FeatureFlagKeys
enum FeatureFlagKey: String, CaseIterable {
    case enableCustomMenu = "enable-custom-menu"
    case enableAdvancedKDS = "enable-advanced-kds"
    case enableOrderHistory = "enable-order-history"
    case enableAnalytics = "enable-analytics"
    case enableRefunds = "enable-refunds"
    case showPriceBreakdown = "show-price-breakdown"
    case experimentalUI = "experimental-ui"
}

// MARK: - FeatureFlagService
@MainActor class FeatureFlagService: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    
    @Published private(set) var enabledFeatures: Set<String> = []
    @Published private(set) var isConnected: Bool = false
    
    static var shared = FeatureFlagService()
    private var ditto: Ditto?
    private var client: LDClient?
    private var serveDitto: Bool = false // would be interesting having this set remotely in the event of an outage
    
    private init() {
        Task {
            await initializeLD()
        }
    }
    private var contextBuilder = LDContextBuilder(key: "baseUserContext")

    @MainActor
    private func initializeLD() async {
        guard !Env.LAUNCH_DARKLY_MOBILE_KEY.isEmpty else {
            print("No LD key, trying Ditto...")
            // try await loadFlagsFromDitto(), probably some questions around need at this specific point
            return
        }
        let config = LDConfig(mobileKey: Env.LAUNCH_DARKLY_MOBILE_KEY, autoEnvAttributes: .enabled)
        let context = try? contextBuilder.build().get()

        
        // Try LaunchDarkly
        do {
            try await LDClient.start(config: config, context: context, startWaitSeconds: 3)
            self.client = LDClient.get()
            print("LaunchDarkly connected successfully")
            // do we want to write to ditto here if successful and no flags for this store? vs big peer
        } catch {
            print("LD initialization failed: \(error)")
            print("Falling back to Ditto...")
            serveDitto = true
            
            do {
                print("Using Ditto fallback")
                try await loadFlagsFromDitto()
            } catch {
                print("Ditto fallback failed: \(error)")
                print("Using hardcoded defaults and LaunchDarkly Retry in the Background")
            }
        }
    }

    private func loadFlagsFromDitto() async throws {
        // initalize ditto
        ditto = Ditto(
            identity: DittoIdentity.onlinePlayground(
                appID: "REPLACE_ME_WITH_YOUR_APP_ID",
                token: "REPLACE_ME_WITH_YOUR_PLAYGROUND_TOKEN",
                enableDittoCloudSync: false, // This is required to be set to false to use the correct URLs
                customAuthURL: URL(string: "REPLACE_ME_WITH_YOUR_AUTH_URL")
            )
        )

        guard let ditto = ditto else { return }

        ditto.updateTransportConfig { transportConfig in
            // Set the Ditto Websocket URL
            transportConfig.connect.webSocketURLs.insert("wss://REPLACE_ME_WITH_YOUR_WEBSOCKET_URL")
        }

        // Disable DQL strict mode so that collection definitions are not required in DQL queries
        try await ditto.store.execute(query:"ALTER SYSTEM SET DQL_STRICT_MODE = false")

        do {
            try ditto.startSync()
        } catch {
            print(error.localizedDescription)
        }


        // query flags for store
        print("Loading flags from Ditto...")
        let query = "SELECT * FROM COLLECTION feature_flags"
        let result = try await ditto.store.execute(query: "SELECT * FROM flags") // any concerns around the performance here
        let items = result.items
        print("Loaded \(items.count) flags from Ditto")

        // format to query
        let jsonSerializedItem: String = result.items[0].jsonString()
        let jsonAsData: Data = Data(jsonSerializedItem.utf8)    

        // TODO: transform to flags
    }
    
    // MARK: - Public API
    public func isEnabled(_ flagKey: FeatureFlagKey) -> Bool {
        if serveDitto {
            // Fallback: check Ditto-loaded values
            return enabledFeatures.contains(flagKey.rawValue)
        } else {
            return client?.boolVariation(forKey: flagKey.rawValue, defaultValue: false) ?? false
        }
    }
    
    // func getString(_ flagKey: FeatureFlagKey, defaultValue: String) -> String {
    //     guard let client = client else { return defaultValue }
    //     guard serveDitto else { return }
    //     return client.stringVariation(forKey: flagKey.rawValue, defaultValue: defaultValue)
    // }
    
    // func getInt(_ flagKey: FeatureFlagKey, defaultValue: Int) -> Int {
    //     guard let client = client else { return defaultValue }
    //     guard serveDitto else { return }
    //     return client.intVariation(forKey: flagKey.rawValue, defaultValue: defaultValue)
    // }
    
    // func getDouble(_ flagKey: FeatureFlagKey, defaultValue: Double) -> Double {
    //     guard let client = client else { return defaultValue }
    //     guard serveDitto else { return }
    //     return client.doubleVariation(forKey: flagKey.rawValue, defaultValue: defaultValue)
    // }
    
    // func getJSON(_ flagKey: FeatureFlagKey) -> LDValue? {
    //     guard let client = client else { return nil }
    //     guard serveDitto else { return }
    //     return client.jsonVariation(forKey: flagKey.rawValue, defaultValue: nil)
    // }



    // TODO: Wrap as an identify call    
    // MARK: - Context Management
    func updateContext(locationId: String, deviceType: String = "ios") {
        var contextBuilder = LDContextBuilder(key: "user-key-123abc")
        contextBuilder.trySetValue("name", .string("Sandy"))
        contextBuilder.trySetValue("email", .string("sandy@example.com"))
    }
    
    // MARK: - utils
    func flush() {
        client?.flush()
    }
}

// MARK: - Convenience Extensions
extension FeatureFlagKey {
    var defaultValue: Bool {
        switch self {
        case .enableAnalytics: return true
        case .enableOrderHistory: return false
        case .enableRefunds: return false
        default: return false
        }
    }
}
