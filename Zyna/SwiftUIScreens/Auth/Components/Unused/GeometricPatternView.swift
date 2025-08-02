//
//  GeometricPatternView.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 02.08.2025.
//

import SwiftUI

struct GeometricPatternView: View {
    var body: some View {
        Canvas { context, size in
            
            for i in 0..<20 {
                let x = CGFloat(i) * size.width / 20
                let startY = size.height * 0.3
                let endY = size.height * 0.7 + CGFloat(i).truncatingRemainder(dividingBy: 3) * 50
                
                let path = Path { path in
                    path.move(to: CGPoint(x: x, y: startY))
                    path.addLine(to: CGPoint(x: x + 50, y: endY))
                }
                
                context.stroke(
                    path,
                    with: .color(.white.opacity(0.1)),
                    lineWidth: 1
                )
            }
            
            for i in 0..<10 {
                let y = CGFloat(i) * size.height / 10
                let path = Path { path in
                    path.addArc(
                        center: CGPoint(x: size.width * 1.5, y: y),
                        radius: size.width * 0.8,
                        startAngle: .degrees(10),
                        endAngle: .degrees(50),
                        clockwise: false
                    )
                }
                context.stroke(
                    path,
                    with: .color(.white.opacity(0.08)),
                    lineWidth: 1.5
                )
            }
        }
        .background(
            AngularGradient(
                colors: [.purple, .blue, .purple],
                center: .center,
                angle: .degrees(45)
            )
        )
    }
}
