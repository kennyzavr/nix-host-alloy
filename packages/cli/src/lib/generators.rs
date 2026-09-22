use std::collections::{HashMap, HashSet, VecDeque};

use petgraph::{
    algo::{tarjan_scc, toposort},
    graph::DiGraph,
};

use crate::lib::{StyledName, facts, secrets, state};

#[derive(Debug, thiserror::Error, miette::Diagnostic)]
pub enum PlanError {
    #[error("Generator {} not found", StyledName(&name))]
    #[diagnostic(
        code(alloy::generators::not_found),
        help("Define the generator in your nix configuration")
    )]
    NotFound { name: String },

    #[error(transparent)]
    #[diagnostic(transparent)]
    Cycles(#[from] CyclesError),
}

#[derive(Debug, thiserror::Error, miette::Diagnostic)]
#[error("Found {} cyclic dependency(-ies) during topological sort.", cycles.len())]
#[diagnostic(
    code(alloy::generators::cycles),
    help("All cycles must be resolved to process with generators execution.")
)]
pub struct CyclesError {
    #[related]
    pub cycles: Vec<CycleError>,
}

#[derive(Debug, thiserror::Error, miette::Diagnostic)]
#[error("Cycle: {}", gen_names.join(" -> "))]
#[diagnostic(code(alloy::generators::cycle))]
pub struct CycleError {
    pub gen_names: Vec<String>,
}

#[derive(Debug, thiserror::Error, miette::Diagnostic)]
#[error("")]
pub enum ExecError {
    #[error("Path of current exe has no parent dir")]
    #[diagnostic()]
    NoParentDir,

    #[error("Failed to get path of current exe")]
    #[diagnostic()]
    NoPath(#[source] std::io::Error),

    #[error("Failed to get add current exe to path env var")]
    #[diagnostic()]
    JoinPaths(#[from] std::env::JoinPathsError),

    #[error("Failed to spawn script")]
    #[diagnostic()]
    Spawn(#[source] std::io::Error),

    #[error("Script failed with {0}")]
    #[diagnostic()]
    Failed(std::process::ExitStatus),
}

pub fn collect(state: &state::State, names: &[String], tags: &[String]) -> Vec<String> {
    let mut result = Vec::new();

    for (gen_name, gen_state) in &state.generators {
        if !names.is_empty() && !names.contains(gen_name) {
            continue;
        }

        if !tags.is_empty() && !gen_state.tags.iter().any(|t| tags.contains(t)) {
            continue;
        }

        result.push(gen_name.clone());
    }

    result
}

pub fn exec(
    gen_state: &state::GeneratorState,
    force: bool,
    add_to_git: bool,
    workspace_root: &std::path::Path,
    module_source: &state::ModuleSource,
    depth: u32,
) -> Result<(), ExecError> {
    let exe_path = std::env::current_exe().map_err(ExecError::NoPath)?;
    let Some(exe_dir) = exe_path.parent() else {
        return Err(ExecError::NoParentDir);
    };

    let current_path = std::env::var("PATH").unwrap_or_default();

    let mut paths = std::env::split_paths(&current_path).collect::<Vec<_>>();
    paths.insert(0, exe_dir.to_path_buf());
    let new_path = std::env::join_paths(paths)?;

    let mut cmd = std::process::Command::new(gen_state.bin.as_ref().unwrap());

    cmd.env("PATH", new_path)
        .env("ALLOY_BIN", exe_path)
        .env("ALLOY_DEPTH", (depth + 1).to_string())
        .env("ALLOY_ROOT", workspace_root);

    match module_source {
        state::ModuleSource::ModuleFile(path) => {
            cmd.env("ALLOY_MODULE", path);
        }
        state::ModuleSource::FlakeAttr(attr) => {
            cmd.env("ALLOY_ATTR", attr);
        }
    }

    if force {
        cmd.env("ALLOY_FORCE", "1");
    }

    if add_to_git {
        cmd.env("ALLOY_ADD_TO_GIT", "1");
    }

    let status = cmd.status().map_err(ExecError::Spawn)?;

    if !status.success() {
        return Err(ExecError::Failed(status));
    }

    Ok(())
}

pub fn build_exec_plan(
    mut gen_states: HashMap<String, state::GeneratorState>,
    target_gens: &HashSet<&str>,
) -> Result<Vec<(String, state::GeneratorState)>, PlanError> {
    let graph = {
        let mut gens = HashMap::<_, Vec<_>>::new();

        for (gen_name, gen_state) in gen_states.iter() {
            gens.entry(gen_name.as_str())
                .or_default()
                .extend(gen_state.wants.iter().map(String::as_str));

            for wanted_by_name in gen_state.wanted_by.iter().map(String::as_str) {
                gens.entry(wanted_by_name)
                    .or_default()
                    .push(gen_name.as_str());
            }
        }

        let mut active_gens = HashSet::with_capacity(gens.len());
        let mut gens_queue = VecDeque::with_capacity(gens.len());

        gens_queue.extend(target_gens.iter().copied());
        while let Some(item) = gens_queue.pop_back() {
            if !active_gens.insert(item) {
                continue;
            }

            if let Some(gen_deps) = gens.get(item) {
                for &dep in gen_deps {
                    if !active_gens.contains(dep) {
                        gens_queue.push_front(dep);
                    }
                }
            }
        }

        let mut graph = DiGraph::<String, ()>::new();
        let mut nodes = HashMap::<&str, _>::new();
        for &active_gen in &active_gens {
            let gen_node = graph.add_node(active_gen.to_string());
            nodes.insert(active_gen, gen_node);
        }

        for active_gen in active_gens {
            let gen_state = gen_states
                .get(active_gen)
                .ok_or_else(|| PlanError::NotFound {
                    name: active_gen.to_string(),
                })?;
            let gen_node = nodes[active_gen];

            for before_gen in gen_state.before.iter().map(String::as_str) {
                if let Some(&before_node) = nodes.get(before_gen) {
                    graph.add_edge(gen_node, before_node, ());
                }
            }

            for after_gen in gen_state.after.iter().map(String::as_str) {
                if let Some(&after_node) = nodes.get(after_gen) {
                    graph.add_edge(after_node, gen_node, ());
                }
            }

            for wants_gen in gen_state.wants.iter().map(String::as_str) {
                if let Some(&wants_node) = nodes.get(wants_gen) {
                    graph.add_edge(wants_node, gen_node, ());
                }
            }

            for wanted_by_gen in gen_state.wanted_by.iter().map(String::as_str) {
                if let Some(&wanted_by_node) = nodes.get(wanted_by_gen) {
                    graph.add_edge(gen_node, wanted_by_node, ());
                }
            }
        }

        graph
    };

    let Ok(order) = toposort(&graph, None) else {
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
                    .map(|n| graph[n].clone())
                    .collect::<Vec<_>>();

                CycleError { gen_names }
            })
            .collect::<Vec<_>>();

        return Err(PlanError::Cycles(CyclesError { cycles }));
    };

    let gens = order
        .into_iter()
        .map(|idx| {
            let name = &graph[idx];
            let state = gen_states.remove(name).unwrap();
            (name.clone(), state)
        })
        .collect();

    Ok(gens)
}
