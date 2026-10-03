use std::io::{IsTerminal, Read};

use alloy_core::domain::{
    NameMarker, PathMarker,
    facts::{
        GetFactValueEvent, ListFactsEvent, SetFactValueEvent, ShowFactEvent, get_fact_value,
        list_facts, set_fact_value, show_fact,
    },
};

use crate::{
    ctx::Ctx,
    editor::edit,
    error::{WrapErrExt, err_msg},
    term_ui::TermUi,
};

#[derive(clap::Parser, Debug, Clone)]
pub struct Args {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(clap::Subcommand, Debug, Clone)]
pub enum Cmd {
    Get(GetArgs),
    Set(SetArgs),
    Edit(EditArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(clap::Args, Debug, Clone)]
pub struct SetArgs {
    #[arg(short = 'f', long = "force")]
    pub force: bool,
    #[arg(short = 'a', long = "add-to-git")]
    pub add_to_git: bool,
    pub fact: String,
}

#[derive(clap::Args, Debug, Clone)]
pub struct EditArgs {
    #[arg(short = 'a', long = "add-to-git")]
    pub add_to_git: bool,
    pub fact: String,
}

#[derive(clap::Args, Debug, Clone)]
pub struct GetArgs {
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

pub fn handle(args: Args, ctx: &mut Ctx, ui: TermUi) {
    match args.cmd {
        Cmd::Get(args) => handle_get(args, ctx, ui),
        Cmd::Set(args) => handle_set(args, ctx, ui),
        Cmd::Edit(args) => handle_edit(args, ctx, ui),
        Cmd::List(args) => handle_list(args, ctx, ui),
        Cmd::Show(args) => handle_show(args, ctx, ui),
    }
}

fn handle_get(args: GetArgs, ctx: &mut Ctx, ui: TermUi) {
    if let Ok(data) = get_fact_value(
        &args.fact,
        ctx,
        |_ctx: &mut Ctx, event: GetFactValueEvent<'_>| match event {
            GetFactValueEvent::Error(err) => {
                ui.print_error(err);
            }
            _ => (),
        },
    ) {
        ui.print_data(data)
    };
}

fn handle_set(args: SetArgs, ctx: &mut Ctx, ui: TermUi) {
    let stdin = std::io::stdin();
    if stdin.is_terminal() {
        ui.print_error(&err_msg("No data was provided through stdin"));
        return;
    }

    let mut data = String::new();
    if let Err(e) = stdin
        .lock()
        .read_to_string(&mut data)
        .wrap_err("Failed to read stdin")
    {
        ui.print_error(&e);
        return;
    }

    let _ = set_fact_value(
        &args.fact,
        &data,
        args.force.then_some(true),
        args.add_to_git.then_some(true),
        ctx,
        |_ctx: &mut Ctx, event: SetFactValueEvent<'_>| match event {
            SetFactValueEvent::ValueWritten(fact) => {
                ui.print_info(&format!(
                    "Fact {} was written to {}",
                    NameMarker(&args.fact),
                    PathMarker(&fact.data.file),
                ));
            }
            SetFactValueEvent::Error(err) => {
                ui.print_error(err);
            }
        },
    );
}

fn handle_edit(args: EditArgs, ctx: &mut Ctx, ui: TermUi) {
    let data = match get_fact_value(&args.fact, ctx, |_: &mut Ctx, _: GetFactValueEvent<'_>| {}) {
        Ok(data) => data,
        Err(err) => {
            ui.print_error(&err);
            return;
        }
    };

    let data = match edit(&data)
        .wrap_err_with(|| format!("Failed to edit fact {}", NameMarker(&args.fact)))
    {
        Ok(Some(data)) if data.is_empty() => {
            ui.print_skip("The temp file is empty. Aborting operation.");
            return;
        }
        Ok(Some(data)) => data,
        Ok(None) => {
            ui.print_skip("No changes made, skipping...");
            return;
        }
        Err(e) => {
            ui.print_error(&e);
            return;
        }
    };

    let _ = set_fact_value(
        &args.fact,
        &data,
        Some(true),
        args.add_to_git.then_some(true),
        ctx,
        |_ctx: &mut Ctx, event: SetFactValueEvent<'_>| match event {
            SetFactValueEvent::ValueWritten(fact) => {
                ui.print_info(&format!(
                    "Fact {} was written to {}",
                    NameMarker(&args.fact),
                    PathMarker(&fact.data.file),
                ));
            }
            SetFactValueEvent::Error(err) => {
                ui.print_error(err);
            }
        },
    );
}

fn handle_list(args: ListArgs, ctx: &mut Ctx, ui: TermUi) {
    let headers = vec!["Fact", "File", "Tags"];
    let mut rows = Vec::new();

    let reporter = |_ctx: &mut Ctx, event: ListFactsEvent<'_>| match event {
        ListFactsEvent::Fact(fact) => {
            rows.push(vec![
                fact.name.to_string(),
                fact.data.file.to_string_lossy().into_owned(),
                fact.data.tags.join(", "),
            ]);
        }
        ListFactsEvent::Error(e) => {
            ui.print_error(e);
        }
        ListFactsEvent::NoMatchingFacts => {
            ui.print_info("No facts found.");
        }
    };

    let Ok(_) = list_facts(&<[String; 0]>::default(), &args.tags, ctx, reporter) else {
        return;
    };

    if !rows.is_empty() {
        ui.print_table(headers, rows);
    }
}

fn handle_show(args: ShowArgs, ctx: &mut Ctx, ui: TermUi) {
    let _ = show_fact(
        &args.fact,
        ctx,
        |_: &mut Ctx, event: ShowFactEvent<'_>| match event {
            ShowFactEvent::Fact(fact) => {
                let headers = vec!["Property", "Value"];
                let rows = vec![
                    vec!["Name".to_string(), args.fact.clone()],
                    vec![
                        "File".to_string(),
                        fact.data.file.to_str().unwrap_or("").to_string(),
                    ],
                    vec!["Tags".to_string(), fact.data.tags.join(", ")],
                ];

                ui.print_table(headers, rows);
            }
            ShowFactEvent::Error(err) => {
                ui.print_error(&err);
            }
        },
    );
}
