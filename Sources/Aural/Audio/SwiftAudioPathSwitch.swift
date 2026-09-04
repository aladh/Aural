//
//  SwiftAudioPathSwitch.swift
//  Aural
//
//  Whether this launch runs the Stage 1 Swift audio path (#208) or the shipped `proxy_sink` one.
//
//  Debug-only and default off, so `main` stays playable through librespot's own decoder until
//  the live spike on the personal machine passes. Release builds cannot turn it on at all: the
//  switch is not a user setting, it is a spike gate.
//
//  Turning it on:
//    defaults write dev.aural.app AuralSwiftAudioPath -bool YES
//  or, per launch, `Aural -AuralSwiftAudioPath YES` — `NSArgumentDomain` puts a leading-dash
//  argument pair into `UserDefaults.standard`, so one read covers both.
//

import Foundation

nonisolated enum SwiftAudioPathSwitch {
    static let defaultsKey = "AuralSwiftAudioPath"

    /// Whether to register the audio-command callback, which is also what tells the engine to
    /// build a `ShimPlayer` rather than librespot's `Player` (see `create_new_player`).
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
            return defaults.bool(forKey: defaultsKey)
        #else
            return false
        #endif
    }
}
