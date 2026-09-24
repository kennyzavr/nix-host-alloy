use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;

use petgraph::{
    algo::{tarjan_scc, toposort},
    graph::DiGraph,
};

use crate::ctx::Ctx;
use crate::{DynError, NameMark, NotDefinedError, models};

#[derive(Debug, Clone)]
pub struct Entity<'s> {
    pub name: &'s str,
    pub data: &'s models::Generator,
    pub secrets: Vec<&'s models::Secret>,
    pub facts: Vec<&'s models::Fact>,
    _priv: (),
}

#[derive(Debug, Clone, Copy)]
pub enum RefKind {
    Wants,
    After,
}

impl fmt::Display for RefKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RefKind::Wants => write!(f, "wants"),
            RefKind::After => write!(f, "after"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Pool<'s> {
    gens: HashMap<&'s str, Entity<'s>>,
}

impl<'s> Pool<'s> {
    pub fn get<'a>(&'a self, name: &'s str) -> Option<&'a Entity<'s>> {
        self.gens.get(name)
    }

    pub fn names(&self) -> impl Iterator<Item = &'s str> {
        self.gens.keys().map(|s| *s)
    }

    pub fn generators<'a>(&'a self) -> impl Iterator<Item = &'a Entity<'s>> {
        self.gens.values()
    }

    pub fn iter<'a>(&'a self) -> impl Iterator<Item = (&'s str, &'a Entity<'s>)> {
        self.gens.iter().map(|(name, data)| (*name, data))
    }
}

#[derive(thiserror::Error, Debug)]
pub enum FindError<'s> {
    #[error(transparent)]
    NotFound(#[from] NotDefinedError),

    #[error("Generator has invalid {kind} ref to {}", NameMark(ref_name))]
    InvalidRef { kind: RefKind, ref_name: &'s str },

    #[error("Invalid secret ref {}", NameMark(secret_name))]
    InvalidSecretRef { secret_name: &'s str },

    #[error("Invalid secret ref {}", NameMark(fact_name))]
    InvalidFactRef { fact_name: &'s str },
}

pub fn find<'s>(state: &'s models::State, name: &'s str) -> Result<Entity<'s>, FindError<'s>> {
    let data = state.generators.get(name).ok_or(NotDefinedError)?;

    for gen_ref in &data.wants {
        if !state.generators.get(gen_ref).is_none() {
            return Err(FindError::InvalidRef {
                kind: RefKind::Wants,
                ref_name: gen_ref,
            });
        }
    }

    for gen_ref in &data.after {
        if !state.generators.get(gen_ref).is_none() {
            return Err(FindError::InvalidRef {
                kind: RefKind::After,
                ref_name: gen_ref,
            });
        }
    }

    let mut secrets = Vec::new();
    for secret_name in &data.secrets {
        let Some(secret) = &state.secrets.get(secret_name) else {
            return Err(FindError::InvalidSecretRef { secret_name });
        };
        secrets.push(*secret);
    }

    let mut facts = Vec::new();
    for fact_name in &data.facts {
        let Some(fact) = &state.facts.get(fact_name) else {
            return Err(FindError::InvalidFactRef {
                fact_name: fact_name,
            });
        };
        facts.push(*fact);
    }

    Ok(Entity {
        name,
        data,
        facts,
        secrets,
        _priv: (),
    })
}

#[derive(thiserror::Error, Debug)]
pub enum FindAllError<'s> {
    #[error(
        "Generator {} has invalid {kind} ref to {}",
        NameMark(name),
        NameMark(ref_name)
    )]
    InvalidRef {
        name: &'s str,
        kind: RefKind,
        ref_name: &'s str,
    },

    #[error(
        "Generator {} has invalid secret ref {}",
        NameMark(name),
        NameMark(secret_name)
    )]
    InvalidSecretRef { name: &'s str, secret_name: &'s str },

    #[error(
        "Generator {} has invalid secret ref {}",
        NameMark(name),
        NameMark(fact_name)
    )]
    InvalidFactRef { name: &'s str, fact_name: &'s str },
}

