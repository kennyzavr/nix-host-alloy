use std::{
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

use crate::{ctx::Ctx, term_ui::TermUi};
use alloy_core::domain::NameMarker;
use alloy_core::domain::deploy::{DeployEvent, DeployOptions, deploy_host};

#[derive(clap::Args, Debug)]
#[command(about = "Build, sign, copy and activate one host")]
pub struct Args {
    pub host: String,
    #[arg(long, short = 'c')]
    pub connection: Option<String>,
    /// Additional SSH identity (OpenSSH identities are additive).
    #[arg(short = 'i', long = "identity-file")]
    pub identity_file: Option<PathBuf>,
}

pub fn handle(args: Args, ctx: &mut Ctx, ui: TermUi) {
    let cancelled = Arc::new(AtomicBool::new(false));
    let signal = cancelled.clone();
    if let Err(error) = ctrlc::set_handler(move || {
        signal.store(true, Ordering::SeqCst);
    }) {
        ui.print_error(&error);
        std::process::exit(1);
    }
    let options = DeployOptions {
        host: args.host,
        connection: args.connection,
        identity_file: args.identity_file,
    };
    let result = deploy_host(
        &options,
        &cancelled,
        ctx,
        |_: &mut Ctx, event: DeployEvent<'_>| match event {
            DeployEvent::Target { host, connection } => ui.print_info(&format!(
                "Deploying {} ({}) via {}",
                NameMarker(host.name),
                host.data.system,
                NameMarker(connection)
            )),
            DeployEvent::Build(host) => {
                ui.print_step(&format!("Building host {} locally", NameMarker(host.name)))
            }
            DeployEvent::Sign { host, key_name } => ui.print_step(&format!(
                "Decrypting key {} and signing closure for {}",
                NameMarker(key_name),
                NameMarker(host.name)
            )),
            DeployEvent::Copy(host) => {
                ui.print_step(&format!("Delivering closure to {}", NameMarker(host.name)))
            }
            DeployEvent::Activate(host) => ui.print_step(&format!(
                "Updating system profile and activating {}",
                NameMarker(host.name)
            )),
            DeployEvent::Completed(host) => ui.print_step(&format!(
                "Deployment of {} completed",
                NameMarker(host.name)
            )),
            DeployEvent::Error(error) => ui.print_error(error),
        },
    );
    if result.is_err() {
        // Domain resources have already been dropped, including the GC root.
        std::process::exit(if cancelled.load(Ordering::SeqCst) {
            130
        } else {
            1
        });
    }
}
