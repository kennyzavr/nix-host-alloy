use itertools::{Either, Itertools};
use petgraph::{
    algo::{tarjan_scc, toposort},
    graph::DiGraph,
};

use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;
use std::path::Path;

use crate::domain::{
    DynError, NameMarker,
    facts::{Fact, FindFactError, ReadFactError, WriteFactError},
    models,
    ports::{NixBuildGensSpec, NixBuildSpec},
    state::reset_state,
};
use crate::domain::{
    ports::{Ctx, Reporter},
    state::{LoadStateError, load_state},
};

#[derive(Debug, Clone)]
pub struct Gen<'s> {
    pub name: &'s str,
    pub data: &'s models::Gen,
    pub(crate) secret_files: Vec<&'s Path>,
    pub(crate) fact_files: Vec<&'s Path>,
    _priv: (),
}

#[derive(Debug, Clone, Copy)]
pub enum GenRefKind {
    Wants,
    After,
    Secret,
    Fact,
}

impl fmt::Display for GenRefKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GenRefKind::Wants => write!(f, "wants"),
            GenRefKind::After => write!(f, "after"),
            GenRefKind::Secret => write!(f, "secret"),
            GenRefKind::Fact => write!(f, "fact"),
        }
    }
}

#[derive(thiserror::Error, Debug)]
pub enum FindGenError {
    #[error("Not found")]
    NotFound,

    #[error("Invalid references: {}", refs.iter().map(|(kind, name)| format!("{kind} {}", NameMarker(&name))).join(", ") )]
    InvalidRefs { refs: Vec<(GenRefKind, String)> },
}

#[derive(Debug, thiserror::Error)]
pub enum ExecGenError {
    #[error("Generator has no evaluated script")]
    NoScript,

