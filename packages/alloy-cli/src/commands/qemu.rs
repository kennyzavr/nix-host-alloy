use alloy_core::domain::qemu::{
    LaunchQemuGuestsEvent, ListQemuGuestsEvent, ShowQemuGuestEvent, launch_qemu_guests,
    list_qemu_guests, show_qemu_guest,
};

use crate::{ctx::Ctx, term_ui::TermUi};

#[derive(clap::Parser, Debug, Clone)]
pub struct Args {
    #[command(subcommand)]
    pub cmd: Cmd,
}

#[derive(clap::Subcommand, Debug, Clone)]
pub enum Cmd {
    Launch(LaunchArgs),
    List(ListArgs),
    Show(ShowArgs),
}

#[derive(clap::Args, Debug, Clone)]
pub struct LaunchArgs {
    #[arg(short = 't', long = "tag")]
    pub tags: Vec<String>,
    pub hosts: Vec<String>,
}

#[derive(clap::Args, Debug, Clone)]
pub struct ListArgs {
    #[arg(short = 't', long = "tag")]
    pub tags: Vec<String>,
}

#[derive(clap::Args, Debug, Clone)]
pub struct ShowArgs {
    pub host: String,
}

pub fn handle(args: Args, ctx: &mut Ctx, ui: &mut TermUi) {
    match args.cmd {
        Cmd::Launch(args) => handle_launch(args, ctx, ui),
        Cmd::List(args) => handle_list(args, ctx, ui),
        Cmd::Show(args) => handle_show(args, ctx, ui),
    }
}

fn handle_launch(args: LaunchArgs, ctx: &mut Ctx, ui: &mut TermUi) {
    let _ = launch_qemu_guests(
        &args.hosts,
        &args.tags,
        ctx,
        |_ctx: &mut Ctx, event: LaunchQemuGuestsEvent<'_>| match event {
            LaunchQemuGuestsEvent::LaunchVdeSwitch { net_name } => {
                ui.print_step(&format!(
                    "Started VDE switch for {}",
                    alloy_core::domain::NameMarker(net_name)
                ));
            }
            LaunchQemuGuestsEvent::StopVdeSwitch { net_name } => {
                ui.print_step(&format!(
                    "Stopped VDE switch for {}",
                    alloy_core::domain::NameMarker(net_name)
                ));
            }
            LaunchQemuGuestsEvent::LaunchQemuGuest(guest) => {
                ui.print_step(&format!(
                    "Launched QEMU guest for {}",
                    alloy_core::domain::NameMarker(guest.host.name)
                ));
                if !guest.data.port_forwards.is_empty() {
                    ui.print_info(&format!(
                        "Port forwards for {}:",
                        alloy_core::domain::NameMarker(guest.host.name)
                    ));
                    for pf in &guest.data.port_forwards {
                        let proto = match pf.proto {
                            alloy_core::domain::models::L4Proto::Tcp => "tcp",
                            alloy_core::domain::models::L4Proto::Udp => "udp",
                        };
                        ui.print_info(&format!(
                            "  - {}: {} -> {} ({})",
                            pf.name, pf.hypervisor, pf.guest, proto
                        ));
                    }
                }
            }
            LaunchQemuGuestsEvent::StopQemuGuest(guest) => {
                ui.print_step(&format!(
                    "QEMU guest {} exited",
                    alloy_core::domain::NameMarker(guest.host.name)
                ));
            }
            LaunchQemuGuestsEvent::NoQemuGuestsToRun => {
                ui.print_info("No QEMU guests found to run.");
            }
            LaunchQemuGuestsEvent::Error(e) => {
                ui.print_error(e);
            }
        },
    );
}

fn handle_list(args: ListArgs, ctx: &mut Ctx, ui: &mut TermUi) {
    let headers = vec!["Host", "Variant", "Tags"];
    let mut rows = Vec::new();

    let reporter = |_ctx: &mut Ctx, event: ListQemuGuestsEvent<'_>| match event {
        ListQemuGuestsEvent::Guest(guest) => {
            let tags = guest.host.data.tags.join(", ");
            rows.push(vec![
                guest.host.name.to_string(),
                guest._variant_name.to_string(),
                tags,
            ]);
        }
        ListQemuGuestsEvent::Error(err) => {
            ui.print_error(err);
        }
        ListQemuGuestsEvent::NoMatchingGuests => {
            ui.print_info("No QEMU guests found.");
        }
    };

    let Ok(_) = list_qemu_guests(&<[String; 0]>::default(), &args.tags, ctx, reporter) else {
        return;
    };

    if !rows.is_empty() {
        ui.print_table(headers, rows);
    }
}

fn handle_show(args: ShowArgs, ctx: &mut Ctx, ui: &mut TermUi) {
    let _ = show_qemu_guest(
        &args.host,
        ctx,
        |_: &mut Ctx, event: ShowQemuGuestEvent<'_>| match event {
            ShowQemuGuestEvent::Guest(guest) => {
                let headers = vec!["Property", "Value"];
                let mut rows = Vec::new();

                rows.push(vec!["Host".to_string(), guest.host.name.to_string()]);
                rows.push(vec!["Variant".to_string(), guest._variant_name.to_string()]);

                let mut pf_strs = Vec::new();
                for pf in &guest.data.port_forwards {
                    let proto = match pf.proto {
                        alloy_core::domain::models::L4Proto::Tcp => "tcp",
                        alloy_core::domain::models::L4Proto::Udp => "udp",
                    };
                    pf_strs.push(format!(
                        "{}: {} -> {} ({})",
                        pf.name, pf.hypervisor, pf.guest, proto
                    ));
                }

                rows.push(vec!["Port Forwards".to_string(), pf_strs.join("\n")]);

                let mut nets_strs = Vec::new();
                for (net, qemu_net) in &guest.data.nets {
                    nets_strs.push(format!("{}: {:?}", net, qemu_net));
                }

                rows.push(vec!["Networks".to_string(), nets_strs.join("\n")]);

                ui.print_table(headers, rows);
            }
            ShowQemuGuestEvent::Error(err) => {
                ui.print_error(err);
            }
        },
    );
}
