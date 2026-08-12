import Testing

@Suite
struct StateStoreTests {}

@Suite
struct AppSettingsTests {}

@Suite
struct SwiftUIStoreTests {}

#if DEBUG
@Suite(.serialized)
struct SessionTraceTests {}
#endif

@Suite(.serialized)
struct LifecycleTests {}
