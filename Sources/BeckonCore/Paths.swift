import Darwin

/// The one place the version is written; scripts/build-app.sh copies it into Info.plist.
public let beckonVersion = "0.3.0"

public enum BeckonPaths {
    /// Per-user directory, created 0700 by the app. Never /tmp: other users could reach a socket there.
    public static var directory: String {
        let home = String(cString: getenv("HOME") ?? getpwuid(getuid()).pointee.pw_dir)
        return home + "/Library/Application Support/beckon"
    }

    public static var socket: String { directory + "/beckon.sock" }

    /// Exists while the screen is unlocked. CLAUDE_CLIENT_PRESENCE_FILE points Claude Code at it.
    public static var presenceFile: String { directory + "/present" }
}

/// Events whose hook must wait for the app's reply. Everything else is fire-and-forget.
/// Stop is not here: it waits only when run as `beckon hook Stop --rewake`, which the hooks config pairs with
/// `asyncRewake`. A plain Stop hook is synchronous, and waiting there would hold up the end of every turn.
public let waitingEvents: Set<String> = ["PermissionRequest", "Doctor"]
