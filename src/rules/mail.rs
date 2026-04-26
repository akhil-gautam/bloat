// Mail.app cleanup rules — require Full Disk Access.
//
// macOS protects ~/Library/Mail under TCC. Without FDA the read returns
// EPERM and the probe yields zero bytes (not zero results — the path
// just looks empty), so we gate the entire detect() behind a capability
// check before walking it.

use crate::permissions::{Capabilities, Tier};
use crate::tree::FsTree;

use super::probe::{glob_paths, probe_paths};
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};

pub struct MailEnvelopeIndexRule {
    caps: Capabilities,
}
pub struct MailDownloadsRule {
    caps: Capabilities,
}
pub struct MailAttachmentsRule {
    caps: Capabilities,
}

impl CleanupRule for MailEnvelopeIndexRule {
    fn name(&self) -> &str { "Mail Envelope Index" }
    fn description(&self) -> &str {
        "Mail.app envelope index database under ~/Library/Mail/V*/MailData. Mail rebuilds it on next launch."
    }
    fn impact(&self) -> &str { "Medium — index files can grow to hundreds of MB" }
    fn category(&self) -> Category { Category::App }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        if !self.caps.full_disk_access {
            return Vec::new();
        }
        let home = match dirs::home_dir() {
            Some(h) => h,
            None => return Vec::new(),
        };
        let pattern = format!("{}/Library/Mail/V*/MailData/Envelope Index*", home.display());
        let paths = glob_paths(&pattern);
        probe_paths(
            "Mail Envelope Index",
            &paths,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
            false,
            Some(Tier::FullDiskAccess),
        )
        .into_iter()
        .collect()
    }
}

impl CleanupRule for MailDownloadsRule {
    fn name(&self) -> &str { "Mail Downloads" }
    fn description(&self) -> &str {
        "Cached attachment downloads under ~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads."
    }
    fn impact(&self) -> &str { "High — opened attachments accumulate indefinitely" }
    fn category(&self) -> Category { Category::App }
    fn safety(&self) -> Safety { Safety::Safe }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        if !self.caps.full_disk_access {
            return Vec::new();
        }
        let home = match dirs::home_dir() {
            Some(h) => h,
            None => return Vec::new(),
        };
        let p = home.join("Library/Containers/com.apple.mail/Data/Library/Mail Downloads");
        probe_paths(
            "Mail Downloads",
            &[p],
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
            false,
            Some(Tier::FullDiskAccess),
        )
        .into_iter()
        .collect()
    }
}

impl CleanupRule for MailAttachmentsRule {
    fn name(&self) -> &str { "Mail Attachments" }
    fn description(&self) -> &str {
        "On-disk attachments stored inside ~/Library/Mail/V*/Attachments. Re-downloaded from the server on demand."
    }
    fn impact(&self) -> &str { "Very High — heavy users see multi-GB attachment stores" }
    fn category(&self) -> Category { Category::App }
    fn safety(&self) -> Safety { Safety::Caution }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        if !self.caps.full_disk_access {
            return Vec::new();
        }
        let home = match dirs::home_dir() {
            Some(h) => h,
            None => return Vec::new(),
        };
        let pattern = format!("{}/Library/Mail/V*/MailData/Attachments", home.display());
        let mut paths = glob_paths(&pattern);
        // Some Mail versions store under V*/<account>/.../Attachments — also include those.
        let pattern2 = format!("{}/Library/Mail/V*/*/*/*/Attachments", home.display());
        paths.extend(glob_paths(&pattern2));
        probe_paths(
            "Mail Attachments",
            &paths,
            self.description(),
            self.impact(),
            self.category(),
            self.safety(),
            false,
            Some(Tier::FullDiskAccess),
        )
        .into_iter()
        .collect()
    }
}

pub fn register(registry: &mut RuleRegistry, caps: Capabilities) {
    registry.register(Box::new(MailEnvelopeIndexRule { caps }));
    registry.register(Box::new(MailDownloadsRule { caps }));
    registry.register(Box::new(MailAttachmentsRule { caps }));
}
