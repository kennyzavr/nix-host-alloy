use std::io::{IsTerminal, Read};

use alloy_core::domain::{
    NameMarker, PathMarker,
    secrets::{
        GetSecretValueEvent, ListSecretRefsEvent, ListSecretsEvent, RekeySecretsEvent,
        SetSecretValueEvent, ShowSecretEvent, get_secret_value, list_secret_refs, list_secrets,
        rekey_secrets, set_secret_value, show_secret,
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
    pub cmd: Cmd,
}

#[derive(clap::Subcommand, Debug, Clone)]
pub enum Cmd {
    Get(GetArgs),
    Set(SetArgs),
    Edit(EditArgs),
    Rekey(RekeyArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(clap::Args, Debug, Clone)]
pub struct SetArgs {
    #[arg(short = 'f', long = "force")]
    pub force: bool,
    #[arg(short = 'a', long = "add-to-git")]
    pub add_to_git: bool,
    pub secret: String,
}

#[derive(clap::Args, Debug, Clone)]
pub struct EditArgs {
    #[arg(short = 'a', long = "add-to-git")]
    pub add_to_git: bool,
    pub secret: String,
}

#[derive(clap::Args, Debug, Clone)]
pub struct GetArgs {
    pub secret: String,
}

#[derive(clap::Args, Debug, Clone)]
pub struct RekeyArgs {
    pub secrets: Vec<String>,
    #[arg(long = "host")]
    pub hosts: Vec<String>,
    #[arg(long = "jail")]
    pub jails: Vec<String>,
    #[arg(long = "tag")]
    pub tags: Vec<String>,
    #[arg(short = 'f', long = "force")]
    pub force: bool,
    #[arg(short = 'a', long = "add-to-git")]
    pub add_to_git: bool,
}

#[derive(clap::Args, Debug, Clone)]
pub struct ListArgs {
    #[arg(long = "host")]
    pub hosts: Vec<String>,
    #[arg(long = "jail")]
    pub jails: Vec<String>,
    #[arg(long = "tag")]
    pub tags: Vec<String>,
    #[arg(short = 'v', long = "verbose")]
    pub verbose: bool,
    #[arg(long = "flat")]
    pub flat: bool,
}

#[derive(clap::Args, Debug, Clone)]
pub struct ShowArgs {
    pub secret: String,
}

pub fn handle(args: Args, ctx: &mut Ctx, ui: TermUi) {
    match args.cmd {
        Cmd::Get(args) => handle_get(args, ctx, ui),
        Cmd::Set(args) => handle_set(args, ctx, ui),
        Cmd::Edit(args) => handle_edit(args, ctx, ui),
        Cmd::Rekey(args) => handle_rekey(args, ctx, ui),
        Cmd::List(args) => handle_list(args, ctx, ui),
        Cmd::Show(args) => handle_show(args, ctx, ui),
    }
}

fn handle_get(args: GetArgs, ctx: &mut Ctx, ui: TermUi) {
    if let Ok(data) = get_secret_value(
        &args.secret,
        ctx,
        |_ctx: &mut Ctx, event: GetSecretValueEvent<'_>| match event {
            GetSecretValueEvent::Error(err) => {
                ui.print_error(err);
            }
            _ => (),
        },
    ) {
        ui.print_raw_data(&data)
    };
}

fn handle_set(args: SetArgs, ctx: &mut Ctx, ui: TermUi) {
    let stdin = std::io::stdin();
    if stdin.is_terminal() {
        ui.print_error(&err_msg("No data was provided through stdin"));
        return;
    }

    let mut data = Vec::new();
    if let Err(e) = stdin
        .lock()
        .read_to_end(&mut data)
        .wrap_err("Failed to read stdin")
    {
        ui.print_error(&e);
        return;
    }

    let _ = set_secret_value(
        &args.secret,
        &data,
        args.force.then_some(true),
        args.add_to_git.then_some(true),
        ctx,
        |_ctx: &mut Ctx, event: SetSecretValueEvent<'_>| match event {
            SetSecretValueEvent::ValueWritten(fact) => {
                ui.print_info(&format!(
                    "Secret {} was written to {}",
                    NameMarker(&args.secret),
                    PathMarker(&fact.data.file),
                ));
            }
            SetSecretValueEvent::Error(err) => {
                ui.print_error(err);
            }
        },
    );
}

fn handle_edit(args: EditArgs, ctx: &mut Ctx, ui: TermUi) {
    let data = match get_secret_value(
        &args.secret,
        ctx,
        |_ctx: &mut Ctx, _event: GetSecretValueEvent<'_>| {},
    ) {
        Ok(v) => v,
        Err(err) => {
            ui.print_error(&err);
            return;
        }
    };

    let data = match String::from_utf8(data).wrap_err("Secret value is not valid UTF-8") {
        Ok(s) => s,
        Err(e) => {
            ui.print_error(&e);
            return;
        }
    };

    let data = match edit(&data)
        .wrap_err_with(|| format!("Failed to edit secret {}", NameMarker(&args.secret)))
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

    let _ = set_secret_value(
        &args.secret,
        data.as_bytes(),
        Some(true),
        args.add_to_git.then_some(true),
        ctx,
        |_ctx: &mut Ctx, event: SetSecretValueEvent<'_>| match event {
            SetSecretValueEvent::ValueWritten(fact) => {
                ui.print_info(&format!(
                    "Secret {} was written to {}",
                    NameMarker(&args.secret),
                    PathMarker(&fact.data.file),
                ));
            }
            SetSecretValueEvent::Error(err) => {
                ui.print_error(err);
            }
        },
    );
}

