// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import Foundation

/// Checks a Run Script action's shell syntax without running it, so a typo
/// shows up while the script is written rather than as a failed action
/// later.
public enum ScriptSyntax {
    /// `nil` when bash can parse `script`, otherwise bash's own message
    /// ("line 3: syntax error near unexpected token `fi'"). `bash -n` reads
    /// the commands without executing any of them.
    public static func error(in script: String, timeout: TimeInterval = 2) -> String? {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", "-c", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus != 0 else { return nil }
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let lines = output
            .split(separator: "\n")
            .map { line in
                var text = String(line)
                for prefix in ["/bin/bash: -c: ", "bash: -c: "] where text.hasPrefix(prefix) {
                    text.removeFirst(prefix.count)
                }
                return text
            }
            .filter { !$0.isEmpty }
        return lines.first ?? "Syntax error"
    }
}