    #[error("Failed to run generator script in the local env")]
    Runner(#[from] DynError),

    #[error("Generator has no evaluated fingerprint")]
    NoFingerprint,

    #[error("Generator fingerprint fact not found")]
    FindFingerprintFact(#[from] FindFactError),

    #[error("Failed to write generator fingerprint fact")]
    WriteFingerprintFact(#[from] WriteFactError),
}

#[derive(Debug, thiserror::Error)]
pub enum IsStaleError {
    #[error("Generator has no evaluated fingerprint")]
    NoFingerprint,

    #[error("Generator fingerprint fact not found")]
    FindFingerprintFact(#[from] FindFactError),

    #[error("Generator fingerprint fact has no value")]
    ReadFingerprintFact(#[from] ReadFactError),
}

impl<'s> Gen<'s> {
    pub fn find(name: &'s str, state: &'s models::State) -> Result<Gen<'s>, FindGenError> {
        let data = state.gens.get(name).ok_or(FindGenError::NotFound)?;

        let mut invalid_refs = Vec::new();

        for wanted_gen in &data.wants {
            let Some(_) = state.gens.get(wanted_gen) else {
                invalid_refs.push((GenRefKind::Wants, wanted_gen.clone()));
                continue;
            };
        }

        for after_gen in &data.after {
            let Some(_) = state.gens.get(after_gen) else {
                invalid_refs.push((GenRefKind::After, after_gen.clone()));
                continue;
            };
        }

        let mut secret_files = Vec::new();
        for secret_name in &data.secrets {
            let Some(secret) = &state.secrets.get(secret_name) else {
                invalid_refs.push((GenRefKind::Secret, secret_name.clone()));
                continue;
            };
            secret_files.push(secret.file.as_path());
        }

        let mut fact_files = Vec::new();
        for fact_name in &data.facts {
            let Some(fact) = &state.facts.get(fact_name) else {
                invalid_refs.push((GenRefKind::Fact, fact_name.clone()));
                continue;
            };
            fact_files.push(fact.file.as_path());
        }

        if !invalid_refs.is_empty() {
            Err(FindGenError::InvalidRefs { refs: invalid_refs })
        } else {
            Ok(Self {
                name,
                data,
                secret_files,
                fact_files,
                _priv: (),
            })
        }
    }

    pub fn exec(
        &self,
        state: &models::State,
        force: Option<bool>,
        add_to_git: Option<bool>,
        ctx: &mut dyn Ctx,
    ) -> Result<bool, ExecGenError> {
        let Some(script_path) = &self.data.script_path else {
            return Err(ExecGenError::NoScript);
        };

        let Some(fingerprint) = &self.data.fingerprint else {
            return Err(ExecGenError::NoFingerprint);
        };

        let state_source = ctx
            .env()
            .state_source
            .as_ref()
            .expect("Gen::exec must be called after state load");

        let env = ctx.env();

        let facts_exist = self
            .fact_files
            .iter()
            .all(|f| ctx.fs().exists(&env.workspace_root.join(f)));
        let secrets_exist = self
            .secret_files
            .iter()
            .all(|s| ctx.fs().exists(&env.workspace_root.join(s)));

        if !matches!(force, Some(true)) && facts_exist && secrets_exist {
            return Ok(false);
        }

        let script_path = state_source.dir_path.join(script_path);
        let force = force.or(ctx.env().force).unwrap_or(false);
        let add_to_git = add_to_git.or(ctx.env().add_to_git).unwrap_or(false);

        ctx.gen_runner()
            .exec_gen(&script_path, force, add_to_git, ctx.env())
            .map_err(ExecGenError::Runner)?;

        Fact::find(&self.data.fingerprint_fact, state)?.write(
            fingerprint,
            Some(true),
            Some(add_to_git),
            ctx,
        )?;

        Ok(true)
    }

    pub fn is_stale(
        &self,
        state: &'s models::State,
        ctx: &mut dyn Ctx,
    ) -> Result<bool, IsStaleError> {
        let fingerprint = self
            .data
            .fingerprint
            .as_ref()
            .ok_or(IsStaleError::NoFingerprint)?;

        let fingerprint_fact = Fact::find(&self.data.fingerprint_fact, state)?;
        if !fingerprint_fact.exists(ctx) {
            return Ok(true);
        }

        let prev_fingerprint = fingerprint_fact.read(ctx)?;

        Ok(fingerprint != &prev_fingerprint)
    }
}

#[derive(thiserror::Error, Debug)]
pub enum ExecGensError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find gen {}", NameMarker(&gen_name))]
    FindGen {
        gen_name: String,
        #[source]
        source: FindGenError,
    },

    #[error("Generators have dependency cycle: {}", gen_names.join(" -> "))]
    Cycle { gen_names: Vec<String> },

    #[error("Failed to execute generator {}", NameMarker(&gen_name))]
    Exec {
        gen_name: String,
        #[source]
        source: ExecGenError,
    },

    #[error("Failed to check is generator {} stale", NameMarker(&gen_name))]
    IsStale {
        gen_name: String,
        #[source]
        source: IsStaleError,
    },
}

pub enum ExecGensEvent<'s> {
    GenExec { r#gen: &'s Gen<'s> },

    GenSkip { r#gen: &'s Gen<'s>, is_stale: bool },

    Error(&'s ExecGensError),
}

fn has_intersection(slice: &[impl AsRef<str>], vec: &Vec<String>) -> bool {
    slice
        .iter()
        .any(|slice_item| vec.iter().any(|vec_item| vec_item == slice_item.as_ref()))
}

pub fn exec_gens<C: Ctx>(
    gen_names: &[impl AsRef<str>],
    tags: &[impl AsRef<str>],
    force: Option<bool>,
    force_stale: Option<bool>,
    add_to_git: Option<bool>,
    ctx: &mut C,
    mut reporter: impl for<'s> Reporter<C, ExecGensEvent<'s>>,
) -> Result<(), Vec<ExecGensError>> {
    let mut cache = HashSet::new();

    'l: loop {
        let state = load_state(
            NixBuildSpec {
                generators: NixBuildGensSpec {
                    build_scripts: true,
                    calc_fingerprint: true,
                },
                ..Default::default()
            },
            ctx,
        )
        .map_err(ExecGensError::Load)
        .map_err(|err| {
            reporter.report(ctx, ExecGensEvent::Error(&err));
            vec![err]
        })?;

        let plan = match build_exec_plan(gen_names, tags, &state) {
            Ok(plan) => plan,
            Err(errors) => {
                errors.iter().for_each(|err| {
                    reporter.report(ctx, ExecGensEvent::Error(&err));
                });
                return Err(errors);
            }
        };

        let mut errors = vec![];
        let mut exec_triggered = false;
        for r#gen in plan {
            if cache.contains(r#gen.name) {
                continue;
            }

            if r#gen.data.script_path.is_none() && !exec_triggered {
                let error = ExecGensError::Exec {
                    gen_name: r#gen.name.to_string(),
                    source: ExecGenError::NoScript,
                };

                reporter.report(ctx, ExecGensEvent::Error(&error));
                errors.push(error);

                let _ = ctx.nix().build_gen_package(r#gen.name, ctx.env().into());

                continue;
            }

            if r#gen.data.script_path.is_none() {
                reset_state(ctx);
                continue 'l;
            }

            let is_stale = match r#gen.is_stale(&state, ctx) {
                Ok(v) => v,
                Err(source) => {
                    let err = ExecGensError::IsStale {
                        gen_name: r#gen.name.to_string(),
                        source,
                    };
                    reporter.report(ctx, ExecGensEvent::Error(&err));
                    return Err(vec![err]);
                }
            };

            reporter.report(ctx, ExecGensEvent::GenExec { r#gen: &r#gen });
            match r#gen.exec(
                &state,
                force.or(is_stale.then_some(force_stale).flatten()),
                add_to_git,
                ctx,
            ) {
                Ok(true) => {}
                Ok(false) => {
                    reporter.report(
                        ctx,
                        ExecGensEvent::GenSkip {
                            r#gen: &r#gen,
                            is_stale,
                        },
                    );
                }
                Err(error) => {
                    let error = ExecGensError::Exec {
                        gen_name: r#gen.name.to_string(),
                        source: error,
                    };
                    reporter.report(ctx, ExecGensEvent::Error(&error));
                    return Err(vec![error]);
                }
            }

            exec_triggered = true;
            cache.insert(r#gen.name.to_string());
        }

        if !errors.is_empty() {
            return Err(errors);
        }

        break;
    }

    Ok(())
}

fn build_exec_plan<'s>(
    gen_names: &[impl AsRef<str>],
    tags: &[impl AsRef<str>],
    state: &'s models::State,
) -> Result<Vec<Gen<'s>>, Vec<ExecGensError>> {
    let mut errors = Vec::new();

    let gen_names: Vec<_> = if gen_names.is_empty() {
        Either::Left(state.gens.keys().into_iter().map(String::as_str))
    } else {
        Either::Right(gen_names.into_iter().map(AsRef::as_ref))
    }
    .filter_map(|gen_name| match state.gens.get(gen_name) {
        Some(r#gen) => Some((gen_name, r#gen)),
        None => {
            let error = ExecGensError::FindGen {
                gen_name: gen_name.to_string(),
                source: FindGenError::NotFound,
            };
            errors.push(error);
            None
        }
    })
    .filter(|(_, r#gen)| tags.is_empty() || has_intersection(tags, &r#gen.tags))
    .map(|(gen_name, _)| gen_name)
    .collect();

    let mut gens: HashMap<_, _> = state
        .gens
        .keys()
        .map(String::as_str)
        .filter_map(|name| {
            Gen::find(name, &state)
                .map_err(|source| ExecGensError::FindGen {
                    gen_name: name.to_string(),
                    source,
                })
                .map_err(|err| {
                    errors.push(err);
                })
                .ok()
        })
        .map(|g| (g.name, g))
        .collect();

    if !errors.is_empty() {
        return Err(errors);
    }

    let mut active_gens = HashSet::<&str>::with_capacity(gens.len());
    let mut gens_queue = VecDeque::<&str>::with_capacity(gens.len());

    gens_queue.extend(gen_names.iter().map(|v| *v));
    while let Some(gen_name) = gens_queue.pop_back() {
        if !active_gens.insert(gen_name) {
            continue;
        }

        for wanted_gen_name in &gens[gen_name].data.wants {
            if !active_gens.contains(wanted_gen_name.as_str()) {
                gens_queue.push_front(wanted_gen_name.as_str());
            }
        }
    }

    let mut graph = DiGraph::<&str, ()>::new();
    let mut nodes = HashMap::<&str, _>::new();
    for active_gen_name in &active_gens {
        let gen_node = graph.add_node(active_gen_name);
        nodes.insert(active_gen_name, gen_node);
    }

    for &active_gen_name in &active_gens {
        let r#gen = &gens[active_gen_name];
        let node = nodes[active_gen_name];

        for after in &r#gen.data.after {
            graph.add_edge(nodes[after.as_str()], node, ());
        }

        for wanted in &r#gen.data.wants {
            graph.add_edge(nodes[wanted.as_str()], node, ());
        }
    }

    let Ok(order) = toposort(&graph, None) else {
        let cycles = tarjan_scc(&graph)
            .into_iter()
            .filter(|cycle_nodes| {
                cycle_nodes.len() > 1
                    || (cycle_nodes.len() == 1
                        && graph.contains_edge(cycle_nodes[0], cycle_nodes[0]))
            })
            .map(|cycle_nodes| {
                cycle_nodes
                    .into_iter()
                    .map(|n| graph[n].to_string())
                    .collect::<Vec<_>>()
            })
            .collect::<Vec<_>>();

        for cycle in cycles {
            let err = ExecGensError::Cycle { gen_names: cycle };
            errors.push(err);
        }

        debug_assert!(errors.len() > 0);
        return Err(errors);
    };

    if !errors.is_empty() {
        Err(errors)
    } else {
        Ok(order
            .into_iter()
            .map(|idx| graph[idx])
            .map(|gen_name| gens.remove(gen_name).unwrap())
            .collect())
    }
}

#[derive(thiserror::Error, Debug)]
pub enum ShowGenError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find generator {}", NameMarker(&gen_name))]
    FindGen {
        gen_name: String,
        #[source]
        source: FindGenError,
    },

    #[error("Failed to check is generator {} is stale", NameMarker(&gen_name))]
    IsGenStale {
        gen_name: String,
        #[source]
        source: IsStaleError,
    },

    #[error("Generator {} has no evaluated script", NameMarker(&gen_name))]
    NoScript { gen_name: String },
}

pub enum ShowGenEvent<'s> {
    Gen { r#gen: &'s Gen<'s>, is_stale: bool },
    Error(&'s ShowGenError),
}

pub fn show_gen<C: Ctx>(
    gen_name: &str,
    ctx: &mut C,
    mut reporter: impl for<'s> Reporter<C, ShowGenEvent<'s>>,
) -> Result<(), ShowGenError> {
    let state = load_state(
        NixBuildSpec {
            generators: NixBuildGensSpec {
                build_scripts: true,
                calc_fingerprint: true,
            },
            ..Default::default()
        },
        ctx,
    )
    .map_err(ShowGenError::Load)
    .map_err(|err| {
        reporter.report(ctx, ShowGenEvent::Error(&err));
        err
    })?;

    let r#gen = Gen::find(gen_name, &state)
        .map_err(|source| ShowGenError::FindGen {
            gen_name: gen_name.to_string(),
            source,
        })
        .inspect_err(|err| {
            reporter.report(ctx, ShowGenEvent::Error(&err));
        })?;

    if r#gen.data.script_path.is_none() {
        let error = ShowGenError::NoScript {
            gen_name: r#gen.name.to_string(),
        };

        reporter.report(ctx, ShowGenEvent::Error(&error));
        let _ = ctx.nix().build_gen_package(r#gen.name, ctx.env().into());

        return Err(error);
    }

    let is_stale = r#gen.is_stale(&state, ctx).map_err(|source| {
        let err = ShowGenError::IsGenStale {
            gen_name: r#gen.name.to_string(),
            source,
        };
        reporter.report(ctx, ShowGenEvent::Error(&err));
        err
    })?;

