import AppKit
import NeedsYouShared
import ServiceManagement
import SwiftUI

/// The ask recorder's level, for the level meter only (HM-1418).
final class MicLevel: ObservableObject {
    static let shared = MicLevel()
    @Published var level: Float = 0
    @Published var hearingSpeech = false
}

/// The sidebar's level meter: the only view that redraws with the mic level.
struct LiveLevelMeter: View {
    @ObservedObject private var mic = MicLevel.shared
    var body: some View { LevelMeter(level: mic.level, active: mic.hearingSpeech) }
}

struct LevelMeter: View {
    var level: Float
    var active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(active ? Color.accentColor : Color.secondary)
                    .frame(width: max(4, geo.size.width * CGFloat(level)))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 5)
        .accessibilityLabel("Microphone level")
    }
}
