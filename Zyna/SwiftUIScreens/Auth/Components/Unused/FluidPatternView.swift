//
//  FluidPatternView.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 02.08.2025.
//

import SwiftUI

struct FluidPatternView: View {
    @State private var phase1: Double = 0
    @State private var phase2: Double = 0
    @State private var phase3: Double = 0
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.purple, .pink, .orange, .yellow],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            Canvas { context, size in
                for layer in 0..<3 {
                    let path = Path { path in
                        let points = 50
                        let centerX = size.width / 2
                        let centerY = size.height / 2
                        let baseRadius = 100 + CGFloat(layer * 50)
                        
                        for i in 0...points {
                            let angle = Double(i) * 2 * .pi / Double(points)
                            let phase = layer == 0 ? phase1 : (layer == 1 ? phase2 : phase3)
                            let radius = baseRadius + 30 * sin(angle * 3 + phase) + 20 * cos(angle * 5 + phase * 1.5)
                            
                            let x = centerX + radius * cos(angle)
                            let y = centerY + radius * sin(angle)
                            
                            if i == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        path.closeSubpath()
                    }
                    
                    let opacity = 0.1 - Double(layer) * 0.02
                    context.fill(path, with: .color(Color.white.opacity(opacity)))
                }
            }
            .animation(.linear(duration: 8).repeatForever(autoreverses: false), value: phase1)
            .animation(.linear(duration: 12).repeatForever(autoreverses: false), value: phase2)
            .animation(.linear(duration: 6).repeatForever(autoreverses: false), value: phase3)
            .onAppear {
                phase1 = .pi * 4
                phase2 = .pi * 6
                phase3 = .pi * 2
            }
        }.ignoresSafeArea(.all)
    }
}
