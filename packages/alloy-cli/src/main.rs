use clap::Parser;

mod commands;
mod ctx;
mod editor;
mod error;
mod term_ui;

// TODO check age key pair files to existance
fn main() {
    let depth: u32 = std::env::var("ALLOY_DEPTH")
        .unwrap_or_default()
        .parse()
        .unwrap_or(0);

    match commands::Args::try_parse() {
        Ok(args) => commands::handle_args(args),
        Err(err) => {
            let ui = term_ui::TermUi { depth };
            ui.print_clap_err(&err);
            std::process::exit(if err.use_stderr() { 2 } else { 0 });
        }
    }
}
