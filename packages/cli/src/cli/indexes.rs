use clap::clap_derive::{Args, Parser, Subcommand};
use miette::Context;

use super::Cli;
use crate::lib::{self, StyledName};

#[derive(Parser, Debug, Clone)]
pub struct Args {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug, Clone)]
enum Cmd {
    Allocate(AllocateArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(Args, Debug, Clone)]
struct AllocateArgs {
    #[arg(
        short = 'f',
        long = "force",
        env = "ALLOY_FORCE",
        help = "Force allocation even if the state is corrupted."
    )]
    force: bool,
    #[arg(
        short = 'a',
        long = "add-to-git",
        env = "ALLOY_ADD_TO_GIT",
        help = "Add the modified fact file to git."
    )]
    add_to_git: bool,
    #[arg(help = "Specific indexes to allocate (default: all)")]
    indexes: Vec<String>,
}

#[derive(Args, Debug, Clone)]
struct ListArgs {}

#[derive(Args, Debug, Clone)]
struct ShowArgs {
    #[arg(help = "Name of the index")]
    name: String,
}

impl Cli {
    pub(super) fn handle_indexes(&self, args: Args) {
        match args.cmd {
            Cmd::Allocate(args) => self.handle_indexes_allocate(args),
            Cmd::List(args) => self.handle_indexes_list(args),
            Cmd::Show(args) => self.handle_indexes_show(args),
        }
    }

    fn handle_indexes_allocate(&self, args: AllocateArgs) {
        let run = || -> miette::Result<()> {
            let state = self.state_loader.load().wrap_err("Failed to load state")?;

            let target_indexes: Vec<String> = if args.indexes.is_empty() {
                state.indexes.keys().cloned().collect()
            } else {
                args.indexes.clone()
            };

            if target_indexes.is_empty() {
                self.print_skip("No indexes to allocate.");
                return Ok(());
            }

            for name in &target_indexes {
                if !state.indexes.contains_key(name) {
                    miette::bail!(
                        "Index '{}' is not defined in the cluster state.",
                        StyledName(name)
                    );
                }
            }

            for name in target_indexes {
                match lib::indexes::allocate(
                    &self.state_loader.workspace,
                    &state,
                    &name,
                    args.force,
                    args.add_to_git,
                ) {
                    Ok(result) => {
                        if result.changed {
                            self.print_ok(&format!(
                                "Index '{}' saved ({} entries).",
                                StyledName(&name),
                                result.size
                            ));
                        } else {
                            self.print_skip(&format!(
                                "No changes in index '{}'.",
                                StyledName(&name)
                            ));
                        }
                    }
                    Err(err) => {
                        self.print_error(err);
                    }
                }
            }

            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
            std::process::exit(1);
        }
    }

    fn handle_indexes_list(&self, _args: ListArgs) {
        let run = || -> miette::Result<()> {
            let state = self.state_loader.load().wrap_err("Failed to load state")?;

            let mut indexes: Vec<_> = state.indexes.iter().collect();
            if indexes.is_empty() {
                self.print_info("No indexes defined.");
                return Ok(());
            }

            indexes.sort_by_key(|(k, _)| *k);

            let mut table = self.create_table();
            table.set_header(vec!["Name", "Fact Name", "Min", "Max", "Keys"]);

            for (name, index) in indexes {
                table.add_row(vec![
                    name,
                    &index.fact_name,
                    &index.min_value.to_string(),
                    &index.max_value.to_string(),
                    &index.keys.len().to_string(),
                ]);
            }

            self.print_table(table);

            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
            std::process::exit(1);
        }
    }

    fn handle_indexes_show(&self, args: ShowArgs) {
        let run = || -> miette::Result<()> {
            let state = self.state_loader.load().wrap_err("Failed to load state")?;

            if let Some(index) = state.indexes.get(&args.name) {
                let mut table = self.create_table();
                table.set_header(vec!["Property", "Value"]);
                table.add_row(vec!["Name", &args.name]);
                table.add_row(vec!["Fact Name", &index.fact_name]);
                table.add_row(vec!["Min", &index.min_value.to_string()]);
                table.add_row(vec!["Max", &index.max_value.to_string()]);

                let mut sorted_keys: Vec<_> = index.keys.iter().collect();
                sorted_keys.sort();
                let keys_str = sorted_keys
                    .into_iter()
                    .map(|s| s.as_str())
                    .collect::<Vec<_>>()
                    .join("\n");

                table.add_row(vec!["Keys", &keys_str]);

                self.print_table(table);
            } else {
                miette::bail!("Index '{}' not found", StyledName(&args.name));
            }

            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
            std::process::exit(1);
        }
    }
}
