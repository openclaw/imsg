# Injected helper

`IMsgInjected.m` is the only translation unit compiled by the native tests and build scripts. It includes the `.inc` feature files in dependency order. This keeps private IMCore bindings, static state, constructors and destructors local to the dylib without exporting an internal ABI.

The fragments group chat resolution, message construction, payload formats, attachment transfers, command handlers, and IPC ownership. Forward declarations remain where a payload or selector probe needs a later definition. Keep runtime selector checks: the supported macOS versions expose different private APIs.

`make test-helper` compiles the real implementation into isolated native hosts. Swift source-contract tests expand the same include list through `InjectedHelperSource.swift`; they supplement the native tests without replacing them. `make build-dylib` and the release build still compile the single entrypoint.
