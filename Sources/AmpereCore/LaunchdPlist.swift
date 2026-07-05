import Foundation

/// Pure launchd plist XML generator for the daemon's job (SPEC §3: label
/// `com.ampere.daemon`, `RunAtLoad=true`, `KeepAlive=true`,
/// `/Library/LaunchDaemons/com.ampere.daemon.plist`).
///
/// No file I/O here — `ampere-cli install` writes the returned string to the
/// plist path itself, so this stays a plain, fully-testable pure function.
public func launchdPlist(label: String, binaryPath: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>Label</key>
    \t<string>\(xmlEscape(label))</string>
    \t<key>ProgramArguments</key>
    \t<array>
    \t\t<string>\(xmlEscape(binaryPath))</string>
    \t</array>
    \t<key>RunAtLoad</key>
    \t<true/>
    \t<key>KeepAlive</key>
    \t<true/>
    </dict>
    </plist>
    """
}

/// Minimal XML-text escaping for the two string values plist substitutes
/// above. Paths/labels aren't expected to contain markup, but escaping costs
/// nothing and keeps the generator honest.
private func xmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
