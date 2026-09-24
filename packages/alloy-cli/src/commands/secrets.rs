use std::io::{IsTerminal, Read, Write};

use alloy_core::{NameMark, PathMark, hosts, jails, secrets};

use crate::{
    ctx::Ctx,
    editor::edit,
    error::{WrapErrExt, err_msg},
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

pub fn handle(args: Args, ctx: &Ctx) {
    match args.cmd {
        Cmd::Read(args) => handle_read(args, ctx),
        Cmd::Write(args) => handle_write(args, ctx),
        Cmd::Edit(args) => handle_edit(args, ctx),
        Cmd::Rekey(args) => handle_rekey(args, ctx),
        Cmd::List(args) => handle_list(args, ctx),
        Cmd::Show(args) => handle_show(args, ctx),
    }
}

fn handle_read(args: ReadArgs, ctx: &Ctx) {
    let state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load state")
    {
        Ok(r) => r,
        Err(err) => {
            ctx.ui.print_error(&err);
            return;
        }
    };

    let secret = match secrets::find(&state, &args.secret)
        .wrap_err_with(|| format!("Failed to find master secret `{}`", args.secret))
    {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    match secrets::read(ctx, secret)
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

fn handle_write(args: WriteArgs, ctx: &Ctx) {
    let state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load state")
    {
        Ok(r) => r,
        Err(err) => {
            ctx.ui.print_error(&err);
            return;
        }
    };

    let secret = match secrets::find(&state, &args.secret)
        .wrap_err_with(|| format!("Failed to find master secret `{}`", args.secret))
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

    let mut data = Vec::new();
    if let Err(e) = stdin.lock().read_to_end(&mut data) {
        ctx.ui.print_error(&e);
        return;
    }

    match secrets::write(ctx, secret, data, args.force, args.add_to_git)
        .wrap_err_with(|| format!("Failed to write master secret `{}`", args.secret))
    {
        Ok(_) => ctx.ui.print_info(&format!(
            "Secret `{}` encrypted to '{}'",
            args.secret,
            secret.data.file.display()
        )),
        Err(e) => ctx.ui.print_error(&e),
    }
}

fn handle_edit(args: EditArgs, ctx: &Ctx) {
    let state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load state")
    {
        Ok(r) => r,
        Err(err) => {
            ctx.ui.print_error(&err);
            return;
        }
    };

    let secret = match secrets::find(&state, &args.secret)
        .wrap_err_with(|| format!("Failed to find master secret `{}`", args.secret))
    {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let current_data = match secrets::read(ctx, secret)
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

    let new_value = match edit(&current_string)
        .wrap_err_with(|| format!("Failed to edit master secret `{}`", args.secret))
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

    if new_value.is_empty() {
        ctx.ui.print_skip("The file is empty. Aborting operation.");
        return;
    }

    match secrets::write(ctx, secret, new_value.into_bytes(), true, args.add_to_git)
        .wrap_err_with(|| format!("Failed to write master secret `{}`", args.secret))
    {
        Ok(_) => ctx
            .ui
            .print_ok(&format!("Secret `{}` was saved successfully", args.secret)),
        Err(e) => ctx.ui.print_error(&e),
    }
}

fn handle_rekey(args: RekeyArgs, ctx: &Ctx) {
    log::info!("Starting secrets rekey operation");
    let state = match ctx
        .nix
        .load_state_data(false)
        .wrap_err("Failed to load state")
    {
        Ok(r) => r,
        Err(err) => {
            ctx.ui.print_error(&err);
            return;
        }
    };

    let mut has_errors = false;
    let mut target_hosts = Vec::new();
    let mut target_jails = Vec::new();

    let mut hosts_to_process = Vec::new();
    if args.hosts.is_empty() {
        hosts_to_process.extend(hosts::find_all(&state));
    } else {
        for h_name in &args.hosts {
            match hosts::find(&state, h_name)
                .wrap_err_with(|| format!("Host `{}` not found", h_name))
            {
                Ok(host) => hosts_to_process.push(host),
                Err(e) => {
                    ctx.ui.print_error(&e);
                    has_errors = true;
                }
            }
        }
    }

    let mut jails_to_process = Vec::new();
    if args.jails.is_empty() {
        for j_res in jails::find_all(&state) {
            match j_res {
                Ok(jail) => jails_to_process.push(jail),
                Err(e) => {
                    ctx.ui.print_error(&e);
                    has_errors = true;
                }
            }
        }
    } else {
        for j_name in &args.jails {
            match jails::find(&state, j_name)
                .map_err(|e| err_msg(e.to_string()))
                .wrap_err_with(|| format!("Jail `{}` not found", j_name))
            {
                Ok(jail) => jails_to_process.push(jail),
                Err(e) => {
                    ctx.ui.print_error(&e);
                    has_errors = true;
                }
            }
        }
    }

    let mut secrets_to_process = Vec::new();
    if args.secrets.is_empty() {
        for s_res in secrets::find_all(&state) {
            match s_res {
                Ok(secret) => secrets_to_process.push(secret),
                Err(e) => {
                    ctx.ui.print_error(&e);
                    has_errors = true;
                }
            }
        }
    } else {
        for s_name in &args.secrets {
            match secrets::find(&state, s_name)
                .wrap_err_with(|| format!("Master secret `{}` not found", s_name))
            {
                Ok(secret) => secrets_to_process.push(secret),
                Err(e) => {
                    ctx.ui.print_error(&e);
                    has_errors = true;
                }
            }
        }
    }

    if has_errors {
        log::debug!("Errors encountered while resolving targets, aborting rekey");
        return;
    }

    log::debug!("Filtering targets by tags: {:?}", args.tags);
    hosts_to_process
        .retain(|h| args.tags.is_empty() || h.data.tags.iter().any(|t| args.tags.contains(t)));
    jails_to_process
        .retain(|j| args.tags.is_empty() || j.data.tags.iter().any(|t| args.tags.contains(t)));

    log::debug!(
        "After filtering, hosts: {}, jails: {}",
        hosts_to_process.len(),
        jails_to_process.len()
    );

    for host in hosts_to_process {
        for secret in &secrets_to_process {
            if let Ok(host_ref) = secrets::find_host_ref(host, *secret) {
                target_hosts.push((host, *secret, host_ref));
            }
        }
    }

    for jail in jails_to_process {
        for secret in &secrets_to_process {
            if let Ok(jail_ref) = secrets::find_jail_ref(jail, *secret) {
                target_jails.push((jail, *secret, jail_ref));
            }
        }
    }

    if target_hosts.is_empty() && target_jails.is_empty() {
        ctx.ui.print_info("No secrets found matching the criteria.");
        return;
    }

    for (host, secret, host_ref) in target_hosts {
        if !args.force && secrets::exists_ref(ctx, host_ref) {
            ctx.ui.print_skip(&format!(
                "Host {} secret {} already exists",
                NameMark(host.name),
                NameMark(&host_ref.master.name)
            ));
            continue;
        }

        match secrets::rekey_ref(ctx, host_ref, args.force, args.add_to_git).wrap_err_with(|| {
            format!(
                "Failed to rekey host `{}` secret `{}`",
                host.name, secret.name
            )
        }) {
            Ok(_) => ctx.ui.print_ok(&format!(
                "Rekeyed host `{}` secret `{}`",
                host.name, secret.name
            )),
            Err(e) => ctx.ui.print_error(&e),
        }
    }

    for (jail, secret, jail_ref) in target_jails {
        if !args.force && secrets::exists_ref(ctx, jail_ref) {
            ctx.ui.print_skip(&format!(
                "Jail {} secret {} already exists",
                NameMark(jail.name),
                NameMark(&jail_ref.master.name)
            ));
            continue;
        }

        match secrets::rekey_ref(ctx, jail_ref, args.force, args.add_to_git).wrap_err_with(|| {
            format!(
                "Failed to rekey jail `{}` secret `{}`",
                jail.name, secret.name
            )
        }) {
            Ok(_) => ctx.ui.print_ok(&format!(
                "Rekeyed jail `{}` secret `{}`",
                jail.name, secret.name
            )),
            Err(e) => ctx.ui.print_error(&e),
        }
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

    let has_target_filters = !args.hosts.is_empty() || !args.jails.is_empty();

    if has_target_filters {
        let mut table_rows = Vec::new();
        let headers = vec!["Target", "Secret", "Master Secret Tags", "Target File"];
        let mut rows = Vec::new();

        let mut has_errors = false;
        let mut hosts_to_process = Vec::new();
        if args.hosts.is_empty() {
            hosts_to_process.extend(hosts::find_all(&state));
        } else {
            for h_name in &args.hosts {
                match hosts::find(&state, h_name)
                    .wrap_err_with(|| format!("Host `{}` not found", h_name))
                {
                    Ok(host) => hosts_to_process.push(host),
                    Err(e) => {
                        ctx.ui.print_error(&e);
                        has_errors = true;
                    }
                }
            }
        }

        let mut jails_to_process = Vec::new();
        if args.jails.is_empty() {
            for j_res in jails::find_all(&state) {
                match j_res {
                    Ok(jail) => jails_to_process.push(jail),
                    Err(e) => {
                        ctx.ui.print_error(&e);
                        has_errors = true;
                    }
                }
            }
        } else {
            for j_name in &args.jails {
                match jails::find(&state, j_name)
                    .map_err(|e| err_msg(e.to_string()))
                    .wrap_err_with(|| format!("Jail `{}` not found", j_name))
                {
                    Ok(jail) => jails_to_process.push(jail),
                    Err(e) => {
                        ctx.ui.print_error(&e);
                        has_errors = true;
                    }
                }
            }
        }

        let mut secrets_to_process = Vec::new();
        for s_res in secrets::find_all(&state) {
            match s_res {
                Ok(secret) => secrets_to_process.push(secret),
                Err(e) => {
                    ctx.ui.print_error(&e);
                    has_errors = true;
                }
            }
        }

        if has_errors {
            return;
        }

        hosts_to_process
            .retain(|h| args.tags.is_empty() || h.data.tags.iter().any(|t| args.tags.contains(t)));
        jails_to_process
            .retain(|j| args.tags.is_empty() || j.data.tags.iter().any(|t| args.tags.contains(t)));

        for host in hosts_to_process {
            for secret in &secrets_to_process {
                if let Ok(host_ref) = secrets::find_host_ref(host, *secret) {
                    let tags = secret.data.tags.join(", ");
                    let file = host_ref.data.file.display().to_string();
                    rows.push((
                        format!("Host: {}", host.name),
                        secret.name.to_string(),
                        tags,
                        file,
                    ));
                }
            }
        }

        for jail in jails_to_process {
            for secret in &secrets_to_process {
                if let Ok(jail_ref) = secrets::find_jail_ref(jail, *secret) {
                    let tags = secret.data.tags.join(", ");
                    let file = jail_ref.data.file.display().to_string();
                    rows.push((
                        format!("Jail: {}", jail.name),
                        secret.name.to_string(),
                        tags,
                        file,
                    ));
                }
            }
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
        let headers = vec!["Master Secret", "File", "Tags"];
        let mut table_rows = Vec::new();

        let mut all_secrets: Vec<_> = secrets::find_all(&state)
            .into_iter()
            .filter_map(|r| match r {
                Ok(s) => Some(s),
                Err(e) => {
                    ctx.ui.print_error(&e);
                    None
                }
            })
            .collect();

        all_secrets.sort_by_key(|s| s.name);

        for secret in all_secrets {
            if !args.tags.is_empty() && !secret.data.tags.iter().any(|t| args.tags.contains(t)) {
                continue;
            }

            table_rows.push(vec![
                secret.name.to_string(),
                secret.data.file.display().to_string(),
                secret.data.tags.join(", "),
            ]);
        }

        if !table_rows.is_empty() {
            ctx.ui.print_table(headers, table_rows);
        } else {
            ctx.ui.print_info("No secrets found matching the criteria.");
        }
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

    let secret = match secrets::find(&state, &args.secret)
        .wrap_err_with(|| format!("Failed to find master secret `{}`", args.secret))
    {
        Ok(r) => r,
        Err(e) => {
            ctx.ui.print_error(&e);
            return;
        }
    };

    let headers = vec!["Property", "Value"];
    let mut table_rows = Vec::new();
    table_rows.push(vec!["Name".to_string(), args.secret.clone()]);
    table_rows.push(vec![
        "File".to_string(),
        secret.data.file.display().to_string(),
    ]);
    table_rows.push(vec!["Tags".to_string(), secret.data.tags.join(", ")]);

    let mut targets = Vec::new();
    for host in hosts::find_all(&state) {
        if secrets::find_host_ref(host, secret).is_ok() {
            targets.push(format!("Host: {}", host.name));
        }
    }
    for jail_res in jails::find_all(&state) {
        if let Ok(j) = jail_res {
            if secrets::find_jail_ref(j, secret).is_ok() {
                targets.push(format!("Jail: {}", j.name));
            }
        }
    }
    targets.sort();

    if !targets.is_empty() {
        table_rows.push(vec!["Targets".to_string(), targets.join("\n")]);
    } else {
        table_rows.push(vec!["Targets".to_string(), "None".to_string()]);
    }

    ctx.ui.print_table(headers, table_rows);
}