fn handle_rekey(args: RekeyArgs, ctx: &mut Ctx, ui: TermUi) {
    let _ = rekey_secrets(
        &args.secrets,
        &args.hosts,
        &args.jails,
        &args.tags,
        args.force.then_some(true),
        args.add_to_git.then_some(true),
        ctx,
        |_ctx: &mut Ctx, event: RekeySecretsEvent<'_>| match event {
            RekeySecretsEvent::HostRefSkipped { host, secret_ref } => {
                ui.print_skip(&format!(
                    "Host {} secret {} already exists",
                    NameMarker(host.name),
                    NameMarker(secret_ref.master.name)
                ));
            }
            RekeySecretsEvent::HostRefRekeyed { host, secret_ref } => {
                ui.print_info(&format!(
                    "Rekeyed host {} secret {}",
                    NameMarker(host.name),
                    NameMarker(secret_ref.master.name)
                ));
            }
            RekeySecretsEvent::JailRefSkipped { jail, secret_ref } => {
                ui.print_skip(&format!(
                    "Jail {} secret {} already exists",
                    NameMarker(jail.name),
                    NameMarker(secret_ref.master.name)
                ));
            }
            RekeySecretsEvent::JailRefRekeyed { jail, secret_ref } => {
                ui.print_info(&format!(
                    "Rekeyed jail {} secret {}",
                    NameMarker(jail.name),
                    NameMarker(secret_ref.master.name)
                ));
            }
            RekeySecretsEvent::Error(err) => {
                ui.print_error(&err);
            }
            RekeySecretsEvent::NoMatchingSecrets => {
                ui.print_info("No secrets found matching the criteria.");
            }
            RekeySecretsEvent::ListError(_) => {
                ui.print_info("No secrets found matching the criteria.");
            }
        },
    );
}

fn handle_list(args: ListArgs, ctx: &mut Ctx, ui: TermUi) {
    let has_target_filters = !args.hosts.is_empty() || !args.jails.is_empty();

    if has_target_filters {
        let headers = vec!["Target", "Secret", "Master Secret Tags", "Target File"];
        let mut rows = Vec::new();

        let reporter = |_ctx: &mut Ctx, event: ListSecretRefsEvent<'_>| match event {
            ListSecretRefsEvent::HostRef { host, secret_ref } => {
                rows.push(vec![
                    format!("Host: {}", host.name),
                    secret_ref.master.name.to_string(),
                    secret_ref.master.data.tags.join(", "),
                    secret_ref.data.file.to_string_lossy().into_owned(),
                ]);
            }
            ListSecretRefsEvent::JailRef { jail, secret_ref } => {
                rows.push(vec![
                    format!("Jail: {}", jail.name),
                    secret_ref.master.name.to_string(),
                    secret_ref.master.data.tags.join(", "),
                    secret_ref.data.file.to_string_lossy().into_owned(),
                ]);
            }
            ListSecretRefsEvent::Error(err) => {
                ui.print_error(err);
            }
            ListSecretRefsEvent::NoMatchingSecrets => {
                ui.print_info("No secrets found matching the criteria.");
            }
        };

        let _ = list_secret_refs(
            &<[String; 0]>::default(),
            &args.hosts,
            &args.jails,
            &args.jails,
            ctx,
            reporter,
        );

        if !rows.is_empty() {
            ui.print_table(headers, rows);
        }
    } else {
        let headers = vec!["Master Secret", "File", "Tags"];
        let mut rows = Vec::new();

        let reporter = |_ctx: &mut Ctx, event: ListSecretsEvent<'_>| match event {
            ListSecretsEvent::Secret(secret) => {
                rows.push(vec![
                    secret.name.to_string(),
                    secret.data.file.to_string_lossy().into_owned(),
                    secret.data.tags.join(", "),
                ]);
            }
            ListSecretsEvent::Error(err) => {
                ui.print_error(err);
            }
            ListSecretsEvent::NoMatchingSecrets => {
                ui.print_info("No secrets found matching the criteria.");
            }
        };
        let _ = list_secrets(&<[String; 0]>::default(), &args.tags, ctx, reporter);

        if !rows.is_empty() {
            ui.print_table(headers, rows);
        }
    }
}

fn handle_show(args: ShowArgs, ctx: &mut Ctx, ui: TermUi) {
    let headers = vec!["Property", "Value"];
    let mut table_rows = Vec::new();
    let mut targets = Vec::new();

    let reporter = |_: &mut Ctx, event: ShowSecretEvent<'_>| match event {
        ShowSecretEvent::Secret(secret) => {
            table_rows.push(vec!["Name".to_string(), secret.name.to_string()]);
            table_rows.push(vec![
                "File".to_string(),
                secret.data.file.to_string_lossy().into_owned(),
            ]);
            table_rows.push(vec!["Tags".to_string(), secret.data.tags.join(", ")]);
        }
        ShowSecretEvent::HostRef {
            host,
            secret_ref: _,
        } => {
            targets.push(format!("Host: {}", host.name));
        }
        ShowSecretEvent::JailRef {
            jail,
            secret_ref: _,
        } => {
            targets.push(format!("Jail: {}", jail.name));
        }
        ShowSecretEvent::Error(error) => {
            ui.print_error(error);
        }
    };
    let _ = show_secret(&args.secret, ctx, reporter);

    if !table_rows.is_empty() {
        targets.sort();
        if !targets.is_empty() {
            table_rows.push(vec!["Targets".to_string(), targets.join("\n")]);
        } else {
            table_rows.push(vec!["Targets".to_string(), "None".to_string()]);
        }
        ui.print_table(headers, table_rows);
    }
}
