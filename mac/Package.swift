// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors
import PackageDescription

let package = Package(
    name: "pype",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "pype",
            path: "Sources/pype"
        )
    ]
)
