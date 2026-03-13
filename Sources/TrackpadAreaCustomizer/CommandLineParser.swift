import ApplicationServices
import Foundation

enum Corner: String {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"

    var isLeftSide: Bool {
        self == .topLeft || self == .bottomLeft
    }

    var isTopSide: Bool {
        self == .topLeft || self == .topRight
    }

    static func parse(_ rawValue: String) -> Corner? {
        switch rawValue.lowercased() {
        case "top-left", "tl":
            return .topLeft
        case "top-right", "tr":
            return .topRight
        case "bottom-left", "bl":
            return .bottomLeft
        case "bottom-right", "br":
            return .bottomRight
        default:
            return nil
        }
    }
}

struct Config {
    let zoneWidthRatio: Double
    let zoneHeightRatio: Double
    let corner: Corner
    let maxTouchAgeMillis: Double
    let action: TriggerAction
    let debug: Bool

    static let `default` = Config(
        zoneWidthRatio: 0.33,
        zoneHeightRatio: 0.33,
        corner: .topLeft,
        maxTouchAgeMillis: 120,
        action: .commandClick,
        debug: false
    )

    static func parse() -> Config {
        var zoneWidthRatio = Self.default.zoneWidthRatio
        var zoneHeightRatio = Self.default.zoneHeightRatio
        var corner = Self.default.corner
        var maxTouchAgeMillis = Self.default.maxTouchAgeMillis
        var action = Self.default.action
        var debug = Self.default.debug

        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0

        func failParse(_ message: String) -> Never {
            fputs("Error: \(message)\n\n", stderr)
            printUsageAndExit(exitCode: 2, toStderr: true)
        }

        func nextValue(for option: String) -> String {
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                failParse("Missing value for \(option)")
            }
            index = nextIndex
            return arguments[nextIndex]
        }

        let keyCodeMap: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50, "return": 36, "enter": 36,
            "space": 49, "tab": 48, "escape": 53, "esc": 53,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79,
            "f19": 80, "f20": 90
        ]

        func parseShortcut(_ rawValue: String) -> KeyboardShortcut {
            let parts = rawValue
                .split(separator: "+")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            guard !parts.isEmpty else {
                failParse("Invalid value for --shortcut: \(rawValue)")
            }

            var flags = CGEventFlags()
            var hasCommand = false
            var hasControl = false
            var hasOption = false
            var hasShift = false
            var keyToken: String?

            for part in parts {
                switch part {
                case "cmd", "command":
                    flags.insert(.maskCommand)
                    hasCommand = true
                case "ctrl", "control":
                    flags.insert(.maskControl)
                    hasControl = true
                case "opt", "option", "alt":
                    flags.insert(.maskAlternate)
                    hasOption = true
                case "shift":
                    flags.insert(.maskShift)
                    hasShift = true
                default:
                    if keyToken != nil {
                        failParse("Invalid value for --shortcut: \(rawValue) (multiple key tokens)")
                    }
                    keyToken = part
                }
            }

            guard let keyToken else {
                failParse("Invalid value for --shortcut: \(rawValue) (missing key token)")
            }
            guard let keyCode = keyCodeMap[keyToken] else {
                failParse("Invalid value for --shortcut: \(rawValue) (unknown key: \(keyToken))")
            }

            var components: [String] = []
            if hasCommand { components.append("cmd") }
            if hasControl { components.append("ctrl") }
            if hasOption { components.append("opt") }
            if hasShift { components.append("shift") }
            components.append(keyToken)

            return KeyboardShortcut(
                keyCode: keyCode,
                flags: flags,
                displayString: components.joined(separator: "+")
            )
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--zone-width":
                let value = nextValue(for: argument)
                guard let ratio = Double(value), ratio > 0, ratio <= 1 else {
                    failParse("Invalid value for --zone-width: \(value) (expected 0.0 < value <= 1.0)")
                }
                zoneWidthRatio = ratio
            case "--zone-height":
                let value = nextValue(for: argument)
                guard let ratio = Double(value), ratio > 0, ratio <= 1 else {
                    failParse("Invalid value for --zone-height: \(value) (expected 0.0 < value <= 1.0)")
                }
                zoneHeightRatio = ratio
            case "--corner":
                let value = nextValue(for: argument)
                guard let parsedCorner = Corner.parse(value) else {
                    failParse("Invalid value for --corner: \(value) (expected top-left|top-right|bottom-left|bottom-right)")
                }
                corner = parsedCorner
            case "--max-touch-age-ms":
                let value = nextValue(for: argument)
                guard let millis = Double(value), millis > 0 else {
                    failParse("Invalid value for --max-touch-age-ms: \(value) (expected value > 0)")
                }
                maxTouchAgeMillis = millis
            case "--shortcut":
                let value = nextValue(for: argument)
                action = .keyboardShortcut(parseShortcut(value))
            case "--debug":
                debug = true
            case "--help":
                printUsageAndExit()
            default:
                failParse("Unknown option: \(argument)")
            }
            index += 1
        }

        return Config(
            zoneWidthRatio: zoneWidthRatio,
            zoneHeightRatio: zoneHeightRatio,
            corner: corner,
            maxTouchAgeMillis: maxTouchAgeMillis,
            action: action,
            debug: debug
        )
    }
}

struct KeyboardShortcut {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let displayString: String
}

enum TriggerAction {
    case commandClick
    case keyboardShortcut(KeyboardShortcut)

    var displayString: String {
        switch self {
        case .commandClick:
            return "cmd-click"
        case .keyboardShortcut(let shortcut):
            return "shortcut(\(shortcut.displayString))"
        }
    }
}

private func printUsageAndExit(exitCode: Int32 = 0, toStderr: Bool = false) -> Never {
    let usage = """
    Usage:
      trackpad-area-customizer [options]

    Options:
      --zone-width <0.0-1.0>      Horizontal size ratio of the corner zone (default: 0.33)
      --zone-height <0.0-1.0>     Vertical size ratio of the corner zone (default: 0.33)
      --corner <name>             top-left|top-right|bottom-left|bottom-right (default: top-left)
      --max-touch-age-ms <ms>     Max age of touch sample used for click mapping (default: 120)
      --shortcut <combo>          Send shortcut instead of cmd-click (e.g. cmd+c, cmd+shift+v, f18)
      --debug                     Print debug log for each click event
      --help                      Show this message
    """
    if toStderr {
        fputs("\(usage)\n", stderr)
    } else {
        print(usage)
    }
    exit(exitCode)
}
