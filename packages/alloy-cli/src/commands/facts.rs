use std::io::{IsTerminal, Read};

use alloy_core::facts;

use crate::{
    ctx::Ctx,
    editor::edit,
    error::{WrapErrExt, err_msg},
};

#[derive(clap::Parser, Debug, Clone)]
pub struct Args {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(clap::Subcommand, Debug, Clone)]
pub enum Cmd {
    Read(ReadArgs),
    Write(WriteArgs),
    Edit(EditArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(clap::Args, Debug, Clone)]
pub struct WriteArgs {
    #[arg(short = 'f', long = "force", env = "ALLOY_FORCE")]
    pub force: bool,
    #[arg(short = 'a', long = "add-to-git", env = "ALLOY_ADD_TO_GIT")]
    pub add_to_git: bool,
    pub fact: String,
}

#[derive(clap::Args, Debug, Clone)]
pub struct EditArgs {
    #[arg(short = 'a', long = "add-to-git", env = "ALLOY_ADD_TO_GIT")]
    pub add_to_git: bool,
    pub fact: String,
}

#[derive(clap::Args, Debug, Clone)]
pub struct ReadArgs {
    pub fact: String,
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
    pub fact: String,
}

pub fn handle(args: Args, ctx: &Ctx) {
    match args.cmd {
        Cmd::Read(args) => handle_read(args, ctx),
        Cmd::Write(args) => handle_write(args, ctx),
        Cmd::Edit(args) => handle_edit(args, ctx),
        Cmd::List(args) => handle_list(args, ctx),
        Cmd::Show(args) => handle_show(args, ctx),
    }
}

fn handle_read(args: ReadArgs, ctx: &Ctx) {
    let state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load stae")
    {
        Ok(r) => r,
        Err(err) => {
            ctx.ui.print_error(&err);
            return;
        }
    };

    let fact = match facts::find(&state, &args.fact)
        .wrap_err_with(|| format!("Failed to find fact `{}`", args.fact))
    {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    match facts::read(ctx, fact).wrap_err_with(|| format!("Failed to read fact `{}`", args.fact)) {
        Ok(value) => ctx.ui.print_data(value),
        Err(e) => ctx.ui.print_error(&e),
    }
}

fn handle_write(args: WriteArgs, ctx: &Ctx) {
    let state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load stae")
    {
        Ok(r) => r,
        Err(err) => {
            ctx.ui.print_error(&err);
            return;
        }
    };

    let fact = match facts::find(&state, &args.fact)
        .wrap_err_with(|| format!("Failed to find fact `{}`", args.fact))
    {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let stdin = std::io::stdin();
    if stdin.is_terminal() {
        ctx.ui
            .print_error(&err_msg("No data was provided through stdin"));
        return;
    }

    let mut data = String::new();
    if let Err(e) = stdin.lock().read_to_string(&mut data) {
        ctx.ui.print_error(&e);
        return;
    }

    match facts::write(ctx, fact, data, args.force, args.add_to_git)
        .wrap_err_with(|| format!("Failed to write fact `{}`", args.fact))
    {
        Ok(_) => {
            ctx.ui.print_info(&format!(
                "Fact `{}` written to '{}'",
                args.fact,
                fact.data.file.display()
            ));
        }
        Err(e) => ctx.ui.print_error(&e),
    }
}

fn handle_edit(args: EditArgs, ctx: &Ctx) {
    let state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load stae")
    {
        Ok(r) => r,
        Err(err) => {
            ctx.ui.print_error(&err);
            return;
        }
    };

    let fact = match facts::find(&state, &args.fact)
        .wrap_err_with(|| format!("Failed to find fact `{}`", args.fact))
    {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let current_data = match facts::read(ctx, fact)
        .wrap_err_with(|| format!("Failed to read fact `{}`", args.fact))
    {
        Ok(value) => value,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let new_data = match edit(&current_data)
        .wrap_err_with(|| format!("Failed to edit fact `{}`", args.fact))
    {
        Ok(Some(data)) => data,
        Ok(None) => {
            ctx.ui.print_skip("No changes made, skipping...");
            return;
        }
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    match facts::write(ctx, fact, new_data, true, args.add_to_git)
        .wrap_err_with(|| format!("Failed to write fact `{}`", args.fact))
    {
        Ok(_) => {
            ctx.ui.print_info(&format!(
                "Fact `{}` written to '{}'",
                args.fact,
                fact.data.file.display()
            ));
        }
        Err(e) => ctx.ui.print_error(&e),
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

    let headers = vec!["Fact", "File", "Tags"];
    let mut rows = Vec::new();

    let mut facts: Vec<_> = state.facts.iter().collect();
    facts.sort_by_key(|(k, _)| *k);

    for (name, fact) in facts {
        if !args.tags.is_empty() && !fact.tags.iter().any(|t| args.tags.contains(t)) {
            continue;
        }

        let tags = fact.tags.join(", ");
        rows.push(vec![
            name.clone(),
            fact.file.to_str().unwrap_or("").to_string(),
            tags,
        ]);
    }

    if !rows.is_empty() {
        ctx.ui.print_table(headers, rows);
    } else {
        ctx.ui.print_info("No facts found.");
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

    let fact = match facts::find(&state, &args.fact)
        .wrap_err_with(|| format!("Failed to find fact `{}`", args.fact))
    {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let headers = vec!["Property", "Value"];
    let rows = vec![
        vec!["Name".to_string(), args.fact.clone()],
        vec![
            "File".to_string(),
            fact.data.file.to_str().unwrap_or("").to_string(),
        ],
        vec!["Tags".to_string(), fact.data.tags.join(", ")],
    ];

    ctx.ui.print_table(headers, rows);
}
