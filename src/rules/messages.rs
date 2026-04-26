// Messages.app cleanup rules — require Full Disk Access.

use crate::permissions::{Capabilities, Tier};
use crate::tree::FsTree;

use super::probe::probe_paths;
use super::{Category, CleanupItem, CleanupRule, RuleRegistry, Safety};

pub struct MessagesAttachmentsRule {
    caps: Capabilities,
}

impl CleanupRule for MessagesAttachmentsRule {
    fn name(&self) -> &str { "Messages Attachments" }
    fn description(&self) -> &str {
        "iMessage attachments stored under ~/Library/Messages/Attachments. Removing them keeps text but loses media."
    }
    fn impact(&self) -> &str { "Very High — frequently multi-GB" }
    fn category(&self) -> Category { Category::App }
    fn safety(&self) -> Safety { Safety::Risky }

    fn detect(&self, _tree: &FsTree) -> Vec<CleanupItem> {
        if !self.caps.full_disk_access {
            return Vec::new();
        }
        let home = match dirs::home_dir() {
            Some(h) => h,
            None => return Vec::new(),
        };
        probe_paths(
            "Messages Attachments",
            &[home.join("Library/Messages/Attachments")],
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
    registry.register(Box::new(MessagesAttachmentsRule { caps }));
}