pub fn find_all<'s>(state: &'s models::State) -> Result<Pool<'s>, Vec<FindAllError<'s>>> {
    let mut errors = Vec::new();
    let mut entities = HashMap::new();

    for (gen_name, gen_data) in &state.generators {
        for gen_ref in &gen_data.wants {
            if state.generators.get(gen_ref).is_none() {
                errors.push(FindAllError::InvalidRef {
                    name: gen_name,
                    kind: RefKind::Wants,
                    ref_name: gen_ref,
                })
            }
        }
        for gen_ref in &gen_data.after {
            if state.generators.get(gen_ref).is_none() {
                errors.push(FindAllError::InvalidRef {
                    name: gen_name,
                    kind: RefKind::After,
                    ref_name: gen_ref,
                })
            }
        }

        let mut secrets = Vec::new();
        for secret_name in &gen_data.secrets {
            let Some(secret) = &state.secrets.get(secret_name) else {
                errors.push(FindAllError::InvalidSecretRef {
                    name: gen_name,
                    secret_name,
                });
                continue;
            };
            secrets.push(*secret);
        }

        let mut facts = Vec::new();
        for fact_name in &gen_data.facts {
            let Some(fact) = &state.facts.get(fact_name) else {
                errors.push(FindAllError::InvalidFactRef {
                    name: gen_name,
                    fact_name: fact_name,
                });
                continue;
            };
            facts.push(*fact);
        }

        entities.insert(
            gen_name.as_str(),
            Entity {
                name: gen_name,
                data: gen_data,
                secrets,
                facts,
                _priv: (),
            },
        );
    }

    if !errors.is_empty() {
        return Err(errors);
    }

    Ok(Pool { gens: entities })
}

#[derive(Debug, thiserror::Error)]
pub enum PlanError<'s> {
    #[error("Generator {} not found in the pool", NameMark(&name))]
    NotFound { name: &'s str },

    #[error("Generators have dependency cycle: {}", gen_names.join(" -> "))]
    Cycle { gen_names: Vec<&'s str> },
}

pub fn plan_exec<'s>(
    pool: Pool<'s>,
    target_gens: &[&'s str],
) -> Result<Vec<&'s str>, Vec<PlanError<'s>>> {
    log::info!("Planning execution for {} target generators", target_gens.len());
    let mut errors = Vec::new();
    let gens = HashMap::<&str, Vec<&str>>::new();

    for &gen_name in target_gens {
        if pool.gens.get(gen_name).is_none() {
            errors.push(PlanError::NotFound { name: gen_name });
        }
    }

    if !errors.is_empty() {
        return Err(errors);
    }

    let mut active_gens = HashSet::<&str>::with_capacity(gens.len());
    let mut gens_queue = VecDeque::<&str>::with_capacity(gens.len());

    gens_queue.extend(target_gens);
    while let Some(gen_name) = gens_queue.pop_back() {
        if !active_gens.insert(gen_name) {
            continue;
        }

        if let Some(gen_wants) = gens.get(gen_name) {
            for wanted_name in gen_wants {
                if !active_gens.contains(*wanted_name) {
                    gens_queue.push_front(*wanted_name);
                }
            }
        }
    }

    let mut graph = DiGraph::<&str, ()>::new();
    let mut nodes = HashMap::<&str, _>::new();
    for active_gen in &active_gens {
        let gen_node = graph.add_node(active_gen);
        nodes.insert(active_gen, gen_node);
    }

    for &active_gen in &active_gens {
        let gen_state = &pool.gens[active_gen];
        let gen_node = nodes[active_gen];

        for after_gen in &gen_state.data.after {
            graph.add_edge(nodes[after_gen.as_str()], gen_node, ());
        }

        for wants_gen in &gen_state.data.wants {
            graph.add_edge(nodes[wants_gen.as_str()], gen_node, ());
        }
    }

    let order = toposort(&graph, None).map_err(|_| {
        tarjan_scc(&graph)
            .into_iter()
            .filter(|cycle_nodes| {
                cycle_nodes.len() > 1
                    || (cycle_nodes.len() == 1
                        && graph.contains_edge(cycle_nodes[0], cycle_nodes[0]))
            })
            .map(|cycle_nodes| PlanError::Cycle {
                gen_names: cycle_nodes
                    .into_iter()
                    .map(|n| graph[n])
                    .collect::<Vec<_>>(),
            })
            .collect::<Vec<_>>()
    })?;

    Ok(order.into_iter().map(|idx| graph[idx]).collect())
}

#[derive(Debug, thiserror::Error)]
pub enum ExecError {
    #[error("Generator has no evaluated script")]
    NoScript,

    #[error(transparent)]
    Runner(#[from] DynError),
}

pub fn exec<'s>(
    ctx: &dyn Ctx,
    entity: &Entity<'s>,
    force: bool,
    add_to_git: bool,
) -> Result<bool, ExecError> {
    let Some(bin_path) = &entity.data.script_path else {
        return Err(ExecError::NoScript);
    };

    let facts_exist = entity.facts.iter().all(|f| ctx.fs().exists(&f.file));
    let secrets_exist = entity.secrets.iter().all(|s| ctx.fs().exists(&s.file));

    if !force && facts_exist && secrets_exist {
        return Ok(false);
    }

    ctx.gen_runner()
        .run(&bin_path, force, add_to_git)
        .map_err(ExecError::Runner)?;

    Ok(true)
}
