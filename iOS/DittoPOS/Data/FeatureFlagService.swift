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
    
    private init() {
        Task {
            await initializeLD()
        }
    }
    
    // MARK: - Initialization
    private func initializeLD() async {
        guard let mobileKey = Env.LAUNCH_DARKLY_MOBILE_KEY, !mobileKey.isEmpty else {
            print("FeatureFlagService: No LAUNCH_DARKLY_MOBILE_KEY found in Env")
            return
        }
        
        let config = LDConfig(mobileKey: mobileKey)
        // Optionally configure caching, polling intervals, etc.
        config.backgroundFlagPollingInterval = 60.0
        config.online = true
        
        let context = LDContextBuilder(key: UUID().uuidString)
            .kind("device")
            .build()
        
        do {
            self.client = try await LDClient.start(config: config, context: context, startWaitSeconds: 5)
            
            // Observe flag updates
            await observeFlagChanges()
            
            await MainActor.run {
                self.isConnected = true
            }
            
        } catch {
            print("FeatureFlagService: Initialization failed: \(error)")
            print("Falling back to ditto flag data store for this location")
        }
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
        enabledFeatures = Set(FeatureFlagKey.allCases.filter { 
            client.boolVariation(forKey: $0.rawValue, defaultValue: false)
        })
    }
    
    // MARK: - Public API
    func isEnabled(_ flagKey: FeatureFlagKey) -> Bool {
        guard let client = client else { return false }
        return client.boolVariation(forKey: flagKey.rawValue, defaultValue: false)
    }
    
    func getString(_ flagKey: FeatureFlagKey, defaultValue: String) -> String {
        guard let client = client else { return defaultValue }
        return client.stringVariation(forKey: flagKey.rawValue, defaultValue: defaultValue)
    }
    
    func getInt(_ flagKey: FeatureFlagKey, defaultValue: Int) -> Int {
        guard let client = client else { return defaultValue }
        return client.intVariation(forKey: flagKey.rawValue, defaultValue: defaultValue)
    }
    
    func getDouble(_ flagKey: FeatureFlagKey, defaultValue: Double) -> Double {
        guard let client = client else { return defaultValue }
        return client.doubleVariation(forKey: flagKey.rawValue, defaultValue: defaultValue)
    }
    
    func getJSON(_ flagKey: FeatureFlagKey) -> LDValue? {
        guard let client = client else { return nil }
        return client.jsonVariation(forKey: flagKey.rawValue, defaultValue: nil)
    }
    
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