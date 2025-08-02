//
//  ConceptClockView.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 02.08.2025.
//

import SwiftUI

struct ConceptClockView: View {
    @State private var rotationAngle: Double = 0
    
    var body: some View {
        ZStack {
            RadialGradient(
                gradient: Gradient(colors: [
                    .purple.opacity(0.8),
                    .blue.opacity(0.6),
                    .clear
                ]),
                center: .init(x: 1.5, y: 0.5),
                startRadius: 0,
                endRadius: UIScreen.main.bounds.width * 0.8
            )
            .rotationEffect(.degrees(rotationAngle))
            .animation(
                .linear(duration: 30).repeatForever(autoreverses: false),
                value: rotationAngle
            )
            .overlay(
                Canvas { context, size in
                    for i in 1...10 {
                        let radius = size.width * 0.2 * CGFloat(i)
                        let circle = Path(ellipseIn: CGRect(
                            x: size.width * 1.5 - radius/2,
                            y: size.height/2 - radius/2,
                            width: radius,
                            height: radius
                        ))
                        context.stroke(
                            circle,
                            with: .color(.white.opacity(0.05)),
                            lineWidth: 1
                        )
                    }
                }
            )
        }
        .onAppear {
            rotationAngle = 360
        }
    }
}
