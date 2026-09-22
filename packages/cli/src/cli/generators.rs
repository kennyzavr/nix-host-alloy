use std::collections::HashSet;

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
    Run(RunArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(Args, Debug, Clone)]
struct RunArgs {
    #[arg(short = 'f', long = "force", env = "ALLOY_FORCE")]
    force: bool,
    #[arg(short = 'a', long = "add-to-git", env = "ALLOY_ADD_TO_GIT")]
    add_to_git: bool,
    #[arg(short = 't', long = "tag")]
    tags: Vec<String>,
    generators: Vec<String>,
}

#[derive(Args, Debug, Clone)]
struct ListArgs {
    #[arg(short = 't', long = "tag")]
    tags: Vec<String>,
    #[arg(short = 'v', long = "verbose")]
    verbose: bool,
    #[arg(long = "flat")]
    flat: bool,
}

#[derive(Args, Debug, Clone)]
struct ShowArgs {
    generator: String,
}

impl Cli {
    pub(super) fn handle_generators(&self, args: Args) {
        match args.cmd {
            Cmd::Run(args) => self.handle_generators_run(args),
            Cmd::Show(args) => self.handle_generators_show(args),
            Cmd::List(args) => self.handle_generators_list(args),
        }
    }

    fn handle_generators_run(&self, args: RunArgs) {
        let run = || -> miette::Result<()> {
            let loader = &self.state_loader;

            let initial_state = loader.load().wrap_err("Failed to load state")?;
            let targets = lib::generators::collect(&initial_state, &args.generators, &args.tags);
            if targets.is_empty() {
                self.print_info("No generators match the criteria.");
                return Ok(());
            }

            let target_gens: HashSet<&str> = targets.iter().map(String::as_str).collect();
            let mut cache = HashSet::<String>::new();

            let invalid_gens = loop {
                let mut state = loader.load().wrap_err("Failed to load nix configuration")?;

                // for &target_gen in &target_gens {
                //     if !state.generators.contains_key(target_gen) {
                //         miette::bail!("Generator {} not found.", StyledName(&target_gen));
                //     }
                // }

                let exec_plan = lib::generators::build_exec_plan(
                    state.generators.drain().collect(),
                    &target_gens,
                )?;

                let mut invalid = vec![];
                let mut executed = false;
                for (gen_name, gen_state) in exec_plan {
                    if gen_state.bin.is_none() {
                        invalid.push(gen_name);
                        continue;
                    }

                    if cache.contains(&gen_name) {
                        continue;
                    }

                    let (force, add_to_git) = if target_gens.contains(&gen_name.as_str()) {
                        (args.force, args.add_to_git)
                    } else {
                        (false, false)
                    };

                    executed = true;

                    let all_exist = !force
                        && gen_state
                            .facts
                            .iter()
                            .all(|f| lib::facts::exists(&loader.workspace, &state, f))
                        && gen_state
                            .secrets
                            .iter()
                            .all(|s| lib::secrets::master::exists(&loader.workspace, &state, s));

                    if !all_exist {
                        self.print_step(&format!("Generator {}", StyledName(&gen_name)));

                        loader.build_generator(&gen_name).wrap_err_with(|| {
                            format!(
                                "Failed to build generator {} via nix",
                                StyledName(&gen_name)
                            )
                        })?;

                        let depth = std::env::var("ALLOY_DEPTH")
                            .unwrap_or_else(|_| "0".to_string())
                            .parse()
                            .unwrap_or(0);

                        lib::generators::exec(
                            &gen_state,
                            force,
                            add_to_git,
                            &loader.workspace.root(),
                            &loader.module_source,
                            depth,
                        )
                        .wrap_err_with(|| {
                            format!("Failed to execute generator {}", StyledName(&gen_name))
                        })?;
                    } else {
                        self.print_skip(&format!(
                            "Generator {} (up to date)",
                            StyledName(&gen_name)
                        ));
                    }

                    cache.insert(gen_name);
                }

                if !executed {
                    break invalid;
                }
            };

            let mut script_errors = Vec::with_capacity(invalid_gens.len());
            for invalid_gen in invalid_gens {
                if let Err(err) = loader.trigger_generator_evaluation(&invalid_gen) {
                    script_errors.push(format!("  - {}: {}", StyledName(&invalid_gen), err));
                } else {
                    script_errors.push(format!("  - {}", StyledName(&invalid_gen)));
                }
            }

            if !script_errors.is_empty() {
                miette::bail!(
                    "Found {} invalid generators:\n{}",
                    script_errors.len(),
                    script_errors.join("\n")
                );
            }

            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
            std::process::exit(1);
        }
    }

