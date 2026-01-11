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
    │   └─ If yes: Seed Ditto with current LD values ← SEED HERE - do we want to do this? 
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

    // test flags
    case showDefaultView = "show-default-view"  // Boolean flag - toggles the view
    case defaultViewNumber = "default-view-number"  // String flag - the number 1-5
}

// MARK: - FeatureFlagService
@MainActor class FeatureFlagService: ObservableObject { //ditto serivce passed as an arguement into the FlagService
    private var cancellables = Set<AnyCancellable>()
    
    @Published private(set) var isConnected: Bool = false
    
    static var shared = FeatureFlagService()
    @ObservedObject var dittoService = DittoService.shared
    private var client: LDClient?
    private var dittoServeTestMode: Bool = true // utility to short circut LD init and serve flag from values in Ditto
    private var serveDitto: Bool = false // would be interesting having this set remotely in the event of an outage
    @Published private(set) var flagValues: [String: FeatureFlag.FlagValue] = [:]
    
    private init() {
        Task {
            await initializeLD()
        }
    }
    private var contextBuilder = LDContextBuilder(key: "baseUserContext")

    @MainActor
    private func initializeLD() async {
        if dittoServeTestMode {
            self.serveDitto = true
            await self.loadFlagsFromDitto()
            return
        }
        guard !Env.LAUNCH_DARKLY_MOBILE_KEY.isEmpty else {
            print("No LD key, trying Ditto...")
            self.serveDitto = true
            await self.loadFlagsFromDitto()
            return
        }
        let config = LDConfig(mobileKey: Env.LAUNCH_DARKLY_MOBILE_KEY, autoEnvAttributes: .enabled)
        let context = try? contextBuilder.build().get()

        // updated try LaunchDarkly
        
        LDClient.start(config: config, context: context, startWaitSeconds: 3) { timedOut in
            if timedOut {
                // Client may not have the most recent flags for the configured context
                print("LD initialization failed")
                print("Falling back to Ditto...")
                Task {
                    self.serveDitto = true
                    await self.loadFlagsFromDitto()
                }
            } else {
                // Client has received flags for the configured context
                self.client = LDClient.get()
                print("LaunchDarkly connected successfully")
                Task {
                    try? await self.writeFlagValuesToDitto()
                }
            }
        }
    }
    
    // MARK: - Public API
    public func isEnabled(_ flagKey: FeatureFlagKey) -> Bool {
        if serveDitto {
            // Read from flagValues
            if let flagValue = flagValues[flagKey.rawValue],
            case .bool(let value) = flagValue {
                return value
            }
            return flagKey.defaultValue
        } else {
            return client?.boolVariation(forKey: flagKey.rawValue, defaultValue: false) ?? false
        }
    }

    public func getString(_ flagKey: FeatureFlagKey, defaultValue: String) -> String {
        if serveDitto {
            // Read from flagValues
            if let flagValue = flagValues[flagKey.rawValue],
            case .string(let value) = flagValue {
                return value
            }
            return defaultValue
        } else {
            guard let client = client else { return defaultValue }
            return client.stringVariation(forKey: flagKey.rawValue, defaultValue: defaultValue)
        }
    }



    // Add a constant for default store ID
    private let defaultStoreId = "00000"  // Hardcoded for now

    // MARK: Ditto
    func writeFlagValuesToDitto() async throws {
        let timestamp = DateFormatter.isoDate.string(from: Date())
        let source = "launchdarkly"
        let storeId = defaultStoreId

        guard let client = client else {
            print("LD client not initialized, cannot write flags")
        return
        }
        
        
        // Get all flags from LaunchDarkly
        let ldFlags: [LDFlagKey: LDValue] = client.allFlags ?? [:]
        
        print("📝 Writing \(ldFlags.count) LD flags to Ditto for store: \(storeId)...")
        
        // Convert LDValue to batch format
        var flagBatch: [(key: String, value: Any, valueType: String)] = []
        
        for (key, ldValue) in ldFlags {
            switch ldValue {
            case .bool(let v):
                flagBatch.append((key: key, value: v, valueType: "bool"))
            case .string(let v):
                flagBatch.append((key: key, value: v, valueType: "string"))
            case .number(let v):
                flagBatch.append((key: key, value: v, valueType: "double"))
            case .array, .object, .null:
                // Skip complex types for now, or handle as JSON string
                print("Skipping complex flag type for key: \(key)")
                continue
            }
        }
        
        try await DittoService.shared.saveFeatureFlagBatch(
            flags: flagBatch,
            storeId: storeId,
            source: source
        )
        print("✅ Successfully wrote flags for store: \(storeId)")
    }

    // Fix line 226 - loadFlagsFromDitto
    private func loadFlagsFromDitto() async {
        print("Loading flags from Ditto...")
        
        let storeId = defaultStoreId
        
        do {
            let documents = try await DittoService.shared.getFeatureFlags(forStoreId: storeId)
            
            print("Loaded \(documents.count) flags from Ditto for store: \(storeId)")
            
            var loadedFlags: [String: FeatureFlag.FlagValue] = [:]
            
            for doc in documents {
                switch doc.valueType {
                case "bool":
                    if let value = doc.boolValue {
                        loadedFlags[doc.flagKey] = .bool(value)
                    }
                case "string":
                    if let value = doc.stringValue {
                        loadedFlags[doc.flagKey] = .string(value)
                    }
                case "int":
                    if let value = doc.intValue {
                        loadedFlags[doc.flagKey] = .int(value)
                    }
                case "double":
                    if let value = doc.doubleValue {
                        loadedFlags[doc.flagKey] = .double(value)
                    }
                default:
                    print("Unknown value type: \(doc.valueType) for flag: \(doc.flagKey)")
                }
            }
            
            await MainActor.run {
                self.flagValues = loadedFlags
                print("Successfully loaded \(loadedFlags.count) flags for store: \(storeId)")
            }
            
        } catch {
            print("Failed to load flags from Ditto: \(error)")
        }
    }

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
