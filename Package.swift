// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "imsg",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "IMsgCore", targets: ["IMsgCore"]),
    .executable(name: "imsg", targets: ["imsg"]),
  ],
  dependencies: [
    .package(url: "https://github.com/steipete/Commander.git", from: "0.2.3"),
    .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.16.0"),
    .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit.git", from: "5.0.4"),
  ],
  targets: {
    var targets: [Target] = [
      .target(
        name: "IMsgCore",
        dependencies: [
          .product(name: "SQLite", package: "SQLite.swift"),
          .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
        ],
        linkerSettings: [
          .linkedFramework("ScriptingBridge", .when(platforms: [.macOS])),
          .linkedFramework("Contacts", .when(platforms: [.macOS])),
        ]
      ),
      .executableTarget(
        name: "imsg",
        dependencies: [
          "IMsgCore",
          .product(name: "Commander", package: "Commander"),
        ],
        exclude: [
          "Resources/Info.plist"
        ],
        linkerSettings: [
          .linkedFramework("ImageIO", .when(platforms: [.macOS])),
          .linkedFramework("LinkPresentation", .when(platforms: [.macOS])),
          .linkedFramework("UniformTypeIdentifiers", .when(platforms: [.macOS])),
          .unsafeFlags(
            [
              "-Xlinker", "-sectcreate",
              "-Xlinker", "__TEXT",
              "-Xlinker", "__info_plist",
              "-Xlinker", "Sources/imsg/Resources/Info.plist",
            ],
            .when(platforms: [.macOS])
          ),
        ]
      ),
    ]

    #if os(macOS)
      targets.append(contentsOf: [
        .testTarget(
          name: "IMsgCoreTests",
          dependencies: [
            "IMsgCore"
          ]
        ),
        .testTarget(
          name: "imsgTests",
          dependencies: [
            "imsg",
            "IMsgCore",
          ],
          exclude: [
            "README-live.md"
          ]
        ),
      ])
    #else
      targets.append(
        .testTarget(
          name: "IMsgLinuxTests",
          dependencies: [
            "imsg",
            "IMsgCore",
            .product(name: "SQLite", package: "SQLite.swift"),
          ],
          path: "TestsLinux"
        ))
    #endif

    return targets
  }()
)