    fn handle_generators_list(&self, args: ListArgs) {
        let run = || -> miette::Result<()> {
            let state = self.state_loader.load().wrap_err("Failed to load state")?;

            let targets = lib::generators::collect(&state, &[], &args.tags);

            let mut table = self.create_table();
            if args.verbose {
                table.set_header(vec![
                    "Generator",
                    "Wants",
                    "Wanted By",
                    "Secrets",
                    "Facts",
                    "Tags",
                ]);
            } else {
                table.set_header(vec!["Generator", "Tags"]);
            }

            let mut targets = targets;
            targets.sort();

            let mut count = 0;
            for name in targets {
                if let Some(gen_state) = state.generators.get(&name) {
                    let tags = gen_state.tags.join(", ");
                    if args.verbose {
                        let wants = gen_state.wants.join(", ");
                        let wanted_by = gen_state.wanted_by.join(", ");

                        let mut secrets_vec: Vec<_> = gen_state.secrets.iter().collect();
                        secrets_vec.sort();
                        let secrets = secrets_vec
                            .into_iter()
                            .map(String::as_str)
                            .collect::<Vec<_>>()
                            .join(", ");

                        let mut facts_vec: Vec<_> = gen_state.facts.iter().collect();
                        facts_vec.sort();
                        let facts = facts_vec
                            .into_iter()
                            .map(String::as_str)
                            .collect::<Vec<_>>()
                            .join(", ");

                        table.add_row(vec![name.clone(), wants, wanted_by, secrets, facts, tags]);
                    } else {
                        table.add_row(vec![name.clone(), tags]);
                    }
                    count += 1;
                }
            }

            if count > 0 {
                self.print_table(table);
            } else {
                self.print_info("No generators found.");
            }

            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
            std::process::exit(1);
        }
    }

    fn handle_generators_show(&self, args: ShowArgs) {
        let run = || -> miette::Result<()> {
            let state = self.state_loader.load().wrap_err("Failed to load state")?;

            if let Some(gen_state) = state.generators.get(&args.generator) {
                let mut table = self.create_table();
                table.set_header(vec!["Property", "Value"]);
                table.add_row(vec!["Name".to_string(), args.generator.clone()]);
                table.add_row(vec!["Tags".to_string(), gen_state.tags.join(", ")]);
                table.add_row(vec!["Wants".to_string(), gen_state.wants.join(", ")]);
                table.add_row(vec![
                    "Wanted By".to_string(),
                    gen_state.wanted_by.join(", "),
                ]);
                table.add_row(vec!["Before".to_string(), gen_state.before.join(", ")]);
                table.add_row(vec!["After".to_string(), gen_state.after.join(", ")]);

                let mut secrets: Vec<_> = gen_state.secrets.iter().collect();
                secrets.sort();
                table.add_row(vec![
                    "Secrets".to_string(),
                    secrets
                        .into_iter()
                        .map(String::as_str)
                        .collect::<Vec<_>>()
                        .join(", "),
                ]);

                let mut facts: Vec<_> = gen_state.facts.iter().collect();
                facts.sort();
                table.add_row(vec![
                    "Facts".to_string(),
                    facts
                        .into_iter()
                        .map(String::as_str)
                        .collect::<Vec<_>>()
                        .join(", "),
                ]);

                if let Some(bin) = &gen_state.bin {
                    table.add_row(vec!["Bin".to_string(), bin.to_string_lossy().to_string()]);
                } else {
                    table.add_row(vec!["Bin".to_string(), "<none>".to_string()]);
                }

                self.print_table(table);
            } else {
                miette::bail!("Generator {} not found", StyledName(&args.generator));
            }

            Ok(())
        };

        if let Err(report) = run() {
            self.print_report(report);
            std::process::exit(1);
        }
    }
}
