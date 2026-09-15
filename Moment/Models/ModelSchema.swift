import Foundation
import SwiftData

enum MomentSchema {
    static let models: [any PersistentModel.Type] = MomentSchemaV1.models
}

/// Schema version 1 (App Store 1.0). Future changes add a V2 and a migration stage here —
/// never edit V1 in place once it has shipped.
enum MomentSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = [
        Memory.self, Person.self, Plan.self, Promise.self, GiftIdea.self,
        Event.self, Place.self, Source.self, MemoryRelation.self,
        Insight.self, UserProfile.self, EntityCorrection.self, MomentStory.self
    ]
}

enum MomentMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [MomentSchemaV1.self]
    static let stages: [MigrationStage] = []
}
