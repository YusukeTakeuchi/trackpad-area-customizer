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
    let debug: Bool

    static let `default` = Config(
        zoneWidthRatio: 0.33,
        zoneHeightRatio: 0.33,
        corner: .topLeft,
        maxTouchAgeMillis: 120,
        debug: false
    )

    static func parse() -> Config {
        var config = Self.default
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

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--zone-width":
                let value = nextValue(for: argument)
                guard let ratio = Double(value), ratio > 0, ratio <= 1 else {
                    failParse("Invalid value for --zone-width: \(value) (expected 0.0 < value <= 1.0)")
                }
                config = Config(
                    zoneWidthRatio: ratio,
                    zoneHeightRatio: config.zoneHeightRatio,
                    corner: config.corner,
                    maxTouchAgeMillis: config.maxTouchAgeMillis,
                    debug: config.debug
                )
            case "--zone-height":
                let value = nextValue(for: argument)
                guard let ratio = Double(value), ratio > 0, ratio <= 1 else {
                    failParse("Invalid value for --zone-height: \(value) (expected 0.0 < value <= 1.0)")
                }
                config = Config(
                    zoneWidthRatio: config.zoneWidthRatio,
                    zoneHeightRatio: ratio,
                    corner: config.corner,
                    maxTouchAgeMillis: config.maxTouchAgeMillis,
                    debug: config.debug
                )
            case "--corner":
                let value = nextValue(for: argument)
                guard let corner = Corner.parse(value) else {
                    failParse("Invalid value for --corner: \(value) (expected top-left|top-right|bottom-left|bottom-right)")
                }
                config = Config(
                    zoneWidthRatio: config.zoneWidthRatio,
                    zoneHeightRatio: config.zoneHeightRatio,
                    corner: corner,
                    maxTouchAgeMillis: config.maxTouchAgeMillis,
                    debug: config.debug
                )
            case "--max-touch-age-ms":
                let value = nextValue(for: argument)
                guard let millis = Double(value), millis > 0 else {
                    failParse("Invalid value for --max-touch-age-ms: \(value) (expected value > 0)")
                }
                config = Config(
                    zoneWidthRatio: config.zoneWidthRatio,
                    zoneHeightRatio: config.zoneHeightRatio,
                    corner: config.corner,
                    maxTouchAgeMillis: millis,
                    debug: config.debug
                )
            case "--debug":
                config = Config(
                    zoneWidthRatio: config.zoneWidthRatio,
                    zoneHeightRatio: config.zoneHeightRatio,
                    corner: config.corner,
                    maxTouchAgeMillis: config.maxTouchAgeMillis,
                    debug: true
                )
            case "--help":
                printUsageAndExit()
            default:
                failParse("Unknown option: \(argument)")
            }
            index += 1
        }

        return config
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
