use std::io::IsTerminal;

use clap::clap_derive::{Args, Parser, Subcommand};
use miette::{Context, IntoDiagnostic};

use super::Cli;
use crate::lib::{self, StyledName, StyledPath};

#[derive(Parser, Debug, Clone)]
pub struct Args {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug, Clone)]
enum Cmd {
    Get(GetArgs),
    Set(SetArgs),
    Edit(EditArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(Args, Debug, Clone)]
struct SetArgs {
    #[arg(short = 'f', long = "force")]
    force: bool,
    #[arg(short = 'a', long = "add-to-git")]
    add_to_git: bool,
    fact: String,
}

#[derive(Args, Debug, Clone)]
struct EditArgs {
    #[arg(short = 'a', long = "add-to-git")]
    add_to_git: bool,
    fact: String,
}

#[derive(Args, Debug, Clone)]
struct GetArgs {
    fact: String,
}

#[derive(Args, Debug, Clone)]
struct ListArgs {
    #[arg(short = 'v', long = "verbose")]
    verbose: bool,
    #[arg(long = "flat")]
    flat: bool,
}

#[derive(Args, Debug, Clone)]
struct ShowArgs {
    secret: String,
}

impl Cli {
    pub(super) fn handle_facts(&self, args: Args) {
        match args.cmd {
            Cmd::Get(args) => self.handle_facts_get(args),
            Cmd::Set(args) => self.handle_facts_set(args),
            Cmd::Edit(args) => self.handle_facts_edit(args),
            Cmd::Show(args) => self.handle_facts_show(args),
            Cmd::List(args) => self.handle_facts_list(args),
        }
    }

    fn handle_facts_get(&self, args: GetArgs) {
        let run = || -> miette::Result<()> {
            let state = self.state_loader.load().wrap_err("Failed to load state")?;
            let value = lib::facts::read(&self.state_loader.workspace, &state, &args.fact)
                .wrap_err_with(|| format!("Failed to read fact {}", StyledName(&args.fact)))?;

            println!("{}", value);

            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
        }
    }

    fn handle_facts_set(&self, args: SetArgs) {
        let run = || -> miette::Result<()> {
            let state = self.state_loader.load().wrap_err("Failed to load state")?;

            let stdin = std::io::stdin();
            if stdin.is_terminal() {
                miette::bail!("No data was provided through stdin");
            }

            let data = std::io::read_to_string(&stdin)
                .into_diagnostic()
                .wrap_err("Failed to read stding")?;
            let fact = lib::facts::write(
                &self.state_loader.workspace,
                &state,
                &args.fact,
                data,
                args.force,
                args.add_to_git,
            )
            .wrap_err_with(|| format!("Failed to write fact {}", StyledName(&args.fact)))?;

            self.print_info(&format!(
                "Fact {} written to {}",
                StyledName(&args.fact),
                StyledPath(&fact.file)
            ));

            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
        }
    }

    fn handle_facts_edit(&self, args: EditArgs) {
        let run = || -> miette::Result<()> {
            let state = self.state_loader.load().wrap_err("Failed to load state")?;

            let current_data =
                lib::facts::read(&self.state_loader.workspace, &state, &args.fact)
                    .wrap_err_with(|| format!("Failed to read fact {}", StyledName(&args.fact)))?;

            let new_data = self.edit(current_data)?;
            let Some(new_data) = new_data else {
                self.print_skip("No changes made, skipping...");
                return Ok(());
            };

            lib::facts::write(
                &self.state_loader.workspace,
                &state,
                &args.fact,
                new_data,
                true,
                args.add_to_git,
            )
            .wrap_err_with(|| format!("Failed to write fact {}", StyledName(&args.fact)))?;

            self.print_ok(&format!(
                "Fact {} was saved successfully",
                StyledName(&args.fact)
            ));

            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
        }
    }

    fn handle_facts_list(&self, args: ListArgs) {}

    fn handle_facts_show(&self, args: ShowArgs) {}
}
