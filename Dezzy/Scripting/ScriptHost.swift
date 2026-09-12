import Foundation
import JavaScriptCore

// JavaScriptCore's execution watchdog. Declared in the framework's private
// `JSContextRefPrivate.h` but exported from JavaScriptCore.framework on macOS
// for as long as anyone can remember; verified working on macOS 27. This app
// is never App Store bound, so a private symbol is an acceptable trade for a
// runaway `while (true)` being killed cleanly instead of hanging a thread.
private typealias JSShouldTerminateCallback = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func JSContextGroupSetExecutionTimeLimit(_ group: JSContextGroupRef, _ limit: Double,
                                                  _ callback: JSShouldTerminateCallback?,
                                                  _ context: UnsafeMutableRawPointer?)
@_silgen_name("JSContextGroupClearExecutionTimeLimit")
private func JSContextGroupClearExecutionTimeLimit(_ group: JSContextGroupRef)

/// Runs one script against a `ScriptSession` in a fresh JavaScriptCore
/// context: no filesystem, no network, no DOM — only `dezzy`, `doc`,
/// `console` and what `ScriptPrelude` defines. Synchronous; the caller picks
/// the thread (`ScriptRunner` uses a background queue).
enum ScriptHost {
    struct Failure: Equatable {
        let message: String
        /// 1-based line in the script where the error surfaced, when known.
        let line: Int?
        let column: Int?
        let isTimeout: Bool
    }

    struct Outcome {
        /// The script's `return` value, JSON-decoded (`NSNull` for none).
        var returnValue: Any = NSNull()
        var logs: [String] = []
        var failure: Failure?
        var duration: TimeInterval = 0
    }

    static let scriptSourceURL = URL(string: "script.js")!

    static func run(code: String, session: ScriptSession, timeout: TimeInterval = 20) -> Outcome {
        let started = Date()
        var outcome = Outcome()
        guard let vm = JSVirtualMachine(), let context = JSContext(virtualMachine: vm) else {
            outcome.failure = Failure(message: "Could not create a JavaScript context", line: nil,
                                      column: nil, isTimeout: false)
            return outcome
        }
        var logs: [String] = []
        var pendingException: JSValue?
        context.exceptionHandler = { _, exception in pendingException = exception }

        // The host bridge: one JSON-in, JSON-out call plus a log sink.
        let host = JSValue(newObjectIn: context)!
        let call: @convention(block) (String) -> String = { json in
            let response: [String: Any]
            do {
                guard let data = json.data(using: .utf8),
                      let args = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ScriptError("Malformed operation")
                }
                response = ["value": try session.perform(args)]
            } catch let error as ScriptError {
                response = ["__error": error.message]
            } catch {
                response = ["__error": error.localizedDescription]
            }
            return Self.json(response)
        }
        let log: @convention(block) (String) -> Void = { line in logs.append(line) }
        host.setObject(call, forKeyedSubscript: "call" as NSString)
        host.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(host, forKeyedSubscript: "__dezzyHost" as NSString)

        context.evaluateScript(ScriptPrelude.source, withSourceURL: URL(string: "dezzy-prelude.js"))
        if let exception = pendingException {
            outcome.failure = Failure(message: "Prelude failed: \(exception.toString() ?? "")",
                                      line: nil, column: nil, isTimeout: false)
            return outcome
        }

        if let group = JSContextGetGroup(context.jsGlobalContextRef) {
            let terminate: JSShouldTerminateCallback = { _, _ in true }
            JSContextGroupSetExecutionTimeLimit(group, timeout, terminate, nil)
        }
        defer {
            if let group = JSContextGetGroup(context.jsGlobalContextRef) {
                JSContextGroupClearExecutionTimeLimit(group)
            }
        }

        // The wrapper shares line 1 with the script so reported line numbers
        // are the script's own.
        let wrapped = "__dezzyRun(function(){" + code + "\n})"
        let result = context.evaluateScript(wrapped, withSourceURL: scriptSourceURL)
        outcome.logs = logs
        outcome.duration = Date().timeIntervalSince(started)
        if let exception = pendingException {
            outcome.failure = failure(from: exception, timeout: timeout)
            return outcome
        }
        if let string = result?.toString(), let data = string.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            outcome.returnValue = value
        }
        return outcome
    }

    private static func failure(from exception: JSValue, timeout: TimeInterval) -> Failure {
        let message = exception.forProperty("message")?.toString().flatMap { $0 == "undefined" ? nil : $0 }
            ?? exception.toString() ?? "Unknown error"
        if message.contains("execution terminated") {
            let seconds = Int(timeout.rounded())
            return Failure(message: "Script timed out after \(seconds) s — an infinite loop?",
                           line: nil, column: nil, isTimeout: true)
        }
        let name = exception.forProperty("name")?.toString() ?? ""
        let text = name.isEmpty || name == "undefined" || name == "Error" || message.hasPrefix(name)
            ? message : "\(name): \(message)"
        var line: Int?
        var column: Int?
        // Prefer the first frame inside the script itself: an API error is
        // thrown from the prelude, and its own line would mislead.
        if let stack = exception.forProperty("stack")?.toString() {
            for frame in stack.split(separator: "\n") {
                guard let range = frame.range(of: "script.js:") else { continue }
                let tail = frame[range.upperBound...].split(separator: ":")
                if let l = tail.first.flatMap({ Int($0) }) {
                    line = l
                    column = tail.dropFirst().first.flatMap { Int($0) }
                    break
                }
            }
        }
        if line == nil, let l = exception.forProperty("line")?.toInt32(), l > 0,
           exception.forProperty("sourceURL")?.toString() == scriptSourceURL.absoluteString {
            line = Int(l)
            column = exception.forProperty("column").map { Int($0.toInt32()) }
        }
        return Failure(message: text, line: line, column: column, isTimeout: false)
    }

    static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"__error\":\"Result could not be encoded as JSON\"}"
        }
        return string
    }
}
