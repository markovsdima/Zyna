//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import SwiftUI

struct InterstellarLinesView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let currentTime = timeline.date.timeIntervalSinceReferenceDate
            let currentPhase = currentTime * 0.05 // Скорость анимации
            
            Canvas { context, size in
                let centerY = size.height / 2
                let numStrips = 7
                let stripSpacing = size.width / CGFloat(numStrips)
                
                // Основные полосы
                for i in 0..<numStrips {
                    let stripIndex = CGFloat(i)
                    let normalizedIndex = stripIndex / CGFloat(numStrips)
                    
                    // Вычисление позиции
                    let baseX = stripIndex * stripSpacing + stripSpacing / 2
                    let waveArgument = normalizedIndex * 8 * CGFloat.pi + currentPhase
                    let waveOffset = sin(waveArgument) * 30
                    let stripX = baseX + waveOffset
                    
                    // Вычисление размеров
                    let heightArg1 = normalizedIndex * 6 * .pi
                    let heightArg2 = currentPhase * 0.7
                    let heightVariation = cos(heightArg1 + heightArg2) * 0.3 + 0.7
                    
                    let widthArg1 = normalizedIndex * 4 * .pi
                    let widthArg2 = currentPhase * 0.5
                    let stripWidth = stripSpacing * 0.6 + sin(widthArg1 + widthArg2) * 4
                    
                    let stripHeight = size.height * heightVariation
                    let stripY = centerY - stripHeight / 2
                    
                    // Эффекты освещения
                    let brightnessArg1 = normalizedIndex * 3 * .pi
                    let brightnessArg2 = currentPhase * 1.2
                    let brightnessVariation = sin(brightnessArg1 + brightnessArg2) * 0.5 + 0.5
                    let brightness = 0.3 + 0.7 * brightnessVariation
                    
                    let opacityArg1 = normalizedIndex * 5 * .pi
                    let opacityArg2 = currentPhase * 0.8
                    let opacityVariation = cos(opacityArg1 + opacityArg2) * 0.5 + 0.5
                    let opacity = 0.6 + 0.4 * opacityVariation
                    
                    // Основной прямоугольник
                    let mainRect = CGRect(
                        x: stripX - stripWidth / 2,
                        y: stripY,
                        width: stripWidth,
                        height: stripHeight
                    )
                    
                    // 3D эффекты - левая сторона
                    let leftOffset = stripWidth * 0.3
                    let leftSide = Path { path in
                        path.move(to: CGPoint(x: mainRect.minX, y: mainRect.minY))
                        path.addLine(to: CGPoint(x: mainRect.minX - leftOffset, y: mainRect.minY - leftOffset))
                        path.addLine(to: CGPoint(x: mainRect.minX - leftOffset, y: mainRect.maxY - leftOffset))
                        path.addLine(to: CGPoint(x: mainRect.minX, y: mainRect.maxY))
                        path.closeSubpath()
                    }
                    
                    // 3D эффекты - верхняя сторона
                    let topOffset = stripWidth * 0.3
                    let topSide = Path { path in
                        path.move(to: CGPoint(x: mainRect.minX, y: mainRect.minY))
                        path.addLine(to: CGPoint(x: mainRect.minX - topOffset, y: mainRect.minY - topOffset))
                        path.addLine(to: CGPoint(x: mainRect.maxX - topOffset, y: mainRect.minY - topOffset))
                        path.addLine(to: CGPoint(x: mainRect.maxX, y: mainRect.minY))
                        path.closeSubpath()
                    }
                    
                    // Рисуем 3D элементы
                    let leftOpacity = opacity * brightness * 0.4
                    context.fill(leftSide, with: .color(.white.opacity(leftOpacity)))
                    
                    let topOpacity = opacity * brightness * 0.8
                    context.fill(topSide, with: .color(.white.opacity(topOpacity)))
                    
                    let mainOpacity = opacity * brightness * 0.6
                    context.fill(Path(mainRect), with: .color(.white.opacity(mainOpacity)))
                    
                    // Внутреннее свечение
                    let glowRect = CGRect(
                        x: stripX - stripWidth / 4,
                        y: stripY + stripHeight * 0.1,
                        width: stripWidth / 2,
                        height: stripHeight * 0.8
                    )
                    let glowOpacity = opacity * brightness * 0.9
                    context.fill(Path(glowRect), with: .color(.white.opacity(glowOpacity)))
                }
                
                // Дополнительные тонкие полосы
                let thinStripsCount = 50
                for i in 0..<thinStripsCount {
                    let stripIndex = CGFloat(i)
                    let normalizedIndex = stripIndex / CGFloat(thinStripsCount)
                    let thinSpacing = size.width / CGFloat(thinStripsCount)
                    
                    // Позиция и размер
                    let baseX = stripIndex * thinSpacing + thinSpacing / 2
                    let waveArg = normalizedIndex * 12 * CGFloat.pi + currentPhase * 1.5
                    let waveOffset = cos(waveArg) * 20
                    let stripX = baseX + waveOffset
                    
                    let widthArg = normalizedIndex * 6 * CGFloat.pi + currentPhase
                    let stripWidth = thinSpacing * 0.3 + sin(widthArg) * 1
                    
                    let heightArg1 = normalizedIndex * 8 * CGFloat.pi
                    let heightArg2 = currentPhase * 1.1
                    let heightVariation = sin(heightArg1 + heightArg2) * 0.4 + 0.6
                    let stripHeight = size.height * heightVariation
                    let stripY = centerY - stripHeight / 2
                    
                    // Прозрачность
                    let opacityArg1 = normalizedIndex * 7 * CGFloat.pi
                    let opacityArg2 = currentPhase * 0.9
                    let opacityVariation = sin(opacityArg1 + opacityArg2) * 0.5 + 0.5
                    let opacity = 0.2 + 0.3 * opacityVariation
                    
                    // Рисуем тонкую полосу
                    let thinRect = CGRect(
                        x: stripX - stripWidth / 2,
                        y: stripY,
                        width: stripWidth,
                        height: stripHeight
                    )
                    context.fill(Path(thinRect), with: .color(.white.opacity(opacity)))
                }
            }
        }
        .drawingGroup()
        .edgesIgnoringSafeArea(.all)
        .background(Color.black)
    }
}
