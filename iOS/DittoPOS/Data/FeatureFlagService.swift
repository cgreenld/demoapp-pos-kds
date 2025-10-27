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
*/



import Combine
import LaunchDarkly
import SwiftUI

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
    private var client: LDClient?
    private var serveDitto: Bool = false // would be interesting having this set remotely in the event of an outage
    
    private init() {
        Task {
            await initializeLD()
        }
    }

    private func initializeLD() async {
        guard let mobileKey = Env.LAUNCH_DARKLY_MOBILE_KEY, !mobileKey.isEmpty else {
            print("No LD key, trying Ditto...")
            await loadFlagsFromDitto()
            return
        }
        
        // Try LaunchDarkly
        do {
            self.client = try await LDClient.start(config: config, context: context, startWaitSeconds: 3)
            await observeFlagChanges()
            await MainActor.run { self.isConnected = true }
            print("LaunchDarkly connected successfully")
        } catch {
            print("LD initialization failed: \(error)")
            print("Falling back to Ditto...")
            serveDitto = true
            
            do {
                await loadFlagsFromDitto()
                await MainActor.run { self.serveDitto = true }
                print("Using Ditto fallback")
            } catch {
                print("Ditto fallback failed: \(error)")
                print("Using hardcoded defaults and LaunchDarkly Retry in the Background")
            }
        }
    }

    private func loadFlagsFromDitto() async throws {
        print("Loading flags from Ditto...")
        let query = "SELECT * FROM COLLECTION feature_flags"
        let result = try await dittoStore.execute(query: query)
        
        // Process results...
        await MainActor.run {
            self.enabledFeatures = Set(flags.filter { $0.value }.map { $0.key })
        }
        
        print("Loaded \(flags.count) flags from Ditto")
    }
    

    // MARK: - Observation
    private func observeFlagChanges() async {
        guard let client = client else { return }
        
        // Listen for flag changes
        client.onObservable { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateEnabledFeatures()
            }
        }
        
        // Initial update
        await MainActor.run {
            self.updateEnabledFeatures()
        }
    }
    
    private func updateEnabledFeatures() {
        guard let client = client else { return }
        guard serveDitto else { return }
        enabledFeatures = Set(FeatureFlagKey.allCases.filter { 
            client.boolVariation(forKey: $0.rawValue, defaultValue: false)
        })
    }

    // MARK: - Public API
    func isEnabled(_ flagKey: FeatureFlagKey) -> Bool {
        guard let serveDitto else {
            // Fallback: check Ditto-loaded values
            return enabledFeatures.contains(flagKey.rawValue)
        }
        return client.boolVariation(forKey: flagKey.rawValue, defaultValue: false)
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
    
    // MARK: - Context Management
    func updateContext(locationId: String, deviceType: String = "ios") {
        let builder = LDContextBuilder(key: UUID().uuidString)
            .kind("device")
            .setValue("locationId", LDValue.string(locationId))
            .setValue("deviceType", LDValue.string(deviceType))
        
        if let context = builder.build() {
            Task {
                try? await client?.identify(context: context)
            }
        }
    }
    
    // MARK: - Health Check
    func flush() {
        client?.flush()
    }
    
    func setOnline(_ online: Bool) {
        client?.setOnline(online)
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