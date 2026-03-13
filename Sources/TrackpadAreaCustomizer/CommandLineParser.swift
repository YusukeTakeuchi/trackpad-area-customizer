import ApplicationServices
import Foundation

struct KeyboardShortcut {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let displayString: String
}

struct ModifiedClickAction {
    let flags: CGEventFlags
    let displayString: String
}

enum TriggerAction {
    case modifiedClick(ModifiedClickAction)
    case keyboardShortcut(KeyboardShortcut)

    var displayString: String {
        switch self {
        case .modifiedClick(let clickAction):
            return clickAction.displayString
        case .keyboardShortcut(let shortcut):
            return "shortcut(\(shortcut.displayString))"
        }
    }
}

struct AreaCondition {
    enum Axis {
        case x
        case y
    }

    struct Bound {
        let value: Double
        let inclusive: Bool
    }

    let axis: Axis
    let lowerBound: Bound?
    let upperBound: Bound?

    func matches(x: Double, y: Double) -> Bool {
        let value = axis == .x ? x : y

        if let lowerBound {
            if lowerBound.inclusive {
                guard value >= lowerBound.value else { return false }
            } else {
                guard value > lowerBound.value else { return false }
            }
        }

        if let upperBound {
            if upperBound.inclusive {
                guard value <= upperBound.value else { return false }
            } else {
                guard value < upperBound.value else { return false }
            }
        }

        return true
    }
}

struct AreaRule {
    let conditions: [AreaCondition]
    let action: TriggerAction
    let description: String

    func matches(x: Double, y: Double) -> Bool {
        conditions.allSatisfy { $0.matches(x: x, y: y) }
    }
}

struct Config {
    let areaRules: [AreaRule]
    let maxTouchAgeMillis: Double
    let debug: Bool

    static let defaultMaxTouchAgeMillis: Double = 120

    static func parse() -> Config {
        var maxTouchAgeMillis = Self.defaultMaxTouchAgeMillis
        var debug = false
        var configPath: String?

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
            case "--config":
                let value = nextValue(for: argument)
                configPath = value
            case "--max-touch-age-ms":
                let value = nextValue(for: argument)
                guard let millis = Double(value), millis > 0 else {
                    failParse("Invalid value for --max-touch-age-ms: \(value) (expected value > 0)")
                }
                maxTouchAgeMillis = millis
            case "--debug":
                debug = true
            case "--help":
                printUsageAndExit()
            default:
                failParse("Unknown option: \(argument)")
            }
            index += 1
        }

        guard let configPath else {
            failParse("--config is required")
        }

        let areaRules: [AreaRule]
        do {
            areaRules = try parseRulesJSON(at: configPath)
        } catch let error as ParseError {
            failParse(error.message)
        } catch {
            failParse("Failed to parse --config: \(configPath)")
        }

        return Config(
            areaRules: areaRules,
            maxTouchAgeMillis: maxTouchAgeMillis,
            debug: debug
        )
    }
}

private struct RulesWrapper: Decodable {
    let rules: [RawRule]
}

private struct RawRule: Decodable {
    let area: [String]
    let shortcut: String
}

private struct PartialCondition {
    let axis: AreaCondition.Axis
    let lowerBound: AreaCondition.Bound?
    let upperBound: AreaCondition.Bound?
}

private enum Comparison {
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual

    init?(token: String) {
        switch token {
        case "<":
            self = .lessThan
        case "<=":
            self = .lessThanOrEqual
        case ">":
            self = .greaterThan
        case ">=":
            self = .greaterThanOrEqual
        default:
            return nil
        }
    }
}

private struct ParseError: Error {
    let message: String
}

