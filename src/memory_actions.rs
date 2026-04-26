// Memory-management actions invoked from the System tab.
//
// Each action returns a Result so the UI can surface success / failure
// in the status bar and Logs tab. Admin-tier actions wrap their command
// in a single `osascript ... with administrator privileges` call, which
// pops one auth dialog per session (cached after the first acceptance).

use std::process::Command;

use crate::permissions;

#[derive(Debug, Clone)]
pub struct ActionResult {
    pub label: String,
    pub success: bool,
    pub message: String,
}

impl ActionResult {
    fn ok(label: impl Into<String>, message: impl Into<String>) -> Self {
        Self { label: label.into(), success: true, message: message.into() }
    }
    fn err(label: impl Into<String>, message: impl Into<String>) -> Self {
        Self { label: label.into(), success: false, message: message.into() }
    }
}

/// Run a shell command with admin privileges via osascript.
///
/// The whole pipeline goes through one prompt; subsequent calls within
/// the same session reuse the cached credential because we set
/// `with administrator privileges` once and the user's auth lingers in
/// the agent. We mark admin as cached after the first success so the
/// Permissions UI flips to ✅.
pub fn run_admin(shell: &str) -> Result<String, String> {
    let escaped = shell.replace('\\', "\\\\").replace('"', "\\\"");
    let script = format!("do shell script \"{}\" with administrator privileges", escaped);

    let output = Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .output()
        .map_err(|e| format!("osascript failed to launch: {}", e))?;

    if output.status.success() {
        permissions::mark_admin_granted();
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_string())
    }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

/// Free inactive memory by invoking /usr/sbin/purge (requires admin).
pub fn purge_memory() -> ActionResult {
    match run_admin("/usr/sbin/purge") {
        Ok(_) => ActionResult::ok("Purge memory", "Inactive pages reclaimed"),
        Err(e) => ActionResult::err("Purge memory", e),
    }
}

/// Flush the DNS resolver cache (requires admin).
pub fn flush_dns() -> ActionResult {
    match run_admin("/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder") {
        Ok(_) => ActionResult::ok("Flush DNS", "DNS cache flushed"),
        Err(e) => ActionResult::err("Flush DNS", e),
    }
}

/// Suspend a process (SIGSTOP). Works without admin for the user's own
/// processes; otherwise needs admin.
pub fn suspend_process(pid: u32) -> ActionResult {
    let label = format!("Suspend pid {}", pid);
    let status = Command::new("kill").args(["-STOP", &pid.to_string()]).status();
    match status {
        Ok(s) if s.success() => ActionResult::ok(label, "Process suspended (SIGSTOP)"),
        Ok(_) => {
            // Retry under admin.
            match run_admin(&format!("/bin/kill -STOP {}", pid)) {
                Ok(_) => ActionResult::ok(label, "Suspended via admin"),
                Err(e) => ActionResult::err(label, e),
            }
        }
        Err(e) => ActionResult::err(label, e.to_string()),
    }
}

/// Resume a previously-suspended process (SIGCONT).
pub fn resume_process(pid: u32) -> ActionResult {
    let label = format!("Resume pid {}", pid);
    let status = Command::new("kill").args(["-CONT", &pid.to_string()]).status();
    match status {
        Ok(s) if s.success() => ActionResult::ok(label, "Process resumed (SIGCONT)"),
        Ok(_) => match run_admin(&format!("/bin/kill -CONT {}", pid)) {
            Ok(_) => ActionResult::ok(label, "Resumed via admin"),
            Err(e) => ActionResult::err(label, e),
        },
        Err(e) => ActionResult::err(label, e.to_string()),
    }
}

/// Ask an app to quit gracefully via AppleScript (Automation tier).
pub fn quit_app(app_name: &str) -> ActionResult {
    let label = format!("Quit {}", app_name);
    let script = format!("tell application \"{}\" to quit", app_name);
    match Command::new("osascript").arg("-e").arg(&script).status() {
        Ok(s) if s.success() => ActionResult::ok(label, "Quit signal sent"),
        Ok(_) => ActionResult::err(label, "Automation denied or app missing"),
        Err(e) => ActionResult::err(label, e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_result_helpers() {
        let ok = ActionResult::ok("a", "b");
        assert!(ok.success);
        let err = ActionResult::err("a", "b");
        assert!(!err.success);
    }
}
