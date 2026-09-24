use std::collections::HashSet;

use alloy_core::gens;

use crate::{
    ctx::Ctx,
    error::{WrapErrExt, WrappedError, err_msg},
};

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

pub fn handle(args: Args, ctx: &Ctx) {
    match args.cmd {
        Cmd::Run(args) => handle_run(args, ctx),
        Cmd::List(args) => handle_list(args, ctx),
        Cmd::Show(args) => handle_show(args, ctx),
    }
}

fn handle_run(args: RunArgs, ctx: &Ctx) {
    log::info!("Executing generators");
    let initial_state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load state")
    {
        Ok(s) => s,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let initial_pool = match gens::find_all(&initial_state) {
        Ok(p) => p,
        Err(errs) => {
            for e in errs {
                ctx.ui.print_error(&err_msg(e.to_string()));
            }
            return;
        }
    };

    for requested_gen in &args.generators {
        if initial_pool.get(requested_gen).is_none() {
            ctx.ui
                .print_error(&err_msg(format!("Generator `{}` not found", requested_gen)));
            return;
        }
    }

    let is_target = |name: &str, record: &gens::Entity| -> bool {
        if !args.generators.is_empty() && !args.generators.contains(&name.to_string()) {
            return false;
        }
        if !args.tags.is_empty() && !record.data.tags.iter().any(|t| args.tags.contains(t)) {
            return false;
        }
        true
    };

    let initial_target_names: Vec<&str> = initial_pool
        .iter()
        .filter(|(name, data)| is_target(name, data))
        .map(|(name, _)| name)
        .collect();

    if initial_target_names.is_empty() {
        ctx.ui.print_info("No generators match the criteria.");
        return;
    }

    match gens::plan_exec(initial_pool.clone(), &initial_target_names) {
        Ok(_) => (),
        Err(errs) => {
            for e in errs {
                ctx.ui.print_error(&err_msg(e.to_string()));
            }
            return;
        }
    };

    let target_gens: HashSet<String> = initial_target_names
        .into_iter()
        .map(|s| s.to_string())
        .collect();

    let mut cache = HashSet::<String>::new();

    loop {
        let state = match ctx
            .nix
            .load_state_data(false)
            .wrap_err("Failed to load state")
        {
            Ok(s) => s,
            Err(e) => {
                ctx.ui.print_error(&e);
                return;
            }
        };

        let pool = match gens::find_all(&state) {
            Ok(p) => p,
            Err(errs) => {
                for e in errs {
                    ctx.ui.print_error(&err_msg(e.to_string()));
                }
                return;
            }
        };

        let target_names: Vec<&str> = pool
            .iter()
            .filter(|(name, _)| target_gens.contains(*name))
            .map(|(name, _)| name)
            .collect();

        let exec_plan = match gens::plan_exec(pool.clone(), &target_names) {
            Ok(plan) => plan,
            Err(errs) => {
                for e in errs {
                    ctx.ui.print_error(&err_msg(e.to_string()));
                }
                return;
            }
        };

        let mut executed_in_this_pass = false;
        let mut hit_unevaluated = None;

        for gen_name in exec_plan {
            if cache.contains(gen_name) {
                continue;
            }

            let gen_record = pool.get(gen_name).unwrap();

            if gen_record.data.script_path.is_none() {
                hit_unevaluated = Some(gen_name.to_string());
                break;
            }

            let force = args.force && target_gens.contains(gen_name);
            let add_to_git = args.add_to_git && target_gens.contains(gen_name);

            ctx.ui.print_step(&format!("Generator `{}`", gen_name));

            match gens::exec(ctx, gen_record, force, add_to_git)
                .map_err(|e| err_msg(e.to_string()))
                .wrap_err_with(|| format!("Failed to execute generator `{}`", gen_name))
            {
                Ok(true) => {}
                Ok(false) => {
                    ctx.ui
                        .print_skip(&format!("Generator `{}` (up to date)", gen_name));
                }
                Err(e) => {
                    ctx.ui.print_error(&e);
                    return;
                }
            }

            executed_in_this_pass = true;
            cache.insert(gen_name.to_string());
        }

        if let Some(broken_gen) = hit_unevaluated {
            if executed_in_this_pass {
                *ctx.state_path.lock().unwrap() = None;
                continue;
            } else {
                if let Err(err) = ctx.nix.eval_generator_raw(&broken_gen) {
                    let wrapped = WrappedError {
                        context: format!("Generator `{}` has Nix evaluation errors", broken_gen),
                        source: err,
                    };
                    ctx.ui.print_error(&wrapped);
                } else {
                    let wrapped = WrappedError {
                        context: format!(
                            "Generator `{}` failed to evaluate, but explicit evaluation succeeded (unexpected)",
                            broken_gen
                        ),
                        source: err_msg("Not evaluated"),
                    };
                    ctx.ui.print_error(&wrapped);
                }
                return;
            }
        }

        break;
    }
}

fn handle_list(args: ListArgs, ctx: &Ctx) {
    let state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load state")
    {
        Ok(s) => s,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let pool = match gens::find_all(&state) {
        Ok(p) => p,
        Err(errs) => {
            for e in errs {
                ctx.ui.print_error(&err_msg(e.to_string()));
            }
            return;
        }
    };

    let mut filtered_gens: Vec<_> = pool
        .iter()
        .filter(|(_, gen_entity)| {
            if !args.tags.is_empty() && !gen_entity.data.tags.iter().any(|t| args.tags.contains(t))
            {
                false
            } else {
                true
            }
        })
        .collect();

    if filtered_gens.is_empty() {
        ctx.ui.print_info("No generators found.");
        return;
    }

    filtered_gens.sort_by_key(|(k, _)| *k);

    let headers = if args.verbose {
        vec!["Generator", "Wants", "After", "Secrets", "Facts", "Tags"]
    } else {
        vec!["Generator", "Tags"]
    };

    let mut table_rows = Vec::new();

    for (name, gen_entity) in filtered_gens {
        let tags = gen_entity.data.tags.join(", ");
        if args.verbose {
            let wants = gen_entity.data.wants.join(", ");
            let after = gen_entity.data.after.join(", ");

            let mut secrets_vec: Vec<_> = gen_entity.data.secrets.iter().collect();
            secrets_vec.sort();
            let secrets = secrets_vec
                .into_iter()
                .cloned()
                .collect::<Vec<_>>()
                .join(", ");

            let mut facts_vec: Vec<_> = gen_entity.data.facts.iter().collect();
            facts_vec.sort();
            let facts = facts_vec
                .into_iter()
                .cloned()
                .collect::<Vec<_>>()
                .join(", ");

            table_rows.push(vec![name.to_string(), wants, after, secrets, facts, tags]);
        } else {
            table_rows.push(vec![name.to_string(), tags]);
        }
    }

    if !table_rows.is_empty() {
        ctx.ui.print_table(headers, table_rows);
    } else {
        ctx.ui.print_info("No generators found.");
    }
}

fn handle_show(args: ShowArgs, ctx: &Ctx) {
    let state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load state")
    {
        Ok(s) => s,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let pool = match gens::find_all(&state) {
        Ok(p) => p,
        Err(errs) => {
            for e in errs {
                ctx.ui.print_error(&err_msg(e.to_string()));
            }
            return;
        }
    };

    let gen_entity = match pool.get(&args.generator) {
        Some(g) => g,
        None => {
            ctx.ui.print_error(&err_msg(format!(
                "Generator `{}` not found",
                args.generator
            )));
            return;
        }
    };

    let headers = vec!["Property", "Value"];
    let mut table_rows = Vec::new();
    table_rows.push(vec!["Name".to_string(), args.generator.clone()]);
    table_rows.push(vec!["Tags".to_string(), gen_entity.data.tags.join(", ")]);
    table_rows.push(vec!["Wants".to_string(), gen_entity.data.wants.join(", ")]);
    table_rows.push(vec!["After".to_string(), gen_entity.data.after.join(", ")]);

    let mut secrets: Vec<_> = gen_entity.data.secrets.iter().collect();
    secrets.sort();
    table_rows.push(vec![
        "Secrets".to_string(),
        secrets.into_iter().cloned().collect::<Vec<_>>().join(", "),
    ]);

    let mut facts: Vec<_> = gen_entity.data.facts.iter().collect();
    facts.sort();
    table_rows.push(vec![
        "Facts".to_string(),
        facts.into_iter().cloned().collect::<Vec<_>>().join(", "),
    ]);

    table_rows.push(vec![
        "Evaluated".to_string(),
        gen_entity.data.script_path.is_some().to_string(),
    ]);

    ctx.ui.print_table(headers, table_rows);
}