private let keyboardKeyCodeMap: [String: CGKeyCode] = [
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

private func parseActionSpec(_ rawValue: String) throws -> TriggerAction {
    let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "cmd-click" || normalized == "command-click" {
        return .modifiedClick(
            ModifiedClickAction(flags: .maskCommand, displayString: "cmd+click")
        )
    }

    let tokens = normalized
        .split(separator: "+")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    if tokens.contains("click") {
        return .modifiedClick(try parseModifiedClickAction(tokens: tokens, rawValue: rawValue))
    }

    return .keyboardShortcut(try parseKeyboardShortcut(rawValue))
}

private func parseModifiedClickAction(tokens: [String], rawValue: String) throws -> ModifiedClickAction {
    guard tokens.last == "click" else {
        throw ParseError(message: "Invalid click action: \(rawValue) (click must be the last token)")
    }

    var flags = CGEventFlags()
    var hasCommand = false
    var hasControl = false
    var hasOption = false
    var hasShift = false

    for token in tokens.dropLast() {
        switch token {
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
            throw ParseError(message: "Invalid click action: \(rawValue) (unknown modifier: \(token))")
        }
    }

    var components: [String] = []
    if hasCommand { components.append("cmd") }
    if hasControl { components.append("ctrl") }
    if hasOption { components.append("opt") }
    if hasShift { components.append("shift") }
    components.append("click")

    return ModifiedClickAction(
        flags: flags,
        displayString: components.joined(separator: "+")
    )
}

private func parseKeyboardShortcut(_ rawValue: String) throws -> KeyboardShortcut {
    let parts = rawValue
        .split(separator: "+")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }

    guard !parts.isEmpty else {
        throw ParseError(message: "Invalid shortcut: \(rawValue)")
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
                throw ParseError(message: "Invalid shortcut: \(rawValue) (multiple key tokens)")
            }
            keyToken = part
        }
    }

    guard let keyToken else {
        throw ParseError(message: "Invalid shortcut: \(rawValue) (missing key token)")
    }
    guard let keyCode = keyboardKeyCodeMap[keyToken] else {
        throw ParseError(message: "Invalid shortcut: \(rawValue) (unknown key: \(keyToken))")
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

private func parseRulesJSON(at path: String) throws -> [AreaRule] {
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw ParseError(message: "Failed to read --config file: \(path)")
    }

    let decoder = JSONDecoder()
    let rawRules: [RawRule]
    if let decodedArray = try? decoder.decode([RawRule].self, from: data) {
        rawRules = decodedArray
    } else {
        do {
            rawRules = try decoder.decode(RulesWrapper.self, from: data).rules
        } catch {
            throw ParseError(message: "Invalid JSON format in --config: \(path)")
        }
    }

    guard !rawRules.isEmpty else {
        throw ParseError(message: "--config must contain at least one rule")
    }

    var parsedRules: [AreaRule] = []
    for (index, rawRule) in rawRules.enumerated() {
        guard !rawRule.area.isEmpty else {
            throw ParseError(message: "Rule #\(index + 1) has empty area conditions")
        }

        var conditions: [AreaCondition] = []
        for expression in rawRule.area {
            do {
                let condition = try parseAreaCondition(expression: expression)
                conditions.append(condition)
            } catch let error as ParseError {
                throw ParseError(message: "Rule #\(index + 1): \(error.message)")
            }
        }

        let action: TriggerAction
        do {
            action = try parseActionSpec(rawRule.shortcut)
        } catch let error as ParseError {
            throw ParseError(message: "Rule #\(index + 1): \(error.message)")
        }

        parsedRules.append(
            AreaRule(
                conditions: conditions,
                action: action,
                description: rawRule.area.joined(separator: " && ")
            )
        )
    }

    return parsedRules
}

private func parseAreaCondition(expression rawExpression: String) throws -> AreaCondition {
    let expression = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !expression.isEmpty else {
        throw ParseError(message: "Area expression is empty")
    }

    let tokens = try tokenizeAreaExpression(expression)

    if tokens.count == 3 {
        let partial = try parseRelation(lhs: tokens[0], op: tokens[1], rhs: tokens[2])
        return try finalizeCondition(
            axis: partial.axis,
            lowerBound: partial.lowerBound,
            upperBound: partial.upperBound,
            expression: expression
        )
    }

    if tokens.count == 5 {
        let left = try parseRelation(lhs: tokens[0], op: tokens[1], rhs: tokens[2])
        let right = try parseRelation(lhs: tokens[2], op: tokens[3], rhs: tokens[4])

        guard left.axis == right.axis else {
            throw ParseError(message: "Invalid area expression '\(expression)' (axis mismatch)")
        }

        let lowerBound = mergeLowerBounds(left.lowerBound, right.lowerBound)
        let upperBound = mergeUpperBounds(left.upperBound, right.upperBound)

        return try finalizeCondition(
            axis: left.axis,
            lowerBound: lowerBound,
            upperBound: upperBound,
            expression: expression
        )
    }

    throw ParseError(message: "Invalid area expression '\(expression)'")
}

private func tokenizeAreaExpression(_ expression: String) throws -> [String] {
    let chars = Array(expression)
    var tokens: [String] = []
    var i = 0

    while i < chars.count {
        let ch = chars[i]

        if ch.isWhitespace {
            i += 1
            continue
        }

        if ch == "x" || ch == "X" || ch == "y" || ch == "Y" {
            tokens.append(String(ch).lowercased())
            i += 1
            continue
        }

        if ch == "<" || ch == ">" {
            if i + 1 < chars.count, chars[i + 1] == "=" {
                tokens.append(String(ch) + "=")
                i += 2
            } else {
                tokens.append(String(ch))
                i += 1
            }
            continue
        }

        if ch.isNumber || ch == "." {
            let start = i
            i += 1
            while i < chars.count, chars[i].isNumber || chars[i] == "." {
                i += 1
            }
            tokens.append(String(chars[start..<i]))
            continue
        }

        throw ParseError(message: "Invalid character '\(ch)' in area expression '\(expression)'")
    }

    return tokens
}

