use std::collections::HashMap;
use std::collections::HashSet;

use either::Either;
use itertools::Itertools;

use crate::domain::DynError;
use crate::domain::hosts::FindHostError;
use crate::domain::ports::Ctx;
use crate::domain::ports::Reporter;
use crate::domain::state::LoadStateError;
use crate::domain::state::load_state;
use crate::domain::{
    NameMarker,
    hosts::Host,
    indexes::{FindIndexError, Index, ReadIndexError},
    models,
};

#[derive(Debug, Clone)]
pub struct QemuOpts<'s> {
    pub data: &'s models::Qemu,
    pub(crate) net_index: HashMap<String, u64>,
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindQemuOptsError {
    #[error("Not found")]
    NotFound,

    #[error("Failed to find qemu-nets index")]
    NoNetIndex(#[from] FindIndexError),

    #[error("Failed to read qemu-nets index")]
    ReadNetIndex(#[from] ReadIndexError),

    #[error("qemu-net index has no allocated values for networks: {}", nets.iter().map(String::as_str).map(NameMarker).join(", "))]
    NoNetIdx { nets: Vec<String> },
}

impl<'s> QemuOpts<'s> {
    pub fn net_index(&self) -> &HashMap<String, u64> {
        &self.net_index
    }

    pub fn find(state: &'s models::State, ctx: &dyn Ctx) -> Result<Self, FindQemuOptsError> {
        let Some(data) = &state.qemu else {
            return Err(FindQemuOptsError::NotFound);
        };

        let net_index = Index::find("qemu-nets", state)?;
        let net_index = net_index.read(ctx)?;

        let mut nets_without_idx = Vec::new();
        for (net, _) in &data.nets {
            if net_index.get(net).is_none() {
                nets_without_idx.push(net.clone());
            }
        }

        if !nets_without_idx.is_empty() {
            return Err(FindQemuOptsError::NoNetIdx {
                nets: nets_without_idx,
            });
        }

        Ok(QemuOpts {
            data,
            net_index,
            _priv: (),
        })
    }
}

pub struct QemuGuest<'s> {
    pub opts: &'s QemuOpts<'s>,
    pub host: &'s Host<'s>,
    pub data: &'s models::QemuGuest,
    pub variant: &'s models::QemuVariant,
    pub _variant_name: &'s str,
    _priv: (),
}

#[derive(thiserror::Error, Debug)]
pub enum FindQemuGuestError {
    #[error("Not found")]
    NotFound,

    #[error("Primary qemu guest variant is not configured for the host")]
    VariantNotSet,

    #[error("Primary qemu guest variant {name} is not specified for the host")]
    VariantNotConfigured { name: String },

    #[error("Networks {} of the qemu guest are not defined in global qemu options", nets.join(", "))]
    NoNets { nets: Vec<String> },
}

impl<'s> QemuGuest<'s> {
    pub fn find(opts: &'s QemuOpts<'s>, host: &'s Host<'s>) -> Result<Self, FindQemuGuestError> {
        let Some(data) = &host.data.qemu else {
            return Err(FindQemuGuestError::NotFound);
        };

        let Some(variant_name) = &data.variant else {
            return Err(FindQemuGuestError::VariantNotSet);
        };

        let Some(variant) = data.variants.get(variant_name) else {
            return Err(FindQemuGuestError::VariantNotConfigured {
                name: variant_name.clone(),
            });
        };

        Ok(QemuGuest {
            opts,
            host,
            data,
            _variant_name: variant_name,
            variant,
            _priv: (),
        })
    }
}

#[derive(thiserror::Error, Debug)]
pub enum LaunchQemuGuestsError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find host {}", NameMarker(&host_name))]
    FindHost {
        host_name: String,
        #[source]
        source: FindHostError,
    },

    #[error(transparent)]
    FindQemuOpts(#[from] FindQemuOptsError),

    #[error("Failed to find QEMU guest for host {}", NameMarker(&host_name))]
    FindQemuGuest {
        host_name: String,
        #[source]
        source: FindQemuGuestError,
    },

    #[error("Failed to start VDE switch for net {}", NameMarker(&net))]
    VdeStart {
        net: String,
        #[source]
        source: DynError,
    },

    #[error("Failed to stop VDE switch for net {}", NameMarker(&net))]
    VdeStop { net: String, source: DynError },

    #[error("Failed to launch QEMU guest {guest_name}")]
    QemuLaunch {
        guest_name: String,
        #[source]
        source: DynError,
    },

    #[error("Failed to wait for QEMU guest {guest_name}")]
    QemuWait {
        guest_name: String,
        #[source]
        source: DynError,
    },
}

pub enum LaunchQemuGuestsEvent<'s> {
    LaunchVdeSwitch { net_name: &'s str },

    StopVdeSwitch { net_name: &'s str },

    LaunchQemuGuest(&'s QemuGuest<'s>),

    StopQemuGuest(&'s QemuGuest<'s>),

    NoQemuGuestsToRun,

    Error(&'s LaunchQemuGuestsError),
}

fn has_intersection(slice: &[impl AsRef<str>], vec: &Vec<String>) -> bool {
    slice
        .iter()
        .any(|slice_item| vec.iter().any(|vec_item| vec_item == slice_item.as_ref()))
}

pub fn launch_qemu_guests<C: Ctx>(
    host_names: &[impl AsRef<str>],
    tags: &[impl AsRef<str>],
    ctx: &mut C,
    mut reporter: impl for<'s> Reporter<C, LaunchQemuGuestsEvent<'s>>,
) -> Result<(), Vec<LaunchQemuGuestsError>> {
    let state = load_state(true, ctx)
        .map_err(LaunchQemuGuestsError::Load)
        .map_err(|err| {
            reporter.report(ctx, LaunchQemuGuestsEvent::Error(&err));
            vec![err]
        })?;
    let mut errors = Vec::new();

    let opts = match QemuOpts::find(&state, ctx) {
        Ok(opts) => opts,
        Err(source) => {
            let err = LaunchQemuGuestsError::FindQemuOpts(source);
            reporter.report(ctx, LaunchQemuGuestsEvent::Error(&err));
            return Err(vec![err]);
        }
    };

    let hosts: Vec<_> = if host_names.is_empty() {
        Either::Left(
            state
                .hosts
                .iter()
                .filter(|(_, host)| host.qemu.is_some())
                .map(|(name, _)| name.as_str()),
        )
    } else {
        Either::Right(host_names.into_iter().map(AsRef::as_ref))
    }
    .filter_map(|name| {
        Host::find(name, &state)
            .map_err(|source| LaunchQemuGuestsError::FindHost {
                host_name: name.to_string(),
                source,
            })
            .map_err(|err| {
                reporter.report(ctx, LaunchQemuGuestsEvent::Error(&err));
                errors.push(err);
            })
            .ok()
    })
    .filter(|secret| tags.is_empty() || has_intersection(tags, &secret.data.tags))
    .collect();

    if !errors.is_empty() {
        return Err(errors);
    }

    let guests: Vec<_> = hosts
        .iter()
        .filter_map(|host| {
            QemuGuest::find(&opts, host)
                .map_err(|source| LaunchQemuGuestsError::FindQemuGuest {
                    host_name: host.name.to_string(),
                    source,
                })
                .map_err(|err| {
                    reporter.report(ctx, LaunchQemuGuestsEvent::Error(&err));
                    errors.push(err);
                })
                .ok()
        })
        .collect();

    if guests.is_empty() {
        reporter.report(ctx, LaunchQemuGuestsEvent::NoQemuGuestsToRun);
        return Ok(());
    }

    let mut unique_nets = HashSet::new();
    for guest in &guests {
        for (net, _) in &guest.data.nets {
            unique_nets.insert(net);
        }
    }

    let cache_dir = ctx.env().cache_dir.join(&state.name);

    let mut vde_switches = Vec::new();
    for net in unique_nets {
        let net_idx = &opts.net_index[net];
        match ctx.qemu_runner().create_vde(&cache_dir, *net_idx) {
            Ok(switch) => {
                reporter.report(
                    ctx,
                    LaunchQemuGuestsEvent::LaunchVdeSwitch { net_name: net },
                );
                vde_switches.push((net.as_str(), switch));
            }
            Err(source) => {
                let err = LaunchQemuGuestsError::VdeStart {
                    net: net.to_string(),
                    source,
                };
                reporter.report(ctx, LaunchQemuGuestsEvent::Error(&err));
                errors.push(err);
                continue;
            }
        };
    }

    if !errors.is_empty() {
        for (net, switch) in vde_switches {
            if let Err(source) = switch.stop() {
                let err = LaunchQemuGuestsError::VdeStop {
                    net: net.to_string(),
                    source,
                };
                reporter.report(ctx, LaunchQemuGuestsEvent::Error(&err));
                errors.push(err);
            } else {
                reporter.report(ctx, LaunchQemuGuestsEvent::StopVdeSwitch { net_name: net });
            }
        }
        return Err(errors);
    }

    let mut qemu_processes = Vec::new();
    for guest in guests {
        let state_source = ctx.env().state_source.as_ref().unwrap();

        match ctx.qemu_runner().launch_guest(
            guest.host.name,
            &cache_dir,
            &state_source.dir().join(&guest.variant.script_path),
            &mut vde_switches.iter().map(|s| s.1.as_ref()),
        ) {
            Ok(proc) => {
                reporter.report(ctx, LaunchQemuGuestsEvent::LaunchQemuGuest(&guest));
                qemu_processes.push((guest, proc));
            }
            Err(source) => {
                let err = LaunchQemuGuestsError::QemuLaunch {
                    guest_name: guest.host.name.to_string(),
                    source,
                };
                reporter.report(ctx, LaunchQemuGuestsEvent::Error(&err));
                errors.push(err);
                continue;
            }
        };
    }

    for (guest, proc) in qemu_processes {
        if let Err(source) = proc.wait() {
            let err = LaunchQemuGuestsError::QemuWait {
                guest_name: guest.host.name.to_string(),
                source,
            };
            reporter.report(ctx, LaunchQemuGuestsEvent::Error(&err));
            errors.push(err);
        } else {
            reporter.report(ctx, LaunchQemuGuestsEvent::StopQemuGuest(&guest));
        }
    }

    for (net, switch) in vde_switches {
        if let Err(source) = switch.stop() {
            let err = LaunchQemuGuestsError::VdeStop {
                net: net.to_string(),
                source,
            };
            reporter.report(ctx, LaunchQemuGuestsEvent::Error(&err));
            errors.push(err);
        } else {
            reporter.report(ctx, LaunchQemuGuestsEvent::StopVdeSwitch { net_name: net });
        }
    }

    if !errors.is_empty() {
        Err(errors)
    } else {
        Ok(())
    }
}

#[derive(thiserror::Error, Debug)]
pub enum ShowQemuGuestError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find host {}", NameMarker(&host_name))]
    FindHost {
        host_name: String,
        #[source]
        source: FindHostError,
    },

    #[error(transparent)]
    FindQemuOpts(#[from] FindQemuOptsError),

    #[error("Failed to find QEMU guest for host {}", NameMarker(&host_name))]
    FindQemuGuest {
        host_name: String,
        #[source]
        source: FindQemuGuestError,
    },
}

pub enum ShowQemuGuestEvent<'s> {
    Guest(&'s QemuGuest<'s>),
    Error(&'s ShowQemuGuestError),
}

pub fn show_qemu_guest<C: Ctx>(
    host_name: &str,
    ctx: &mut C,
    mut reporter: impl for<'s> Reporter<C, ShowQemuGuestEvent<'s>>,
) -> Result<(), ShowQemuGuestError> {
    let state = load_state(true, ctx)
        .map_err(ShowQemuGuestError::Load)
        .map_err(|err| {
            reporter.report(ctx, ShowQemuGuestEvent::Error(&err));
            err
        })?;

    let opts = match QemuOpts::find(&state, ctx) {
        Ok(opts) => opts,
        Err(source) => {
            let err = ShowQemuGuestError::FindQemuOpts(source);
            reporter.report(ctx, ShowQemuGuestEvent::Error(&err));
            return Err(err);
        }
    };

    let host = match Host::find(host_name, &state) {
        Ok(host) => host,
        Err(source) => {
            let err = ShowQemuGuestError::FindHost {
                host_name: host_name.to_string(),
                source,
            };
            reporter.report(ctx, ShowQemuGuestEvent::Error(&err));
            return Err(err);
        }
    };

    let guest = match QemuGuest::find(&opts, &host) {
        Ok(guest) => guest,
        Err(source) => {
            let err = ShowQemuGuestError::FindQemuGuest {
                host_name: host_name.to_string(),
                source,
            };
            reporter.report(ctx, ShowQemuGuestEvent::Error(&err));
            return Err(err);
        }
    };

    reporter.report(ctx, ShowQemuGuestEvent::Guest(&guest));

    Ok(())
}

#[derive(thiserror::Error, Debug)]
pub enum ListQemuGuestsError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find host {}", NameMarker(&host_name))]
    FindHost {
        host_name: String,
        #[source]
        source: FindHostError,
    },

    #[error(transparent)]
    FindQemuOpts(#[from] FindQemuOptsError),

    #[error("Failed to find QEMU guest for host {}", NameMarker(&host_name))]
    FindQemuGuest {
        host_name: String,
        #[source]
        source: FindQemuGuestError,
    },
}

pub enum ListQemuGuestsEvent<'s> {
    Guest(&'s QemuGuest<'s>),
    Error(&'s ListQemuGuestsError),
    NoMatchingGuests,
}

pub fn list_qemu_guests<C: Ctx>(
    host_names: &[impl AsRef<str>],
    tags: &[impl AsRef<str>],
    ctx: &mut C,
    mut reporter: impl for<'s> Reporter<C, ListQemuGuestsEvent<'s>>,
) -> Result<(), Vec<ListQemuGuestsError>> {
    let state = load_state(true, ctx)
        .map_err(ListQemuGuestsError::Load)
        .map_err(|err| {
            reporter.report(ctx, ListQemuGuestsEvent::Error(&err));
            vec![err]
        })?;
    let mut errors = Vec::new();

    let opts = match QemuOpts::find(&state, ctx) {
        Ok(opts) => opts,
        Err(source) => {
            let err = ListQemuGuestsError::FindQemuOpts(source);
            reporter.report(ctx, ListQemuGuestsEvent::Error(&err));
            return Err(vec![err]);
        }
    };

    let hosts: Vec<_> = if host_names.is_empty() {
        Either::Left(
            state
                .hosts
                .iter()
                .filter(|(_, host)| host.qemu.is_some())
                .map(|(name, _)| name.as_str()),
        )
    } else {
        Either::Right(host_names.into_iter().map(AsRef::as_ref))
    }
    .filter_map(|name| {
        Host::find(name, &state)
            .map_err(|source| ListQemuGuestsError::FindHost {
                host_name: name.to_string(),
                source,
            })
            .map_err(|err| {
                reporter.report(ctx, ListQemuGuestsEvent::Error(&err));
                errors.push(err);
            })
            .ok()
    })
    .filter(|secret| tags.is_empty() || has_intersection(tags, &secret.data.tags))
    .collect();

    if !errors.is_empty() {
        return Err(errors);
    }

    let guests: Vec<_> = hosts
        .iter()
        .filter_map(|host| {
            QemuGuest::find(&opts, host)
                .map_err(|source| ListQemuGuestsError::FindQemuGuest {
                    host_name: host.name.to_string(),
                    source,
                })
                .map_err(|err| {
                    reporter.report(ctx, ListQemuGuestsEvent::Error(&err));
                    errors.push(err);
                })
                .ok()
        })
        .collect();

    if guests.is_empty() {
        reporter.report(ctx, ListQemuGuestsEvent::NoMatchingGuests);
        return Ok(());
    }

    for guest in guests {
        reporter.report(ctx, ListQemuGuestsEvent::Guest(&guest));
    }

    Ok(())
}
