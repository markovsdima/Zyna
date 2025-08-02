//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

struct RadialPatternView: View {
    @State private var glowIntensity: CGFloat = 0.9
    var body: some View {
        ZStack {
            RadialGradient(
                //colors: [.purple, .blue, .cyan, .clear],
                //colors: [.indigo.opacity(0.8), .purple.opacity(0.6), .black.opacity(0.3), .clear],
                //colors: [.orange.opacity(0.4), .pink.opacity(0.3), .purple.opacity(0.2), .clear],
                colors: [.orange.opacity(0.7), .pink.opacity(0.35), .purple.opacity(0.2), .clear], // Good
                //colors: [.mint.opacity(0.7), .teal.opacity(0.5), .blue.opacity(0.3), .clear],
                //colors: [.red.opacity(0.5), .purple.opacity(0.4), .black.opacity(0.1), .clear],
                //colors: [.yellow.opacity(0.3), .orange.opacity(0.2), .clear],
                center: UnitPoint(x: 1.2, y: 0.5),
                startRadius: 50,
                endRadius: 500
            )
            .opacity(glowIntensity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 4).repeatForever()) {
                        glowIntensity = 1
                    }
                }
        }
    }
}