    reporter.report(
        ctx,
        ShowGenEvent::Gen {
            r#gen: &r#gen,
            is_stale,
        },
    );
    Ok(())
}

#[derive(thiserror::Error, Debug)]
pub enum ListGensError {
    #[error(transparent)]
    Load(#[from] LoadStateError),

    #[error("Failed to find generator {}", NameMarker(&gen_name))]
    FindGen {
        gen_name: String,
        #[source]
        source: FindGenError,
    },

    #[error("Failed to check is generator {} is stale", NameMarker(&gen_name))]
    IsGenStale {
        gen_name: String,
        #[source]
        source: IsStaleError,
    },

    #[error("Generator {} has no evaluated script", NameMarker(&gen_name))]
    NoScript { gen_name: String },
}

pub enum ListGensEvent<'s> {
    Gen { r#gen: &'s Gen<'s>, is_stale: bool },
    Error(&'s ListGensError),
    NoMatchingGens,
}

pub fn list_gens<C: Ctx>(
    gen_names: &[impl AsRef<str>],
    tags: &[impl AsRef<str>],
    ctx: &mut C,
    mut reporter: impl for<'s> Reporter<C, ListGensEvent<'s>>,
) -> Result<(), Vec<ListGensError>> {
    let state = load_state(
        NixBuildSpec {
            generators: NixBuildGensSpec {
                build_scripts: true,
                calc_fingerprint: true,
            },
            ..Default::default()
        },
        ctx,
    )
    .map_err(ListGensError::Load)
    .map_err(|err| {
        reporter.report(ctx, ListGensEvent::Error(&err));
        vec![err]
    })?;
    let mut errors = Vec::new();

    let gens: Vec<_> = if gen_names.is_empty() {
        Either::Left(state.gens.keys().map(String::as_str))
    } else {
        Either::Right(gen_names.into_iter().map(AsRef::as_ref))
    }
    .filter_map(|name| {
        Gen::find(name, &state)
            .map_err(|source| ListGensError::FindGen {
                gen_name: name.to_string(),
                source,
            })
            .map_err(|err| {
                reporter.report(ctx, ListGensEvent::Error(&err));
                errors.push(err);
            })
            .ok()
    })
    .filter(|g| tags.is_empty() || has_intersection(tags, &g.data.tags))
    .collect();

    if !errors.is_empty() {
        return Err(errors);
    }

    if gens.is_empty() {
        reporter.report(ctx, ListGensEvent::NoMatchingGens);
    }

    for r#gen in gens {
        if r#gen.data.script_path.is_none() {
            let error = ListGensError::NoScript {
                gen_name: r#gen.name.to_string(),
            };

            reporter.report(ctx, ListGensEvent::Error(&error));
            let _ = ctx.nix().build_gen_package(r#gen.name, ctx.env().into());

            continue;
        }

        let Some(is_stale) = r#gen
            .is_stale(&state, ctx)
            .map_err(|source| {
                let err = ListGensError::IsGenStale {
                    gen_name: r#gen.name.to_string(),
                    source,
                };
                reporter.report(ctx, ListGensEvent::Error(&err));
                errors.push(err);
            })
            .ok()
        else {
            continue;
        };

        reporter.report(
            ctx,
            ListGensEvent::Gen {
                r#gen: &r#gen,
                is_stale,
            },
        );
    }

    if !errors.is_empty() {
        return Err(errors);
    }

    Ok(())
}
