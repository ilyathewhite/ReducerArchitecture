import Testing

@Suite
struct StateStoreTests {}

@Suite
struct AppSettingsTests {}

@Suite
struct SwiftUIStoreTests {}

@Suite(.serialized)
struct SnapshotTests {}

@Suite(.serialized)
struct LifecycleTests {}
