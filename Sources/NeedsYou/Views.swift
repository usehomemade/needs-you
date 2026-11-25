import AppKit
import NeedsYouShared
import ServiceManagement
import SwiftUI

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
