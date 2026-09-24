use alloy_core::{NameMark, indexes};

use crate::{
    ctx::Ctx,
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

pub fn handle(args: Args, ctx: &Ctx) {
    match args.cmd {
        Cmd::Alloc(args) => handle_alloc(args, ctx),
        Cmd::List(args) => handle_list(args, ctx),
        Cmd::Show(args) => handle_show(args, ctx),
    }
}

fn handle_alloc(args: AllocArgs, ctx: &Ctx) {
    log::info!("Starting index allocation");
    log::debug!("Indexes to alloc: {:?}", args.indexes);
    let state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load state")
    {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let mut has_errors = false;
    let mut indexes_to_process = Vec::new();

    if args.indexes.is_empty() {
        for i_res in indexes::find_all(&state) {
            match i_res {
                Ok(index) => indexes_to_process.push(index),
                Err(e) => {
                    ctx.ui.print_error(&err_msg(e.to_string()));
                    has_errors = true;
                }
            }
        }
    } else {
        for i_name in &args.indexes {
            match indexes::find(&state, i_name)
                .map_err(|e| err_msg(e.to_string()))
                .wrap_err_with(|| format!("Index `{}` not found", i_name))
            {
                Ok(index) => indexes_to_process.push(index),
                Err(e) => {
                    ctx.ui.print_error(&e);
                    has_errors = true;
                }
            }
        }
    }

    if has_errors {
        return;
    }

    if indexes_to_process.is_empty() {
        ctx.ui.print_skip("No indexes to allocate.");
        return;
    }

    for index in indexes_to_process {
        log::info!("Allocating index: {}", index.name);
        if index.data.keys.is_none() {
            log::debug!("Index {} has no keys, evaluating...", index.name);
            if let Err(e) = ctx.nix.eval_index_raw(&index.name).wrap_err_with(|| {
                format!("Index {} has Nix evaluation errors", NameMark(index.name))
            }) {
                ctx.ui.print_error(&e);
                continue;
            } else {
                ctx.ui.print_error(&crate::error::err_msg(format!(
                    "Index `{}` failed to evaluate",
                    index.name
                )));
                continue;
            }
        }

        match indexes::alloc(ctx, index, args.force, args.add_to_git)
            .wrap_err_with(|| format!("Failed to allocate index `{}`", index.name))
        {
            Ok(result) => {
                if result.changed {
                    ctx.ui.print_ok(&format!(
                        "Index `{}` saved ({} entries).",
                        index.name, result.size
                    ));
                } else {
                    ctx.ui
                        .print_skip(&format!("No changes in index `{}`.", index.name));
                }
            }
            Err(err) => {
                ctx.ui.print_error(&err);
            }
        }
    }
}

fn handle_list(_args: ListArgs, ctx: &Ctx) {
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

    let mut all_indexes: Vec<_> = indexes::find_all(&state)
        .into_iter()
        .filter_map(|r| match r {
            Ok(idx) => Some(idx),
            Err(e) => {
                ctx.ui.print_error(&err_msg(e.to_string()));
                None
            }
        })
        .collect();

    if all_indexes.is_empty() {
        ctx.ui.print_info("No indexes defined.");
        return;
    }

    all_indexes.sort_by_key(|i| i.name);

    let headers = vec!["Name", "Fact Name", "Min", "Max", "Keys"];
    let mut rows = Vec::new();

    for index in all_indexes {
        if index.data.keys.is_none() {
            rows.push(vec![
                index.name.to_string(),
                index.data.fact_name.clone(),
                "<error>".to_string(),
                "<error>".to_string(),
                "<error>".to_string(),
            ]);
            continue;
        }

        let keys_len = index.data.keys.as_ref().map(|k| k.len()).unwrap_or(0);

        rows.push(vec![
            index.name.to_string(),
            index.data.fact_name.clone(),
            index.data.min_value.to_string(),
            index.data.max_value.to_string(),
            keys_len.to_string(),
        ]);
    }

    ctx.ui.print_table(headers, rows);
}

fn handle_show(args: ShowArgs, ctx: &Ctx) {
    let state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load state")
    {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let index = match indexes::find(&state, &args.name)
        .map_err(|e| err_msg(e.to_string()))
        .wrap_err_with(|| format!("Failed to get index `{}`", args.name))
    {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    if index.data.keys.is_none() {
        if let Err(e) = ctx.nix.eval_index_raw(&index.name) {
            let wrapped = crate::error::WrappedError {
                context: format!("Index `{}` has Nix evaluation errors", index.name),
                source: e,
            };
            ctx.ui.print_error(&wrapped);
            return;
        } else {
            ctx.ui.print_error(&crate::error::WrappedError {
                context: format!(
                    "Index `{}` failed to evaluate, but explicit evaluation succeeded",
                    index.name
                ),
                source: std::io::Error::new(std::io::ErrorKind::Other, "Not evaluated"),
            });
            return;
        }
    }

    let headers = vec!["Property", "Value"];
    let mut rows = Vec::new();

    rows.push(vec!["Name".to_string(), args.name.clone()]);
    rows.push(vec!["Fact Name".to_string(), index.data.fact_name.clone()]);
    rows.push(vec!["Min".to_string(), index.data.min_value.to_string()]);
    rows.push(vec!["Max".to_string(), index.data.max_value.to_string()]);

    let keys_str = if let Some(keys) = &index.data.keys {
        let mut sorted_keys: Vec<_> = keys.iter().collect();
        sorted_keys.sort();
        sorted_keys
            .into_iter()
            .map(|s| s.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    } else {
        "".to_string()
    };

    rows.push(vec!["Keys".to_string(), keys_str]);

    ctx.ui.print_table(headers, rows);
}
