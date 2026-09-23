use crate::domain::models::GeneratorRecord;
use crate::domain::ports::{CommandError, CommandRunner, NixError, NixEvaluator};
use petgraph::{
    algo::{tarjan_scc, toposort},
    graph::DiGraph,
};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::Arc;

use crate::error::ErrorCollection;

#[derive(Debug, thiserror::Error)]
pub enum PlanError {
    #[error("Failed to load state")]
    Nix(#[from] NixError),

    #[error(transparent)]
    GeneratorsNotFound(ErrorCollection<NotFoundError>),

    #[error("Found {count} cyclic dependency(-ies) during topological sort")]
    Cycles {
        count: usize,
        #[source]
        cycles: ErrorCollection<CycleError>,
    },
}

#[derive(Debug, thiserror::Error)]
#[error("Cycle: {}", gen_names.join(" -> "))]
pub struct CycleError {
    pub gen_names: Vec<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum GetError {
    #[error(transparent)]
    NotFound(#[from] NotFoundError),
}

#[derive(Debug, thiserror::Error)]
#[error("Generator `{name}` not found")]
pub struct NotFoundError {
    pub name: String,
}

#[derive(Debug, thiserror::Error)]
pub enum ExecError {
    #[error("Failed to build via Nix")]
    Build(#[from] NixError),

    #[error("Failed to execute script")]
    Execution(#[from] CommandError),
}

pub struct Service {
    pub nix: Arc<dyn NixEvaluator>,
    pub runner: Arc<dyn CommandRunner>,
    pub fs: Arc<dyn crate::domain::ports::FileSystem>,
}

impl Service {
    pub fn get(
        &self,
        state: &crate::domain::models::State,
        name: String,
    ) -> Result<GeneratorRecord, GetError> {
        let state_val = state
            .generators
            .get(&name)
            .ok_or_else(|| NotFoundError { name: name.clone() })?;

        Ok(GeneratorRecord {
            name,
            state: state_val.clone(),
        })
    }

    pub fn exec(
        &self,
        record: &GeneratorRecord,
        force: bool,
        add_to_git: bool,
    ) -> Result<(), ExecError> {
        let bin_path = self.nix.build_generator(&record.name)?;
        self.runner.spawn_generator(&bin_path, force, add_to_git)?;

        Ok(())
    }

    pub fn plan(
        &self,
        state: &crate::domain::models::State,
        names: &[String],
        tags: &[String],
    ) -> Result<Vec<GeneratorRecord>, PlanError> {
        let mut missing = Vec::new();
        for name in names {
            if !state.generators.contains_key(name) {
                missing.push(NotFoundError { name: name.clone() });
            }
        }
        if !missing.is_empty() {
            return Err(PlanError::GeneratorsNotFound(ErrorCollection::new(missing)));
        }

        let mut all_gens = Vec::new();
        for (gen_name, gen_state) in &state.generators {
            all_gens.push(GeneratorRecord {
                name: gen_name.clone(),
                state: gen_state.clone(),
            });
        }

        let mut target_gens = Vec::new();
        for generator in &all_gens {
            if !names.is_empty() && !names.contains(&generator.name) {
                continue;
            }

            if !tags.is_empty() && !generator.state.tags.iter().any(|t| tags.contains(t)) {
                continue;
            }

            target_gens.push(generator.clone());
        }

        self.build_exec_plan(&target_gens, &all_gens)
    }

    fn build_exec_plan(
        &self,
        target_gens: &[GeneratorRecord],
        all_gens: &[GeneratorRecord],
    ) -> Result<Vec<GeneratorRecord>, PlanError> {
        let mut gens = HashMap::<String, Vec<String>>::new();

        for generator in all_gens {
            gens.entry(generator.name.clone())
                .or_default()
                .extend(generator.state.wants.iter().cloned());

            for wanted_by_name in &generator.state.wanted_by {
                gens.entry(wanted_by_name.clone())
                    .or_default()
                    .push(generator.name.clone());
            }
        }

        let mut active_gens = HashSet::with_capacity(gens.len());
        let mut gens_queue = VecDeque::with_capacity(gens.len());

        gens_queue.extend(target_gens.iter().map(|g| g.name.clone()));
        while let Some(item) = gens_queue.pop_back() {
            if !active_gens.insert(item.clone()) {
                continue;
            }

            if let Some(gen_deps) = gens.get(&item) {
                for dep in gen_deps {
                    if !active_gens.contains(dep) {
                        gens_queue.push_front(dep.clone());
                    }
                }
            }
        }

        let mut graph = DiGraph::<String, ()>::new();
        let mut nodes = HashMap::<String, _>::new();
        for active_gen in &active_gens {
            let gen_node = graph.add_node(active_gen.clone());
            nodes.insert(active_gen.clone(), gen_node);
        }

        let mut missing_deps = Vec::new();
        for active_gen in &active_gens {
            if !all_gens.iter().any(|g| g.name == *active_gen) {
                missing_deps.push(NotFoundError {
                    name: active_gen.clone(),
                });
            }
        }
        if !missing_deps.is_empty() {
            return Err(PlanError::GeneratorsNotFound(ErrorCollection::new(
                missing_deps,
            )));
        }

        for active_gen in &active_gens {
            let generator = all_gens.iter().find(|g| g.name == *active_gen).unwrap();
            let gen_node = nodes[active_gen];

            for before_gen in &generator.state.before {
                if let Some(&before_node) = nodes.get(before_gen) {
                    graph.add_edge(gen_node, before_node, ());
                }
            }

            for after_gen in &generator.state.after {
                if let Some(&after_node) = nodes.get(after_gen) {
                    graph.add_edge(after_node, gen_node, ());
                }
            }

            for wants_gen in &generator.state.wants {
                if let Some(&wants_node) = nodes.get(wants_gen) {
                    graph.add_edge(wants_node, gen_node, ());
                }
            }

            for wanted_by_gen in &generator.state.wanted_by {
                if let Some(&wanted_by_node) = nodes.get(wanted_by_gen) {
                    graph.add_edge(gen_node, wanted_by_node, ());
                }
            }
        }

        let order = match toposort(&graph, None) {
            Ok(order) => order,
            Err(_) => {
                let cycles = tarjan_scc(&graph)
                    .into_iter()
                    .filter(|cycle_nodes| {
                        cycle_nodes.len() > 1
                            || (cycle_nodes.len() == 1
                                && graph.contains_edge(cycle_nodes[0], cycle_nodes[0]))
                    })
                    .map(|cycle_nodes| {
                        let gen_names = cycle_nodes
                            .into_iter()
                            .map(|n| graph[n].to_string())
                            .collect::<Vec<_>>();
                        CycleError { gen_names }
                    })
                    .collect::<Vec<_>>();

                return Err(PlanError::Cycles {
                    count: cycles.len(),
                    cycles: ErrorCollection::new(cycles),
                });
            }
        };

        let mut result_gens = Vec::new();
        for idx in order {
            let name = &graph[idx];
            let generator = all_gens.iter().find(|g| g.name == *name).unwrap();
            result_gens.push(generator.clone());
        }

        Ok(result_gens)
    }
}
