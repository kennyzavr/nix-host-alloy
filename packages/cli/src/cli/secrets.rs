use std::io::{IsTerminal, Read, Write};

use crate::{
    ctx::AppContext,
    error::{WrapErrExt, err_msg},
    infra::editor,
};

#[derive(clap::Parser, Debug, Clone)]
pub struct Args {
    #[command(subcommand)]
    pub cmd: Cmd,
}

#[derive(clap::Subcommand, Debug, Clone)]
pub enum Cmd {
    Read(ReadArgs),
    Write(WriteArgs),
    Edit(EditArgs),
    Rekey(RekeyArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(clap::Args, Debug, Clone)]
pub struct WriteArgs {
    #[arg(short = 'f', long = "force", env = "ALLOY_FORCE")]
    pub force: bool,
    #[arg(short = 'a', long = "add-to-git", env = "ALLOY_ADD_TO_GIT")]
    pub add_to_git: bool,
    pub secret: String,
}

#[derive(clap::Args, Debug, Clone)]
pub struct EditArgs {
    #[arg(short = 'a', long = "add-to-git", env = "ALLOY_ADD_TO_GIT")]
    pub add_to_git: bool,
    pub secret: String,
}

#[derive(clap::Args, Debug, Clone)]
pub struct ReadArgs {
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
    #[arg(short = 'f', long = "force", env = "ALLOY_FORCE")]
    pub force: bool,
    #[arg(short = 'a', long = "add-to-git", env = "ALLOY_ADD_TO_GIT")]
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

pub fn handle(args: Args, ctx: &AppContext) {
    match args.cmd {
        Cmd::Read(args) => handle_read(args, ctx),
        Cmd::Write(args) => handle_write(args, ctx),
        Cmd::Edit(args) => handle_edit(args, ctx),
        Cmd::Rekey(args) => handle_rekey(args, ctx),
        Cmd::List(args) => handle_list(args, ctx),
        Cmd::Show(args) => handle_show(args, ctx),
    }
}

fn handle_read(args: ReadArgs, ctx: &AppContext) {
    let service = &ctx.secrets_service;

    let record = match service.get(args.secret.clone()) {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    match service
        .read_master(&record)
        .wrap_err_with(|| format!("Failed to read master secret `{}`", args.secret))
    {
        Ok(data) => {
            let mut stdout = std::io::stdout();
            if let Err(e) = stdout.write_all(&data).and_then(|_| stdout.flush()) {
                ctx.ui.print_error(&e);
            }
        }
        Err(e) => ctx.ui.print_error(&e),
    }
}

fn handle_write(args: WriteArgs, ctx: &AppContext) {
    let service = &ctx.secrets_service;

    let record = match service.get(args.secret.clone()) {
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

    let mut value = Vec::new();
    if let Err(e) = stdin.lock().read_to_end(&mut value) {
        ctx.ui.print_error(&e);
        return;
    }

    match service
        .write_master(&record, &value, args.force, args.add_to_git)
        .wrap_err_with(|| format!("Failed to write master secret `{}`", args.secret))
    {
        Ok(_) => ctx.ui.print_info(&format!(
            "Secret `{}` encrypted to `{}`",
            args.secret,
            record.state.file.display()
        )),
        Err(e) => ctx.ui.print_error(&e),
    }
}

fn handle_edit(args: EditArgs, ctx: &AppContext) {
    let service = &ctx.secrets_service;

    let record = match service.get(args.secret.clone()) {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let current_data = match service
        .read_master(&record)
        .wrap_err_with(|| format!("Failed to read master secret `{}`", args.secret))
    {
        Ok(data) => data,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let current_string = match String::from_utf8(current_data) {
        Ok(s) => s,
        Err(e) => {
            ctx.ui
                .print_error(&err_msg(format!("Master secret is not valid UTF-8: {}", e)));
            return;
        }
    };

    match editor::edit(&current_string)
        .wrap_err_with(|| format!("Failed to edit master secret `{}`", args.secret))
    {
        Ok(Some(new_value)) => {
            if new_value.is_empty() {
                ctx.ui.print_skip("The file is empty. Aborting operation.");
                return;
            }
            match service.write_master(&record, new_value.as_bytes(), true, args.add_to_git) {
                Ok(_) => ctx
                    .ui
                    .print_ok(&format!("Secret `{}` was saved successfully", args.secret)),
                Err(e) => ctx.ui.print_error(&e),
            }
        }
        Ok(None) => ctx.ui.print_skip("No changes made, skipping..."),
        Err(e) => ctx.ui.print_error(&e),
    }
}

fn handle_rekey(args: RekeyArgs, ctx: &AppContext) {
    let service = &ctx.secrets_service;

    let host_collection = service.collect_hosts(&args.secrets, &args.hosts, &args.tags);
    let jail_collection = service.collect_jails(&args.secrets, &args.jails, &args.tags);

    let mut has_errors = false;
    let hosts = match host_collection {
        Ok(h) => h,
        Err(e) => {
            ctx.ui.print_error(&e);
            has_errors = true;
            Vec::new()
        }
    };

    let jails = match jail_collection {
        Ok(j) => j,
        Err(e) => {
            ctx.ui.print_error(&e);
            has_errors = true;
            Vec::new()
        }
    };

    if has_errors {
        return;
    }

    if hosts.is_empty() && jails.is_empty() {
        ctx.ui.print_info("No secrets found matching the criteria.");
        return;
    }

    for (host, secret) in hosts {
        match service.rekey_host(&host, &secret, args.force, args.add_to_git) {
            Ok(_) => ctx.ui.print_ok(&format!(
                "Rekeyed host `{}` secret `{}`",
                host.name, secret.name
            )),
            Err(e) => ctx.ui.print_error(&e),
        }
    }

    for (jail, secret) in jails {
        match service.rekey_jail(&jail, &secret, args.force, args.add_to_git) {
            Ok(_) => ctx.ui.print_ok(&format!(
                "Rekeyed jail `{}` secret `{}`",
                jail.name, secret.name
            )),
            Err(e) => ctx.ui.print_error(&e),
        }
    }
}

fn handle_list(args: ListArgs, ctx: &AppContext) {
    let service = &ctx.secrets_service;

    let has_target_filters = !args.hosts.is_empty() || !args.jails.is_empty();

    if has_target_filters {
        let host_collection = match service.collect_hosts(&[], &args.hosts, &args.tags) {
            Ok(h) => h,
            Err(e) => {
                ctx.ui.print_error(&e);
                return;
            }
        };

        let jail_collection = match service.collect_jails(&[], &args.jails, &args.tags) {
            Ok(j) => j,
            Err(e) => {
                ctx.ui.print_error(&e);
                return;
            }
        };

        let headers = vec!["Target", "Secret", "Master Secret Tags", "Target File"];
        let mut table_rows = Vec::new();
        let mut rows = Vec::new();

        for (host, secret) in host_collection {
            let tags = secret.state.tags.join(", ");
            let file = host
                .state
                .secrets
                .get(&secret.name)
                .map(|s| s.file.to_string_lossy().to_string())
                .unwrap_or_default();
            rows.push((
                format!("Host: {}", host.name),
                secret.name.to_string(),
                tags,
                file,
            ));
        }

        for (jail, secret) in jail_collection {
            let tags = secret.state.tags.join(", ");
            let file = jail
                .state
                .secrets
                .get(&secret.name)
                .map(|s| s.file.to_string_lossy().to_string())
                .unwrap_or_default();
            rows.push((
                format!("Jail: {}", jail.name),
                secret.name.to_string(),
                tags,
                file,
            ));
        }

        rows.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.1.cmp(&b.1)));

        for (target, secret, tags, file) in rows {
            table_rows.push(vec![target, secret, tags, file]);
        }

        if !table_rows.is_empty() {
            ctx.ui.print_table(headers, table_rows);
        } else {
            ctx.ui.print_info("No secrets found matching the criteria.");
        }
    } else {
        let state = match ctx.nix.load_state().wrap_err("Failed to load state") {
            Ok(s) => s,
            Err(e) => {
                ctx.ui.print_error(&e);
                return;
            }
        };

        let headers = vec!["Master Secret", "File", "Tags"];
        let mut table_rows = Vec::new();

        let mut secrets: Vec<_> = state.secrets.iter().collect();
        secrets.sort_by_key(|(k, _)| *k);

        for (name, secret) in secrets {
            if !args.tags.is_empty() && !secret.tags.iter().any(|t| args.tags.contains(t)) {
                continue;
            }

            table_rows.push(vec![
                name.clone(),
                secret.file.to_string_lossy().to_string(),
                secret.tags.join(", "),
            ]);
        }

        if !table_rows.is_empty() {
            ctx.ui.print_table(headers, table_rows);
        } else {
            ctx.ui.print_info("No secrets found matching the criteria.");
        }
    }
}

fn handle_show(args: ShowArgs, ctx: &AppContext) {
    let service = &ctx.secrets_service;

    match service
        .get(args.secret.clone())
        .wrap_err_with(|| format!("Failed to get secret `{}`", args.secret))
    {
        Ok(record) => {
            let secret = record.state;
            let headers = vec!["Property", "Value"];
            let mut table_rows = Vec::new();
            table_rows.push(vec!["Name".to_string(), args.secret.clone()]);
            table_rows.push(vec![
                "File".to_string(),
                secret.file.to_string_lossy().to_string(),
            ]);
            table_rows.push(vec!["Tags".to_string(), secret.tags.join(", ")]);

            let hosts = service
                .collect_hosts(&[args.secret.clone()], &[], &[])
                .unwrap_or_default();
            let jails = service
                .collect_jails(&[args.secret.clone()], &[], &[])
                .unwrap_or_default();

            let mut targets = Vec::new();
            for (host, _) in hosts {
                targets.push(format!("Host: {}", host.name));
            }
            for (jail, _) in jails {
                targets.push(format!("Jail: {}", jail.name));
            }
            targets.sort();

            if !targets.is_empty() {
                table_rows.push(vec!["Targets".to_string(), targets.join("\n")]);
            } else {
                table_rows.push(vec!["Targets".to_string(), "None".to_string()]);
            }

            ctx.ui.print_table(headers, table_rows);
        }
        Err(e) => {
            ctx.ui.print_error(&e);
        }
    }
}
