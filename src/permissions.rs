// Permission tier detection for macOS-gated capabilities.
//
// Each tier corresponds to a TCC / authorization surface that unlocks
// additional cleanup rules and memory actions. Probes are read-only and
// must never trigger a permission prompt themselves — the user grants
// access via System Settings (or by accepting the auth dialog the first
// time they invoke an Admin action).

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Tier {
    User,
    FullDiskAccess,
    Admin,
    Accessibility,
    Automation,
}

impl Tier {
    pub fn label(self) -> &'static str {
        match self {
            Tier::User => "User",
            Tier::FullDiskAccess => "Full Disk Access",
            Tier::Admin => "Administrator",
            Tier::Accessibility => "Accessibility",
            Tier::Automation => "Automation",
        }
    }

    /// Deep link to the relevant System Settings pane.
    pub fn settings_url(self) -> &'static str {
        match self {
            Tier::User => "",
            Tier::FullDiskAccess => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
            }
            Tier::Admin => "",
            Tier::Accessibility => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            }
            Tier::Automation => {
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
            }
        }
    }

    pub fn unlocks(self) -> &'static str {
        match self {
            Tier::User => "current rules — dev caches, browser caches, Trash",
            Tier::FullDiskAccess => {
                "Mail / Messages / Photos / Safari / iOS backups under ~/Library"
            }
            Tier::Admin => {
                "purge memory, /Library/Caches, /private/var/log, APFS local snapshots"
            }
            Tier::Accessibility => "suspend / resume processes scripted via UI",
            Tier::Automation => "tell Mail / Messages / Photos to compact via AppleScript",
        }
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Capabilities {
    pub full_disk_access: bool,
    pub admin: bool,
    pub accessibility: bool,
}

impl Capabilities {
    pub fn has(&self, tier: Tier) -> bool {
        match tier {
            Tier::User => true,
            Tier::FullDiskAccess => self.full_disk_access,
            Tier::Admin => self.admin,
            Tier::Accessibility => self.accessibility,
            // Automation is per-app and only known after the first call.
            Tier::Automation => false,
        }
    }
}

/// Cached admin status — set when an admin action succeeds during the session.
static ADMIN_CACHED: AtomicBool = AtomicBool::new(false);

pub fn mark_admin_granted() {
    ADMIN_CACHED.store(true, Ordering::Relaxed);
}

pub fn admin_is_cached() -> bool {
    ADMIN_CACHED.load(Ordering::Relaxed)
}

/// Probe each tier without triggering any TCC prompt.
pub fn probe_all() -> Capabilities {
    Capabilities {
        full_disk_access: probe_full_disk_access(),
        admin: admin_is_cached(),
        accessibility: probe_accessibility(),
    }
}

/// FDA probe: try a read on a known-protected path. We pick paths that
/// only exist when the user has used Mail/Safari/Messages, and fall back
/// to the system-wide TCC database which is FDA-only.
fn probe_full_disk_access() -> bool {
    if let Some(home) = dirs::home_dir() {
        let candidates: [PathBuf; 4] = [
            home.join("Library/Mail"),
            home.join("Library/Safari/History.db"),
            home.join("Library/Messages/chat.db"),
            home.join("Library/Application Support/MobileSync/Backup"),
        ];
        for p in candidates.iter() {
            if try_read(p) {
                return true;
            }
        }
    }
    // Fall back to the system TCC db — readable only with FDA.
    try_read(&PathBuf::from(
        "/Library/Application Support/com.apple.TCC/TCC.db",
    ))
}

/// Returns true if the path exists and we can open it (any byte read).
fn try_read(path: &PathBuf) -> bool {
    use std::fs::File;
    use std::io::Read;
    if !path.exists() {
        return false;
    }
    if path.is_dir() {
        // For directories, try to enumerate one entry.
        return std::fs::read_dir(path).is_ok();
    }
    match File::open(path) {
        Ok(mut f) => {
            let mut buf = [0u8; 1];
            f.read(&mut buf).is_ok()
        }
        Err(_) => false,
    }
}

/// Accessibility probe via AXIsProcessTrusted.
/// We use the no-prompt variant so launching the app never spams a dialog.
fn probe_accessibility() -> bool {
    use core_foundation::base::TCFType;
    use core_foundation::dictionary::CFDictionary;
    extern "C" {
        fn AXIsProcessTrustedWithOptions(options: *const std::ffi::c_void) -> bool;
    }
    let opts: CFDictionary<core_foundation::string::CFString, core_foundation::boolean::CFBoolean> =
        CFDictionary::from_CFType_pairs(&[]);
    unsafe { AXIsProcessTrustedWithOptions(opts.as_concrete_TypeRef() as *const _) }
}

/// Open the System Settings pane that grants the given tier.
pub fn open_settings_for(tier: Tier) {
    let url = tier.settings_url();
    if url.is_empty() {
        return;
    }
    let _ = std::process::Command::new("open").arg(url).spawn();
}
