use crate::lib::state::State;

mod age;
pub mod host;
pub mod jail;
pub mod master;

#[derive(Default)]
pub struct Collection<'s> {
    pub host_secrets: Vec<(&'s String, &'s String)>,
    pub jail_secrets: Vec<(&'s String, &'s String)>,
}

pub fn collect<'s>(
    state: &'s State,
    secrets: &[String],
    hosts: &[String],
    jails: &[String],
    tags: &[String],
) -> Collection<'s> {
    let mut plan = Collection::default();

    for (host_name, host_state) in &state.hosts {
        if !hosts.is_empty() && !hosts.contains(host_name) {
            continue;
        }

        for (secret_name, _) in &host_state.secrets {
            if !secrets.is_empty() && !secrets.contains(secret_name) {
                continue;
            }

            if let Some(master) = state.secrets.get(secret_name) {
                if !tags.is_empty() && !master.tags.iter().any(|t| tags.contains(t)) {
                    continue;
                }
            }

            plan.host_secrets.push((host_name, secret_name));
        }
    }

    for (jail_name, jail_state) in &state.jails {
        if !jails.is_empty() && !jails.contains(jail_name) {
            continue;
        }

        for (secret_name, _) in &jail_state.secrets {
            if !secrets.is_empty() && !secrets.contains(secret_name) {
                continue;
            }

            if let Some(master) = state.secrets.get(secret_name) {
                if !tags.is_empty() && !master.tags.iter().any(|t| tags.contains(t)) {
                    continue;
                }
            }

            plan.jail_secrets.push((jail_name, secret_name));
        }
    }

    plan
}
