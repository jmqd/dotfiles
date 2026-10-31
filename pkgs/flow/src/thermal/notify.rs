use anyhow::{Context as _, bail};
use std::process::Command;

/// Shows a desktop notification: Notification Center on macOS, `notify-send`
/// elsewhere. Text is passed as arguments, never spliced into a script.
pub fn desktop(title: &str, body: &str) -> anyhow::Result<()> {
    let mut command = if cfg!(target_os = "macos") {
        let mut command = Command::new("osascript");
        command.args([
            "-e",
            "on run argv",
            "-e",
            "display notification (item 2 of argv) with title (item 1 of argv)",
            "-e",
            "end run",
            title,
            body,
        ]);
        command
    } else {
        let mut command = Command::new("notify-send");
        command.args([title, body]);
        command
    };
    let status = command
        .status()
        .with_context(|| format!("running {:?}", command.get_program()))?;
    if !status.success() {
        bail!("{:?} exited with {status}", command.get_program());
    }
    Ok(())
}
