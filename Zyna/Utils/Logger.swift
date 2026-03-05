//
//  Logger.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 06.08.2025.
//

import Foundation

enum LogColor: String {
    case `default` = ""
    case red = "\u{001B}[31m"
    case green = "\u{001B}[32m"
    case yellow = "\u{001B}[33m"
    case blue = "\u{001B}[34m"
    case magenta = "\u{001B}[35m"
    case cyan = "\u{001B}[36m"
    case white = "\u{001B}[37m"
    case gray = "\u{001B}[90m"
    
    private static let reset = "\u{001B}[0m"
    
    func wrap(_ text: String) -> String {
        return rawValue + text + LogColor.reset
    }
}

class Logger {
    static var isEnabled = true
    
    static func log(_ message: String, color: LogColor = .default, file: String = #file, line: Int = #line) {
        guard isEnabled else { return }
        
        let filename = URL(fileURLWithPath: file).lastPathComponent
        let logMessage = "[\(filename):\(line)] \(message)"
        
        print(color.wrap(logMessage))
    }
}

func log(_ message: String, color: LogColor = .default, file: String = #file, line: Int = #line) {
    Logger.log(message, color: color, file: file, line: line)
}

// MARK: - Пример использования
//class MessengerExample {
//    func sendMessage() {
//        log("Отправляем сообщение")
//        log("Сообщение отправлено успешно", color: .green)
//        log("Ошибка отправки", color: .red)
//        log("Предупреждение о лимите", color: .yellow)
//        log("Debug информация", color: .gray)
//    }
//    
//    func setupLogging() {
//        // Включить/выключить все логи одной строчкой
//        Logger.isEnabled = true
//        
//        // В релизе выключаем
//        #if !DEBUG
//        Logger.isEnabled = false
//        #endif
//    }
//}
