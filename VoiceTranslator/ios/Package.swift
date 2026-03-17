// swift-tools-version: 5.9
// This Package.swift enables building and type-checking the VoiceTranslator
// source files without requiring a full .xcodeproj (which needs Xcode on macOS).
//
// To build the actual iOS app, open the project in Xcode and create a
// VoiceTranslator.xcodeproj targeting iOS 17+.
//
// This file is for CI/syntax validation only — it won't produce a runnable app
// because it can't link iOS-only frameworks (AVFoundation, Speech, CoreML, UIKit).

import PackageDescription

let package = Package(
    name: "VoiceTranslator",
    platforms: [.iOS(.v17), .macOS(.v14)],
    targets: [
        .target(
            name: "VoiceTranslator",
            path: "VoiceTranslator"
        )
    ]
)
