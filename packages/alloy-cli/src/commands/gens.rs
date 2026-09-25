use alloy_core::domain::gens::{
    ExecGensEvent, ListGensEvent, ShowGenEvent, exec_gens, list_gens, show_gen,
};

use crate::{ctx::Ctx, term_ui::TermUi};

#[derive(clap::Parser, Debug, Clone)]
pub struct Args {
    #[command(subcommand)]
    pub cmd: Cmd,
}

#[derive(clap::Subcommand, Debug, Clone)]
pub enum Cmd {
    Exec(ExecArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(clap::Args, Debug, Clone)]
pub struct ExecArgs {
    #[arg(short = 'f', long = "force")]
    pub force: bool,
    #[arg(short = 'a', long = "add-to-git")]
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

pub fn handle(args: Args, ctx: &mut Ctx, ui: &mut TermUi) {
    match args.cmd {
        Cmd::Exec(args) => handle_exec(args, ctx, ui),
        Cmd::List(args) => handle_list(args, ctx, ui),
        Cmd::Show(args) => handle_show(args, ctx, ui),
    }
}

fn handle_exec(args: ExecArgs, ctx: &mut Ctx, ui: &mut TermUi) {
    log::info!("Executing generators");

    let _ = exec_gens(
        &args.generators,
        &args.tags,
        args.force.then_some(true),
        args.add_to_git.then_some(true),
        ctx,
        |_ctx: &mut Ctx, event: ExecGensEvent<'_>| match event {
            ExecGensEvent::GenExec { r#gen } => {
                ui.print_step(&format!(
                    "Generator {}",
                    alloy_core::domain::NameMarker(r#gen.name)
                ));
            }
            ExecGensEvent::GenSkip { .. } => {
                ui.print_skip(&format!("The generator was skipped (up to date)\n"));
            }
            ExecGensEvent::Error(err) => {
                ui.print_error(err);
            }
        },
    );
}

fn handle_list(args: ListArgs, ctx: &mut Ctx, ui: &mut TermUi) {
    let headers = if args.verbose {
        vec!["Generator", "Wants", "After", "Secrets", "Facts", "Tags"]
    } else {
        vec!["Generator", "Tags"]
    };
    let mut rows = Vec::new();

    let reporter = |_ctx: &mut Ctx, event: ListGensEvent<'_>| match event {
        ListGensEvent::Gen(r#gen) => {
            let tags = r#gen.data.tags.join(", ");
            if args.verbose {
                let wants = r#gen.data.wants.join(", ");
                let after = r#gen.data.after.join(", ");

                let mut secrets_vec: Vec<_> = r#gen.data.secrets.iter().collect();
                secrets_vec.sort();
                let secrets = secrets_vec
                    .into_iter()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", ");

                let mut facts_vec: Vec<_> = r#gen.data.facts.iter().collect();
                facts_vec.sort();
                let facts = facts_vec
                    .into_iter()
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(", ");

                rows.push(vec![
                    r#gen.name.to_string(),
                    wants,
                    after,
                    secrets,
                    facts,
                    tags,
                ]);
            } else {
                rows.push(vec![r#gen.name.to_string(), tags]);
            }
        }
        ListGensEvent::Error(err) => {
            ui.print_error(err);
        }
        ListGensEvent::NoMatchingGens => {
            ui.print_info("No generators found.");
        }
    };

    let Ok(_) = list_gens(&<[String; 0]>::default(), &args.tags, ctx, reporter) else {
        return;
    };

    if !rows.is_empty() {
        ui.print_table(headers, rows);
    }
}

fn handle_show(args: ShowArgs, ctx: &mut Ctx, ui: &mut TermUi) {
    let _ = show_gen(
        &args.generator,
        ctx,
        |_: &mut Ctx, event: ShowGenEvent<'_>| match event {
            ShowGenEvent::Gen(r#gen) => {
                let headers = vec!["Property", "Value"];
                let mut rows = Vec::new();

                rows.push(vec!["Name".to_string(), r#gen.name.to_string()]);
                rows.push(vec!["Tags".to_string(), r#gen.data.tags.join(", ")]);
                rows.push(vec!["Wants".to_string(), r#gen.data.wants.join(", ")]);
                rows.push(vec!["After".to_string(), r#gen.data.after.join(", ")]);

                let mut secrets: Vec<_> = r#gen.data.secrets.iter().collect();
                secrets.sort();
                rows.push(vec![
                    "Secrets".to_string(),
                    secrets.into_iter().cloned().collect::<Vec<_>>().join(", "),
                ]);

                let mut facts: Vec<_> = r#gen.data.facts.iter().collect();
                facts.sort();
                rows.push(vec![
                    "Facts".to_string(),
                    facts.into_iter().cloned().collect::<Vec<_>>().join(", "),
                ]);

                ui.print_table(headers, rows);
            }
            ShowGenEvent::Error(err) => {
                ui.print_error(err);
            }
        },
    );
}
