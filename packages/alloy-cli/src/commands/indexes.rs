use alloy_core::domain::indexes::{
    AllocIndexesEvent, GetIndexValueEvent, ListIndexesEvent, ShowIndexEvent, alloc_indexes,
    get_index_value, list_indexes, show_index,
};

use crate::{ctx::Ctx, term_ui::TermUi};

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
    Get(GetArgs),
}

#[derive(clap::Args, Debug, Clone)]
pub struct AllocArgs {
    #[arg(short = 'f', long = "force")]
    pub force: bool,
    #[arg(short = 'a', long = "add-to-git")]
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

#[derive(clap::Args, Debug, Clone)]
pub struct GetArgs {
    #[arg(long = "json", help = "Output as JSON")]
    pub json: bool,
    #[arg(help = "Name of the index")]
    pub name: String,
}

pub fn handle(args: Args, ctx: &mut Ctx, ui: &mut TermUi) {
    match args.cmd {
        Cmd::Alloc(args) => handle_alloc(args, ctx, ui),
        Cmd::List(args) => handle_list(args, ctx, ui),
        Cmd::Show(args) => handle_show(args, ctx, ui),
        Cmd::Get(args) => handle_get(args, ctx, ui),
    }
}

fn handle_alloc(args: AllocArgs, ctx: &mut Ctx, ui: &mut TermUi) {
    log::info!("Starting index allocation");
    log::debug!("Indexes to alloc: {:?}", args.indexes);

    let _ = alloc_indexes(
        &args.indexes,
        args.force.then_some(true),
        args.add_to_git.then_some(true),
        ctx,
        |_ctx: &mut Ctx, event: AllocIndexesEvent<'_>| match event {
            AllocIndexesEvent::IndexAllocated { index_name, values } => {
                ui.print_ok(&format!(
                    "Index {} saved ({} entries).",
                    alloy_core::domain::NameMarker(index_name),
                    values.len()
                ));
            }
            AllocIndexesEvent::IndexSkipped {
                index_name,
                values: _,
            } => {
                ui.print_skip(&format!(
                    "No changes in index {}.",
                    alloy_core::domain::NameMarker(index_name)
                ));
            }
            AllocIndexesEvent::Error(err) => {
                ui.print_error(err);
            }
        },
    );
}

fn handle_list(_args: ListArgs, ctx: &mut Ctx, ui: &mut TermUi) {
    let headers = vec!["Name", "Fact Name", "Min", "Max", "Keys"];
    let mut rows = Vec::new();

    let reporter = |_ctx: &mut Ctx, event: ListIndexesEvent<'_>| match event {
        ListIndexesEvent::Index(index) => {
            let keys_len = index.data.keys.as_ref().map(|k| k.len()).unwrap_or(0);

            rows.push(vec![
                index.name.to_string(),
                index.data.fact_name.clone(),
                index.data.min_value.to_string(),
                index.data.max_value.to_string(),
                keys_len.to_string(),
            ]);
        }
        ListIndexesEvent::Error(err) => {
            ui.print_error(err);
        }
        ListIndexesEvent::NoMatchingIndexes => {
            ui.print_info("No indexes defined.");
        }
    };

    let Ok(_) = list_indexes(&<[String; 0]>::default(), ctx, reporter) else {
        return;
    };

    if !rows.is_empty() {
        ui.print_table(headers, rows);
    }
}

fn handle_show(args: ShowArgs, ctx: &mut Ctx, ui: &mut TermUi) {
    let _ = show_index(
        &args.name,
        ctx,
        |_: &mut Ctx, event: ShowIndexEvent<'_>| match event {
            ShowIndexEvent::Index(index) => {
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

                ui.print_table(headers, rows);
            }
            ShowIndexEvent::Error(err) => {
                ui.print_error(&err);
            }
        },
    );
}

fn handle_get(args: GetArgs, ctx: &mut Ctx, ui: &mut TermUi) {
    let _ = get_index_value(
        &args.name,
        ctx,
        |_: &mut Ctx, event: GetIndexValueEvent<'_>| match event {
            GetIndexValueEvent::ValueRead { index: _, values } => {
                if args.json {
                    match serde_json::to_string_pretty(values) {
                        Ok(json) => println!("{}", json),
                        Err(e) => ui.print_error(&crate::error::err_msg(format!(
                            "Failed to serialize JSON: {}",
                            e
                        ))),
                    }
                } else {
                    let headers = vec!["Key", "Value"];
                    let mut rows = Vec::new();
                    let mut sorted_keys: Vec<_> = values.keys().collect();
                    sorted_keys.sort();
                    for k in sorted_keys {
                        rows.push(vec![k.clone(), values[k].to_string()]);
                    }
                    ui.print_table(headers, rows);
                }
            }
            GetIndexValueEvent::Error(err) => {
                ui.print_error(err);
            }
        },
    );
}
