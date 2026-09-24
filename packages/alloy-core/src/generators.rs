use std::collections::{HashMap, HashSet, VecDeque};
use std::fmt;

use petgraph::{
    algo::{tarjan_scc, toposort},
    graph::DiGraph,
};

use crate::ctx::Ctx;
use crate::{DynError, NameMark, models};

pub struct Entity<'s> {
    pub name: &'s str,
    pub data: &'s models::Generator,
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

#[derive(Debug, Clone, Copy)]
pub struct Pool<'s> {
    gens: &'s HashMap<String, models::Generator>,
}

impl<'s> Pool<'s> {
    pub fn get(&self, name: &str) -> Option<&models::Generator> {
        self.gens.get(name)
    }

    pub fn names(&self) -> impl IntoIterator<Item = &'s str> {
        self.gens.keys().map(String::as_str)
    }

    pub fn generators(&self) -> impl IntoIterator<Item = &'s models::Generator> {
        self.gens.values()
    }

    pub fn iter(&self) -> impl IntoIterator<Item = (&'s str, &'s models::Generator)> {
        self.gens.iter().map(|(name, data)| (name.as_str(), data))
    }
}

#[derive(thiserror::Error, Debug)]
pub enum FindError<'s> {
    #[error(transparent)]
    NotFound(#[source] NotDefinedError),
    #[error("Generator has invalid {kind} ref to {}", NameMark(ref_name))]
    InvalidRef { kind: RefKind, ref_name: &'s str },
}

pub fn find<'s>(state: &'s models::State, name: &'s str) -> Result<Pool<'s>, Vec<FindError<'s>>> {
    let data = state.generator.get(name).ok_or(NotDefinedError)?;

    let mut errors = Vec::new();
    for (gen_name, gen_state) in &state.generators {
        for gen_ref in &gen_state.wants {
            if !state.generators.get(gen_ref).is_none() {
                errors.push(FindAllError::InvalidRef {
                    name: gen_name,
                    kind: RefKind::Wants,
                    ref_name: gen_ref,
                })
            }
        }
        for gen_ref in &gen_state.after {
            if !state.generators.get(gen_ref).is_none() {
                errors.push(FindAllError::InvalidRef {
                    name: gen_name,
                    kind: RefKind::After,
                    ref_name: gen_ref,
                })
            }
        }
    }

    if !errors.is_empty() {
        return Err(errors);
    }

    Ok(Pool {
        gens: &state.generators,
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
}

pub fn find_all<'s>(state: &'s models::State) -> Result<Pool<'s>, Vec<FindAllError<'s>>> {
    let mut errors = Vec::new();
    for (gen_name, gen_state) in &state.generators {
        for gen_ref in &gen_state.wants {
            if !state.generators.get(gen_ref).is_none() {
                errors.push(FindAllError::InvalidRef {
                    name: gen_name,
                    kind: RefKind::Wants,
                    ref_name: gen_ref,
                })
            }
        }
        for gen_ref in &gen_state.after {
            if !state.generators.get(gen_ref).is_none() {
                errors.push(FindAllError::InvalidRef {
                    name: gen_name,
                    kind: RefKind::After,
                    ref_name: gen_ref,
                })
            }
        }
    }

    if !errors.is_empty() {
        return Err(errors);
    }

    Ok(Pool {
        gens: &state.generators,
    })
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

        for after_gen in &gen_state.after {
            graph.add_edge(nodes[after_gen.as_str()], gen_node, ());
        }

        for wants_gen in &gen_state.wants {
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
    ctx: &'s Ctx,
    generator: &'s models::Generator,
    force: bool,
    add_to_git: bool,
) -> Result<(), ExecError> {
    let Some(bin_path) = &generator.script_path else {
        return Err(ExecError::NoScript);
    };

    ctx.generator_runner
        .run(&bin_path, force, add_to_git)
        .map_err(ExecError::Runner)?;

    Ok(())
}
