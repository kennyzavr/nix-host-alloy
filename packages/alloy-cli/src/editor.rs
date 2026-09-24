use std::io::Write;
use tempfile::NamedTempFile;

#[derive(Debug, thiserror::Error)]
pub enum EditError {
    #[error("Failed to create temp file: {0}")]
    Create(#[source] std::io::Error),

    #[error("Failed to execute editor: {0}")]
    Exec(#[source] std::io::Error),

    #[error("Editor execution failed with status: {0}")]
    ExitStatus(std::process::ExitStatus),

    #[error("Failed to write initial content to temp file: {0}")]
    Write(#[source] std::io::Error),

    #[error("Failed to read new content from temp file: {0}")]
    Read(#[source] std::io::Error),
}

pub fn edit(data: &str) -> Result<Option<String>, EditError> {
    let mut tempfile = NamedTempFile::new().map_err(EditError::Create)?;
    tempfile
        .write_all(data.as_bytes())
        .map_err(EditError::Write)?;

    let editor_env = std::env::var("EDITOR").ok();
    let editor_env = editor_env.as_deref().unwrap_or("nano");

    let mut editor_parts = editor_env.split_whitespace();
    let editor_bin = editor_parts.next().unwrap();

    let mut cmd = std::process::Command::new(editor_bin);
    cmd.args(editor_parts);

    if ["vi", "vim", "nvim", "gvim"]
        .iter()
        .any(|&c| editor_bin.ends_with(c))
    {
        cmd.args(["-n", "-i", "NONE"]);
    } else if editor_bin.ends_with("nano") {
        cmd.arg("-H");
    } else if editor_bin.ends_with("emacs") {
        cmd.args([
            "--eval",
            "(setq make-backup-files nil)",
            "--eval",
            "(setq auto-save-default nil)",
        ]);
    }

    let status = cmd.arg(tempfile.path()).status().map_err(EditError::Exec)?;
    if !status.success() {
        return Err(EditError::ExitStatus(status));
    }

    let mut new_data = std::fs::read_to_string(tempfile.path()).map_err(EditError::Read)?;

    if !data.ends_with('\n') && new_data.ends_with('\n') {
        new_data.pop();
        if new_data.ends_with('\r') {
            new_data.pop();
        }
    }

    if data == new_data {
        return Ok(None);
    }
    Ok(Some(new_data))
}
