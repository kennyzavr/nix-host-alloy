use crate::{
    ctx::AppContext,
    error::{WrapErrExt, err_msg},
};

#[derive(clap::Parser, Debug, Clone)]
pub struct Args {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(clap::Subcommand, Debug, Clone)]
pub enum Cmd {
    Alloc(AllocArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(clap::Args, Debug, Clone)]
pub struct AllocArgs {
    #[arg(
        short = 'f',
        long = "force",
        env = "ALLOY_FORCE",
        help = "Force allocation even if the state is corrupted."
    )]
    pub force: bool,
    #[arg(
        short = 'a',
        long = "add-to-git",
        env = "ALLOY_ADD_TO_GIT",
        help = "Add the modified fact file to git."
    )]
    pub add_to_git: bool,
    #[arg(help = "Specific indexes to allocate (default: all)")]
    pub indexes: Vec<String>,
}

#[derive(clap::Args, Debug, Clone)]
pub struct ListArgs {}

#[derive(clap::Args, Debug, Clone)]
pub struct ShowArgs {
    #[arg(help = "Name of the index")]
    pub name: String,
}

pub fn handle(args: Args, ctx: &AppContext) {
    match args.cmd {
        Cmd::Alloc(args) => handle_alloc(args, ctx),
        Cmd::List(args) => handle_list(args, ctx),
        Cmd::Show(args) => handle_show(args, ctx),
    }
}

fn handle_alloc(args: AllocArgs, ctx: &AppContext) {
    let service = &ctx.indexes_service;

    let records = match service.collect(&args.indexes) {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    if records.is_empty() {
        ctx.ui.print_skip("No indexes to allocate.");
        return;
    }

    for record in records {
        if !record.state.evaluated {
            if let Err(e) = ctx.nix.eval_index_raw(&record.name) {
                let wrapped = crate::error::WrappedError {
                    context: format!("Index `{}` has Nix evaluation errors", record.name),
                    source: e,
                };
                ctx.ui.print_error(&wrapped);
                continue;
            } else {
                ctx.ui.print_error(&crate::error::err_msg(format!(
                    "Index `{}` failed to evaluate",
                    record.name
                )));
                continue;
            }
        }

        match service
            .alloc(&record, args.force, args.add_to_git)
            .wrap_err_with(|| format!("Failed to allocate index `{}`", record.name))
        {
            Ok(result) => {
                if result.changed {
                    ctx.ui.print_ok(&format!(
                        "Index `{}` saved ({} entries).",
                        record.name, result.size
                    ));
                } else {
                    ctx.ui
                        .print_skip(&format!("No changes in index `{}`.", record.name));
                }
            }
            Err(err) => {
                ctx.ui.print_error(&err);
            }
        }
    }
}

fn handle_list(_args: ListArgs, ctx: &AppContext) {
    let state = match ctx.nix.load_state().wrap_err("Failed to load state") {
        Ok(s) => s,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let mut indexes: Vec<_> = state.indexes.iter().collect();
    if indexes.is_empty() {
        ctx.ui.print_info("No indexes defined.");
        return;
    }

    indexes.sort_by_key(|(k, _)| *k);

    let headers = vec!["Name", "Fact Name", "Min", "Max", "Keys"];
    let mut rows = Vec::new();

    for (name, index) in indexes {
        if !index.evaluated {
            rows.push(vec![
                name.clone(),
                index.fact_name.clone(),
                "<error>".to_string(),
                "<error>".to_string(),
                "<error>".to_string(),
            ]);
            continue;
        }

        rows.push(vec![
            name.clone(),
            index.fact_name.clone(),
            index.min_value.to_string(),
            index.max_value.to_string(),
            index.keys.len().to_string(),
        ]);
    }

    ctx.ui.print_table(headers, rows);
}

fn handle_show(args: ShowArgs, ctx: &AppContext) {
    let service = &ctx.indexes_service;

    let record = match service
        .get(args.name.clone())
        .wrap_err_with(|| format!("Failed to get index `{}`", args.name))
    {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    if !record.state.evaluated {
        if let Err(e) = ctx.nix.eval_index_raw(&record.name) {
            let wrapped = crate::error::WrappedError {
                context: format!("Index `{}` has Nix evaluation errors", record.name),
                source: e,
            };
            ctx.ui.print_error(&wrapped);
            return;
        } else {
            ctx.ui.print_error(&crate::error::WrappedError {
                context: format!(
                    "Index `{}` failed to evaluate, but explicit evaluation succeeded",
                    record.name
                ),
                source: std::io::Error::new(std::io::ErrorKind::Other, "Not evaluated"),
            });
            return;
        }
    }

    let headers = vec!["Property", "Value"];
    let mut rows = Vec::new();

    rows.push(vec!["Name".to_string(), args.name.clone()]);
    rows.push(vec![
        "Fact Name".to_string(),
        record.state.fact_name.clone(),
    ]);
    rows.push(vec!["Min".to_string(), record.state.min_value.to_string()]);
    rows.push(vec!["Max".to_string(), record.state.max_value.to_string()]);

    let mut sorted_keys: Vec<_> = record.state.keys.iter().collect();
    sorted_keys.sort();
    let keys_str = sorted_keys
        .into_iter()
        .map(|s| s.as_str())
        .collect::<Vec<_>>()
        .join("\n");

    rows.push(vec!["Keys".to_string(), keys_str]);

    ctx.ui.print_table(headers, rows);
}
