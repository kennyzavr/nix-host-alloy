use std::io::Read;

use eyre::{Context, OptionExt, Result, eyre};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use terminal_size::terminal_size;

pub fn exec_sh_script(script: &str) -> Result<()> {
    let mut cmd = CommandBuilder::new("sh");
    cmd.args(["-c", script]);

    let pty_system = native_pty_system();

    let (width, height) = terminal_size().ok_or_eyre("unable to get current terminal size")?;
    let pair = pty_system
        .openpty(PtySize {
            rows: width.0,
            cols: height.0,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|err| eyre!("{err}"))?;

    let mut child = pair.slave.spawn_command(cmd).map_err(|e| eyre!("{e}"))?;
    drop(pair.slave);

    let mut reader = pair.master.try_clone_reader().unwrap();
    let mut log_output = String::new();
    reader
        .read_to_string(&mut log_output)
        .wrap_err("Unable to read nix logs")?;

    let status = child.wait()?;

    if !status.success() {
        eyre::bail!("\n{}", log_output);
    }

    return Ok(());
}
