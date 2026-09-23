use std::collections::HashSet;

use crate::{
    ctx::AppContext,
    error::{ErrorCollection, WrapErrExt, WrappedError},
};

#[derive(Debug, thiserror::Error)]
enum InvalidGeneratorError {
    #[error("Generator `{0}` failed to build")]
    BuildFailed(String, #[source] crate::domain::ports::NixError),

    #[error("Generator `{0}` failed to build")]
    NotEvaluated(String),
}

#[derive(clap::Parser, Debug, Clone)]
pub struct Args {
    #[command(subcommand)]
    pub cmd: Cmd,
}

#[derive(clap::Subcommand, Debug, Clone)]
pub enum Cmd {
    Run(RunArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(clap::Args, Debug, Clone)]
pub struct RunArgs {
    #[arg(short = 'f', long = "force", env = "ALLOY_FORCE")]
    pub force: bool,
    #[arg(short = 'a', long = "add-to-git", env = "ALLOY_ADD_TO_GIT")]
    pub add_to_git: bool,
    #[arg(short = 't', long = "tag")]
    pub tags: Vec<String>,
    pub generators: Vec<String>,
}

#[derive(clap::Args, Debug, Clone)]
pub struct ListArgs {
    #[arg(short = 't', long = "tag")]
    pub tags: Vec<String>,
    #[arg(short = 'v', long = "verbose")]
    pub verbose: bool,
    #[arg(long = "flat")]
    pub flat: bool,
}

#[derive(clap::Args, Debug, Clone)]
pub struct ShowArgs {
    pub generator: String,
}

pub fn handle(args: Args, ctx: &AppContext) {
    match args.cmd {
        Cmd::Run(args) => handle_run(args, ctx),
        Cmd::List(args) => handle_list(args, ctx),
        Cmd::Show(args) => handle_show(args, ctx),
    }
}

fn needs_execution(
    ctx: &AppContext,
    state: &crate::domain::models::State,
    record: &crate::domain::models::GeneratorRecord,
) -> bool {
    let facts_exist = record.state.facts.iter().all(|f| {
        if let Some(s) = state.facts.get(f) {
            ctx.fs.exists(&s.file)
        } else {
            false
        }
    });

    let secrets_exist = record.state.secrets.iter().all(|s| {
        if let Some(sec) = state.secrets.get(s) {
            ctx.fs.exists(&sec.file)
        } else {
            false
        }
    });

    !(facts_exist && secrets_exist)
}

fn handle_run(args: RunArgs, ctx: &AppContext) {
    let service = &ctx.generators_service;

    let initial_state = match ctx.nix.load_state().wrap_err("Failed to load state") {
        Ok(s) => s,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let initial_plan = match service.plan(&initial_state, &args.generators, &args.tags) {
        Ok(plan) => plan,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    if initial_plan.is_empty() {
        ctx.ui.print_info("No generators match the criteria.");
        return;
    }

    let is_target = |record: &crate::domain::models::GeneratorRecord| -> bool {
        if !args.generators.is_empty() && !args.generators.contains(&record.name) {
            return false;
        }
        if !args.tags.is_empty() && !record.state.tags.iter().any(|t| args.tags.contains(t)) {
            return false;
        }
        true
    };

    let target_gens: HashSet<String> = initial_plan
        .iter()
        .filter(|r| is_target(r))
        .map(|r| r.name.clone())
        .collect();

    let mut cache = HashSet::<String>::new();

    let invalid_gens = loop {
        let state = match ctx.nix.load_state().wrap_err("Failed to load state") {
            Ok(s) => s,
            Err(e) => {
                ctx.ui.print_error(&e);
                return;
            }
        };

        let exec_plan = match service.plan(&state, &args.generators, &args.tags) {
            Ok(plan) => plan,
            Err(e) => {
                ctx.ui.print_error(&e);
                return;
            }
        };

        let mut invalid = vec![];
        let mut executed = false;

        for gen_record in exec_plan {
            if !gen_record.state.evaluated {
                invalid.push(gen_record.name.to_string());
                continue;
            }

            if cache.contains(&gen_record.name) {
                continue;
            }

            let force = if target_gens.contains(&gen_record.name) {
                args.force
            } else {
                false
            };
            let add_to_git = if target_gens.contains(&gen_record.name) {
                args.add_to_git
            } else {
                false
            };

            let needs_exec = force || needs_execution(ctx, &state, &gen_record);

            if needs_exec {
                ctx.ui
                    .print_step(&format!("Generator `{}`", gen_record.name));

                match service
                    .exec(&gen_record, force, add_to_git)
                    .wrap_err_with(|| format!("Failed to execute generator `{}`", gen_record.name))
                {
                    Ok(_) => (),
                    Err(e) => {
                        ctx.ui.print_error(&e);
                    }
                }
            } else {
                ctx.ui
                    .print_skip(&format!("Generator `{}` (up to date)", gen_record.name));
            }

            cache.insert(gen_record.name.to_string());
            executed = true;
            break;
        }

        if !executed {
            break invalid;
        }

        *ctx.state_file_slot.lock().unwrap() = None;
    };

    let mut script_errors = ErrorCollection::new(Vec::with_capacity(invalid_gens.len()));
    for invalid_gen in invalid_gens {
        if let Err(err) = ctx.nix.build_generator(&invalid_gen) {
            script_errors.push(InvalidGeneratorError::BuildFailed(invalid_gen, err));
        } else {
            script_errors.push(InvalidGeneratorError::NotEvaluated(invalid_gen));
        }
    }

    if !script_errors.is_empty() {
        let count = script_errors.len();
        ctx.ui.print_error(&WrappedError {
            context: format!("Found {} invalid generator(s)", count),
            source: script_errors,
        });
    }
}

fn handle_list(args: ListArgs, ctx: &AppContext) {
    let state = match ctx.nix.load_state().wrap_err("Failed to load state") {
        Ok(s) => s,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let mut generators: Vec<_> = state.generators.into_iter().collect();
    if generators.is_empty() {
        ctx.ui.print_info("No generators defined.");
        return;
    }

    generators.sort_by_key(|(k, _)| k.clone());

    let headers = if args.verbose {
        vec![
            "Generator",
            "Wants",
            "Wanted By",
            "Secrets",
            "Facts",
            "Tags",
        ]
    } else {
        vec!["Generator", "Tags"]
    };

    let mut table_rows = Vec::new();

    for (name, gen_state) in generators {
        if !args.tags.is_empty() && !gen_state.tags.iter().any(|t| args.tags.contains(t)) {
            continue;
        }

        let tags = gen_state.tags.join(", ");
        if args.verbose {
            let wants = gen_state.wants.join(", ");
            let wanted_by = gen_state.wanted_by.join(", ");

            let mut secrets_vec: Vec<_> = gen_state.secrets.iter().collect();
            secrets_vec.sort();
            let secrets = secrets_vec
                .into_iter()
                .cloned()
                .collect::<Vec<_>>()
                .join(", ");

            let mut facts_vec: Vec<_> = gen_state.facts.iter().collect();
            facts_vec.sort();
            let facts = facts_vec
                .into_iter()
                .cloned()
                .collect::<Vec<_>>()
                .join(", ");

            table_rows.push(vec![name.clone(), wants, wanted_by, secrets, facts, tags]);
        } else {
            table_rows.push(vec![name.clone(), tags]);
        }
    }

    if !table_rows.is_empty() {
        ctx.ui.print_table(headers, table_rows);
    } else {
        ctx.ui.print_info("No generators found.");
    }
}

fn handle_show(args: ShowArgs, ctx: &AppContext) {
    let service = &ctx.generators_service;

    let state = match ctx.nix.load_state().wrap_err("Failed to load state") {
        Ok(s) => s,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    match service
        .get(&state, args.generator.clone())
        .wrap_err_with(|| format!("Failed to get generator `{}`", args.generator))
    {
        Ok(gen_record) => {
            let gen_state = gen_record.state;
            let headers = vec!["Property", "Value"];
            let mut table_rows = Vec::new();
            table_rows.push(vec!["Name".to_string(), args.generator.clone()]);
            table_rows.push(vec!["Tags".to_string(), gen_state.tags.join(", ")]);
            table_rows.push(vec!["Wants".to_string(), gen_state.wants.join(", ")]);
            table_rows.push(vec![
                "Wanted By".to_string(),
                gen_state.wanted_by.join(", "),
            ]);
            table_rows.push(vec!["Before".to_string(), gen_state.before.join(", ")]);
            table_rows.push(vec!["After".to_string(), gen_state.after.join(", ")]);

            let mut secrets: Vec<_> = gen_state.secrets.iter().collect();
            secrets.sort();
            table_rows.push(vec![
                "Secrets".to_string(),
                secrets.into_iter().cloned().collect::<Vec<_>>().join(", "),
            ]);

            let mut facts: Vec<_> = gen_state.facts.iter().collect();
            facts.sort();
            table_rows.push(vec![
                "Facts".to_string(),
                facts.into_iter().cloned().collect::<Vec<_>>().join(", "),
            ]);

            table_rows.push(vec![
                "Evaluated".to_string(),
                gen_state.evaluated.to_string(),
            ]);

            ctx.ui.print_table(headers, table_rows);
        }
        Err(e) => {
            ctx.ui.print_error(&e);
        }
    }
}
