//
//  Flag.swift
//  DittoPOS
//
//  Created by Connor Green on 1/8/26.
//  Copyright © 2026 DittoLive Incorporated. All rights reserved.
//

// MARK: - FeatureFlag (Data Model for Ditto Storage)
struct FeatureFlag: Codable {
    let _id: String  // flag key (e.g., "show-default-view")
    let value: FlagValue  // The actual flag value
    let updatedAt: String  // ISO timestamp
    let source: String  // "launchdarkly" or "default"
    
    enum FlagValue: Codable {
        case bool(Bool)
        case string(String)
        case int(Int)
        case double(Double)
        
        // Convenience initializers
        var boolValue: Bool? {
            if case .bool(let val) = self { return val }
            return nil
        }
        
        var stringValue: String? {
            if case .string(let val) = self { return val }
            return nil
        }
        
        var intValue: Int? {
            if case .int(let val) = self { return val }
            return nil
        }
    }
    
    static let collectionName = "feature_flags"
}