private func parseRelation(lhs: String, op: String, rhs: String) throws -> PartialCondition {
    guard let comparison = Comparison(token: op) else {
        throw ParseError(message: "Invalid operator '\(op)'")
    }

    if let axis = parseAxisToken(lhs), let number = parseCoordinateValue(rhs) {
        switch comparison {
        case .lessThan:
            return PartialCondition(axis: axis, lowerBound: nil, upperBound: .init(value: number, inclusive: false))
        case .lessThanOrEqual:
            return PartialCondition(axis: axis, lowerBound: nil, upperBound: .init(value: number, inclusive: true))
        case .greaterThan:
            return PartialCondition(axis: axis, lowerBound: .init(value: number, inclusive: false), upperBound: nil)
        case .greaterThanOrEqual:
            return PartialCondition(axis: axis, lowerBound: .init(value: number, inclusive: true), upperBound: nil)
        }
    }

    if let number = parseCoordinateValue(lhs), let axis = parseAxisToken(rhs) {
        switch comparison {
        case .lessThan:
            return PartialCondition(axis: axis, lowerBound: .init(value: number, inclusive: false), upperBound: nil)
        case .lessThanOrEqual:
            return PartialCondition(axis: axis, lowerBound: .init(value: number, inclusive: true), upperBound: nil)
        case .greaterThan:
            return PartialCondition(axis: axis, lowerBound: nil, upperBound: .init(value: number, inclusive: false))
        case .greaterThanOrEqual:
            return PartialCondition(axis: axis, lowerBound: nil, upperBound: .init(value: number, inclusive: true))
        }
    }

    throw ParseError(message: "Invalid relation '\(lhs) \(op) \(rhs)'")
}

private func parseAxisToken(_ token: String) -> AreaCondition.Axis? {
    switch token.lowercased() {
    case "x":
        return .x
    case "y":
        return .y
    default:
        return nil
    }
}

private func parseCoordinateValue(_ token: String) -> Double? {
    guard let value = Double(token), value >= 0, value <= 1 else {
        return nil
    }
    return value
}

private func mergeLowerBounds(_ lhs: AreaCondition.Bound?, _ rhs: AreaCondition.Bound?) -> AreaCondition.Bound? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }

    if lhs.value > rhs.value {
        return lhs
    }
    if rhs.value > lhs.value {
        return rhs
    }

    return AreaCondition.Bound(value: lhs.value, inclusive: lhs.inclusive && rhs.inclusive)
}

private func mergeUpperBounds(_ lhs: AreaCondition.Bound?, _ rhs: AreaCondition.Bound?) -> AreaCondition.Bound? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }

    if lhs.value < rhs.value {
        return lhs
    }
    if rhs.value < lhs.value {
        return rhs
    }

    return AreaCondition.Bound(value: lhs.value, inclusive: lhs.inclusive && rhs.inclusive)
}

private func finalizeCondition(
    axis: AreaCondition.Axis,
    lowerBound: AreaCondition.Bound?,
    upperBound: AreaCondition.Bound?,
    expression: String
) throws -> AreaCondition {
    if let lowerBound, let upperBound {
        if lowerBound.value > upperBound.value {
            throw ParseError(message: "Invalid area expression '\(expression)' (empty range)")
        }
        if lowerBound.value == upperBound.value && !(lowerBound.inclusive && upperBound.inclusive) {
            throw ParseError(message: "Invalid area expression '\(expression)' (empty range)")
        }
    }

    return AreaCondition(axis: axis, lowerBound: lowerBound, upperBound: upperBound)
}

private func printUsageAndExit(exitCode: Int32 = 0, toStderr: Bool = false) -> Never {
    let usage = """
    Usage:
      trackpad-area-customizer --config <path> [options]

    Options:
      --config <path>             JSON rules file path (required)
      --max-touch-age-ms <ms>     Max age of touch sample used for click mapping (default: 120)
      --debug                     Print debug log for each click event
      --help                      Show this message

    config format:
      [
        {"area": ["0.3 < x < 0.8"], "shortcut": "f12"},
        {"area": ["0.8 < x", "y < 0.2"], "shortcut": "shift+click"}
      ]
    """
    if toStderr {
        fputs("\(usage)\n", stderr)
    } else {
        print(usage)
    }
    exit(exitCode)
}
