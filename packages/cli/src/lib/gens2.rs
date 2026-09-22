use std::collections::{HashMap, HashSet, VecDeque};

use petgraph::{
    algo::{tarjan_scc, toposort},
    graph::DiGraph,
};

use crate::lib::{
    StyledName,
    state::{self},
};

#[derive(Debug, thiserror::Error, miette::Diagnostic)]
pub enum RunError {
    #[error("Generator {} not found", StyledName(&name))]
    #[diagnostic(
        code(alloy::facts::not_found),
        help("Define the fact in your nix configuration")
    )]
    NotFound { name: String },

    #[error(transparent)]
    #[diagnostic(transparent)]
    Cycles(#[from] CyclesError),

    #[error("Found {} invalid generators", scripts.len())]
    #[diagnostic(help("Check your nix configuration to errors"))]
    Scripts {
        #[related]
        scripts: Vec<ScriptError>,
    },

    #[error("Failed to execute generator {}", StyledName(&name))]
    #[diagnostic(forward(inner))]
    Exec {
        name: String,
        #[source]
        inner: ExecError,
    },
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
}

#[derive(Debug, thiserror::Error, miette::Diagnostic)]
pub enum ScriptError {
    #[error("Script for generator {} cannot be evaluated", StyledName(&name))]
    #[diagnostic(forward(inner))]
    Load {
        name: String,
        #[source]
        inner: state::EvalError,
    },

    #[error("Script for generator {} cannot be evaluated", StyledName(&name))]
    #[diagnostic()]
    Eval { name: String },
}

pub fn run<'s>(
    loader: &'s state::Loader,
    target_gens: &HashSet<&'s str>,
    force: bool,
    add_to_git: bool,
) -> Result<(), RunError> {
    let mut cache = HashSet::<state::GeneratorState>::new();

    let invalid_gens = loop {
        let state = loader.load().unwrap();

        for &target_gen in target_gens {
            if !state.generators.contains_key(target_gen) {
                return Err(RunError::NotFound {
                    name: target_gen.to_string(),
                });
            }
        }

        let exec_plan = build_exec_plan(state.generators, target_gens)?;

        let mut invalid = vec![];
        let mut executed = false;
        for (gen_name, gen_state) in exec_plan {
            if gen_state.bin.is_none() {
                invalid.push(gen_name);
                continue;
            }

            if cache.contains(&gen_state) {
                continue;
            }

            let (force, add_to_git) = if target_gens.contains(&gen_name.as_str()) {
                (force, add_to_git)
            } else {
                (false, false)
            };

            exec(&gen_state, force, add_to_git).map_err(|err| RunError::Exec {
                name: gen_name,
                inner: err,
            })?;

            executed = true;
            cache.insert(gen_state);
        }

        if !executed {
            break invalid;
        }
    };

    let mut script_errors = Vec::with_capacity(invalid_gens.len());
    for invalid_gen in invalid_gens {
        let error = match loader.trigger_generator_evaluation(&invalid_gen) {
            Ok(_) => ScriptError::Eval { name: invalid_gen },
            Err(err) => ScriptError::Load {
                name: invalid_gen,
                inner: err,
            },
        };
        script_errors.push(error);
    }

    if script_errors.is_empty() {
        Ok(())
    } else {
        Err(RunError::Scripts {
            scripts: script_errors,
        })
    }
}

fn exec(gen_state: &state::GeneratorState, force: bool, add_to_git: bool) -> Result<(), ExecError> {
    let exe_path = std::env::current_exe().map_err(ExecError::NoPath)?;
    let Some(exe_dir) = exe_path.parent() else {
        return Err(ExecError::NoParentDir);
    };

    let current_path = std::env::var("PATH").unwrap_or_default();

    let mut paths = std::env::split_paths(&current_path).collect::<Vec<_>>();
    paths.insert(0, exe_dir.to_path_buf());
    let new_path = std::env::join_paths(paths)?;

    let depth = std::env::var("ALLOY_DEPTH")
        .unwrap_or_else(|_| "0".to_string())
        .parse()
        .unwrap_or(0);

    let mut cmd = std::process::Command::new(gen_state.bin.as_ref().unwrap());

    cmd.env("PATH", new_path)
        .env("ALLOY_BIN", exe_path)
        .env("ALLOY_DEPTH", (depth + 1).to_string());

    if force {
        cmd.env("ALLOY_FORCE", "1");
    }

    if add_to_git {
        cmd.env("ALLOY_ADD_TO_GIT", "1");
    }

    let _status = cmd.status().map_err(ExecError::Spawn)?;

    Ok(())
}

fn build_exec_plan(
    mut gen_states: HashMap<String, state::GeneratorState>,
    target_gens: &HashSet<&str>,
) -> Result<Vec<(String, state::GeneratorState)>, CyclesError> {
    let graph = {
        let mut gens = HashMap::<_, Vec<_>>::new();

        for (gen_name, gen_state) in gen_states.iter() {
            gens.entry(gen_name.as_str())
                .or_default()
                .extend(gen_state.wants.iter().map(String::as_str));

            for wanted_by_name in gen_state.wanted_by.iter().map(String::as_str) {
                gens.entry(wanted_by_name).or_default().push(gen_name);
            }
        }

        let mut active_gens = HashSet::with_capacity(gens.len());
        let mut gens_queue = VecDeque::with_capacity(gens.len());

        gens_queue.extend(target_gens.iter().copied());
        while let Some(item) = gens_queue.pop_back() {
            if !active_gens.insert(item) {
                continue;
            }

            let gen_deps = gens.get(item).unwrap();

            for &dep in gen_deps {
                if !active_gens.contains(dep) {
                    gens_queue.push_front(dep);
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
            let gen_state = &gen_states[active_gen];
            let gen_node = nodes[active_gen];

            for before_gen in gen_state.before.iter().map(String::as_str) {
                let before_node = nodes[before_gen];
                graph.add_edge(gen_node, before_node, ());
            }

            for after_gen in gen_state.after.iter().map(String::as_str) {
                let after_node = nodes[after_gen];
                graph.add_edge(after_node, gen_node, ());
            }

            for wants_gen in gen_state.before.iter().map(String::as_str) {
                let wants_node = nodes[wants_gen];
                graph.add_edge(wants_node, gen_node, ());
            }

            for wanted_by_gen in gen_state.after.iter().map(String::as_str) {
                let wanted_by_node = nodes[wanted_by_gen];
                graph.add_edge(gen_node, wanted_by_node, ());
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

        return Err(CyclesError { cycles });
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
