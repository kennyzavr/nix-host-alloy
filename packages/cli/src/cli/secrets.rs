use std::io::{IsTerminal, Read, Write};

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
    Rekey(RekeyArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(Args, Debug, Clone)]
struct SetArgs {
    #[arg(short = 'f', long = "force")]
    force: bool,
    #[arg(short = 'a', long = "add-to-git")]
    add_to_git: bool,
    secret: String,
}

#[derive(Args, Debug, Clone)]
struct EditArgs {
    #[arg(short = 'a', long = "add-to-git")]
    add_to_git: bool,
    secret: String,
}

#[derive(Args, Debug, Clone)]
struct GetArgs {
    secret: String,
}

#[derive(Args, Debug, Clone)]
struct RekeyArgs {
    secrets: Vec<String>,
    #[arg(long = "host")]
    hosts: Vec<String>,
    #[arg(long = "jail")]
    jails: Vec<String>,
    #[arg(long = "tag")]
    tags: Vec<String>,
    #[arg(short = 'f', long = "force")]
    force: bool,
    #[arg(short = 'a', long = "add-to-git")]
    add_to_git: bool,
}

#[derive(Args, Debug, Clone)]
struct ListArgs {
    #[arg(long = "host")]
    hosts: Vec<String>,
    #[arg(long = "jail")]
    jails: Vec<String>,
    #[arg(long = "tag")]
    tags: Vec<String>,
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
    pub(super) fn handle_secrets(&self, args: Args) {
        match args.cmd {
            Cmd::Get(args) => self.handle_secrets_get(args),
            Cmd::Set(args) => self.handle_secrets_set(args),
            Cmd::Edit(args) => self.handle_secrets_edit(args),
            Cmd::Rekey(args) => self.handle_secrets_rekey(args),
            Cmd::List(args) => self.handle_secrets_list(args),
            Cmd::Show(args) => self.handle_secrets_show(args),
        }
    }

    fn handle_secrets_get(&self, args: GetArgs) {
        let run = || -> miette::Result<()> {
            let state = self.state_loader.load().wrap_err("Failed to load state")?;
            let data =
                lib::secrets::master::read(&self.state_loader.workspace, &state, &args.secret)
                    .wrap_err_with(|| {
                        format!("Failed to read secret {}", StyledName(&args.secret))
                    })?;
            std::io::stdout().write_all(&data).into_diagnostic()?;
            std::io::stdout().flush().into_diagnostic()?;
            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
        }
    }

    fn handle_secrets_set(&self, args: SetArgs) {
        let run = || -> miette::Result<()> {
            let state = self.state_loader.load().wrap_err("Failed to load state")?;

            let stdin = std::io::stdin();
            if stdin.is_terminal() {
                miette::bail!("No data was provided through stdin");
            }

            let mut value = Vec::new();
            stdin.lock().read_to_end(&mut value).into_diagnostic()?;

            let secret = lib::secrets::master::write(
                &self.state_loader.workspace,
                &state,
                &args.secret,
                &value,
                args.force,
                args.add_to_git,
            )
            .wrap_err_with(|| format!("Failed to write secret {}", StyledName(&args.secret)))?;

            self.print_info(&format!(
                "Secret {} encrypted to {}",
                StyledName(&args.secret),
                StyledPath(&secret.file)
            ));

            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
        }
    }

    fn handle_secrets_edit(&self, args: EditArgs) {
        let run = || -> miette::Result<()> {
            let state = self.state_loader.load().wrap_err("Failed to load state")?;

            let current_data =
                lib::secrets::master::read(&self.state_loader.workspace, &state, &args.secret)
                    .wrap_err_with(|| {
                        format!("Failed to read secret {}", StyledName(&args.secret))
                    })?;
            let current_data = String::from_utf8(current_data).into_diagnostic()?;

            let new_value = self.edit(current_data)?;
            let Some(new_value) = new_value else {
                self.print_skip("No changes made, skipping...");
                return Ok(());
            };

            if new_value.is_empty() {
                self.print_skip("The file is empty. Aborting operation.");
                return Ok(());
            }

            lib::secrets::master::write(
                &self.state_loader.workspace,
                &state,
                &args.secret,
                new_value.as_bytes(),
                true,
                args.add_to_git,
            )
            .wrap_err_with(|| format!("Failed to write secret {}", StyledName(&args.secret)))?;

            self.print_ok(&format!(
                "Secret {} was saved successfully",
                StyledName(&args.secret)
            ));

            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
        }
    }

    fn handle_secrets_rekey(&self, args: RekeyArgs) {
        let Ok(state) = self
            .state_loader
            .load()
            .wrap_err("Failed to load state")
            .map_err(|report| self.print_report(report))
        else {
            return;
        };

        let collection =
            lib::secrets::collect(&state, &args.secrets, &args.hosts, &args.jails, &args.tags);

        for (host_name, secret_name) in collection.host_secrets {
            match lib::secrets::host::rekey(
                &self.state_loader.workspace,
                &state,
                host_name,
                secret_name,
                args.force,
                args.add_to_git,
            )
            .wrap_err_with(|| {
                format!(
                    "Failed to rekey secret {} for host {}",
                    StyledName(&secret_name),
                    StyledName(&host_name)
                )
            }) {
                Ok(_) => {
                    self.print_ok(&format!(
                        "Rekeyed host {} secret {}",
                        StyledName(host_name),
                        StyledName(secret_name)
                    ));
                }
                Err(report) => {
                    self.print_report(report);
                }
            }
        }

        for (jail_name, secret_name) in collection.jail_secrets {
            match lib::secrets::jail::rekey(
                &self.state_loader.workspace,
                &state,
                jail_name,
                secret_name,
                args.force,
                args.add_to_git,
            )
            .wrap_err_with(|| {
                format!(
                    "Failed to rekey secret {} for jail {}",
                    StyledName(&secret_name),
                    StyledName(&jail_name)
                )
            }) {
                Ok(_) => {
                    self.print_ok(&format!(
                        "Rekeyed jail {} secret {}",
                        StyledName(jail_name),
                        StyledName(secret_name)
                    ));
                }
                Err(report) => {
                    self.print_report(report);
                }
            }
        }
    }

    fn handle_secrets_list(&self, args: ListArgs) {}

    fn handle_secrets_show(&self, args: ShowArgs) {}
}
