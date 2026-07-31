import AppKit
import Foundation

/// DeskHealth — native macOS break UI + menu bar manager.
///
/// Usage:
///   DeskHealthOverlay --menubar
///   DeskHealthOverlay --test              # A→B→C then quit
///   DeskHealthOverlay --layer A           # single layer then quit
///   DeskHealthOverlay --layer A --test    # full A→B→C then quit
///   DeskHealthOverlay --payload file.json
///   DeskHealthOverlay --menubar --test    # menu bar + start full sequence

@main
enum DeskHealthOverlayMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let mode: LaunchMode

        do {
            mode = try parseMode(from: args)
        } catch CLIError.help {
            printHelp()
            exit(0)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            printHelp()
            exit(2)
        }

        // Menu bar: only one resident instance. One-shot --layer may run beside it.
        if case .menuBar = mode {
            if !SingleInstance.acquireMenubar() {
                fputs("rise: menu bar already running — exiting duplicate\n", stderr)
                exit(0)
            }
        }

        let app = NSApplication.shared
        let retain = DelegateBox()
        retain.delegate = AppDelegate(mode: mode)
        app.delegate = retain.delegate
        app.run()
        SingleInstance.releaseMenubar()
        exit(0)
    }

    private static func printHelp() {
        let text = """
        DeskHealthOverlay — OLED break overlay + menu bar

        usage:
          DeskHealthOverlay --menubar
          DeskHealthOverlay --test
          DeskHealthOverlay --layer A|B|C
          DeskHealthOverlay --layer A --test
          DeskHealthOverlay --payload /path.json
          DeskHealthOverlay --menubar --test

        --test           walk A → B → C (Next between layers)
        --menubar        stay in menu bar (default if no layer/payload)
        prints: done | snooze | skip
        """
        fputs(text + "\n", stderr)
    }

    private static func parseMode(from args: [String]) throws -> LaunchMode {
        var layer: String?
        var test = false
        var menubar = false
        var payload: String?
        var explicit = false

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--layer", "-l":
                i += 1
                guard i < args.count else { throw CLIError.missingValue(a) }
                layer = args[i].uppercased()
                explicit = true
            case "--test", "-t":
                test = true
                explicit = true
            case "--menubar", "-m":
                menubar = true
            case "--payload", "-p":
                i += 1
                guard i < args.count else { throw CLIError.missingValue(a) }
                payload = args[i]
                explicit = true
            case "--help", "-h":
                throw CLIError.help
            default:
                if a.hasPrefix("-") { throw CLIError.unknown(a) }
            }
            i += 1
        }

        // Payload always one-shot single model
        if let payload {
            let model = try BreakModel.load(from: payload)
            return .oneShot(models: [model])
        }

        // Full test sequence
        if test {
            let sequence = BreakModel.testSequence()
            if menubar || !explicit {
                // --menubar --test, or only --test with menubar default?
                // User: --test alone should show sequence (one-shot is fine for CLI)
                if menubar {
                    return .menuBar(autoSequence: sequence)
                }
                return .oneShot(models: sequence)
            }
            // --layer X --test → full sequence still (click through all 3)
            return .oneShot(models: sequence)
        }

        if let layer {
            guard ["A", "B", "C"].contains(layer) else { throw CLIError.badLayer(layer) }
            let model = BreakModel.builtin(layer: layer, position: .sitting, testMode: false)
            if menubar {
                return .menuBar(autoSequence: [model])
            }
            return .oneShot(models: [model])
        }

        // Default: menu bar only
        return .menuBar(autoSequence: nil)
    }
}

enum CLIError: LocalizedError {
    case missingValue(String)
    case unknown(String)
    case badLayer(String)
    case help

    var errorDescription: String? {
        switch self {
        case .missingValue(let f): return "missing value for \(f)"
        case .unknown(let f): return "unknown flag \(f)"
        case .badLayer(let l): return "layer must be A, B, or C (got \(l))"
        case .help: return "help"
        }
    }
}

private final class DelegateBox {
    var delegate: AppDelegate?
}
