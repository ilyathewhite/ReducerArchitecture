import Testing

@Suite
struct StateStoreTests {}

@Suite
struct AppSettingsTests {}

@Suite
struct SwiftUIStoreTests {}

@Suite(.serialized)
struct SessionTraceTests {}

@Suite(.serialized)
struct LifecycleTests {}
