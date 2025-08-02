//
//  ParticlePatternView.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 01.08.2025.
//

import SwiftUI

struct ParticleData {
    let x: Double
    let y: Double
    let size: Double
    let speed: Double
}

struct ParticlePatternView: View, Equatable {
    
    static func == (lhs: ParticlePatternView, rhs: ParticlePatternView) -> Bool {
        lhs.uid == rhs.uid
    }
    
    @State private var animationPhase: Double = 0
    
    private let uid = "ParticlePatternView.noRedraw"
    
    private let particles: [ParticleData]
    
    init() {
        particles = Self.getParticles()
    }
    
    var body: some View {
        ZStack {
            Canvas { context, size in
                for particle in particles {
                    let x = particle.x * Double(size.width)
                    let y = particle.y * Double(size.height) + sin(animationPhase * particle.speed + particle.x * 10) * 20
                    let adjustedSize = particle.size + sin(animationPhase * 2 + particle.x * 5) * 2
                    
                    let rect = CGRect(
                        x: x - adjustedSize / 2,
                        y: y - adjustedSize / 2,
                        width: adjustedSize,
                        height: adjustedSize
                    )
                    
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(Color.white.opacity(0.2))
                    )
                }
            }
        }.ignoresSafeArea(.all)
    }
    
    private static func getParticles() -> [ParticleData] {
        (0..<500).map { _ in
            ParticleData(
                x: Double.random(in: 0...1),
                y: Double.random(in: 0...1),
                size: Double.random(in: 0.2...1),
                speed: Double.random(in: 0.1...0.5)
            )
        }
    }
}
