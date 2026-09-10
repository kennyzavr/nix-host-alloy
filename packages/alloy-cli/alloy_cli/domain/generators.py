from typing import List, Optional

from ..data.state import GeneratorsRepository
from ..data.models import GeneratorRecord
from ..infrastructure.script_runner import ScriptRunnerAdapter
from .exceptions import (
    GeneratorNotDefinedError,
    GeneratorCycleError,
    GeneratorExecutionError,
)


class GeneratorsService:
    def __init__(
        self, generators_repo: GeneratorsRepository, script_runner: ScriptRunnerAdapter
    ):
        self.repo = generators_repo
        self.runner = script_runner

    def get_execution_plan(
        self, names: Optional[List[str]] = None, tags: Optional[List[str]] = None
    ) -> List[GeneratorRecord]:
        all_gens = self.repo.find_all()
        if not all_gens:
            return []

        if not names and not tags:
            selected = all_gens
        else:
            target_names = set(names or [])

            if tags:
                tag_set = set(tags)
                for g in all_gens:
                    if any(t in tag_set for t in g.tags):
                        target_names.add(g.name)

            for name in target_names:
                if not any(g.name == name for g in all_gens):
                    raise GeneratorNotDefinedError(name)

            selected = self.resolve_selection(target_names, all_gens)

        return self.build_execution_order(selected, all_gens)

    def run_generator(
        self, record: GeneratorRecord, force: bool = False, add_to_git: bool = False
    ) -> None:
        return_code = self.runner.run(record.script_path, force, add_to_git)
        if return_code != 0:
            raise GeneratorExecutionError(record.name, return_code)

    def resolve_selection(
        self, target_names: set, all_generators: List[GeneratorRecord]
    ) -> List[GeneratorRecord]:
        gen_map = {g.name: g for g in all_generators}
        selected_names = set(target_names)

        selection_edges = {}
        for g in all_generators:
            selection_edges.setdefault(g.name, set())
            for w in g.wants:
                selection_edges[g.name].add(w)
            for wb in g.wanted_by:
                selection_edges.setdefault(wb, set()).add(g.name)

        queue = list(selected_names)
        while queue:
            curr = queue.pop(0)
            if curr not in gen_map:
                raise GeneratorNotDefinedError(curr)

            for nxt in selection_edges.get(curr, []):
                if nxt not in selected_names:
                    selected_names.add(nxt)
                    queue.append(nxt)

        return [gen_map[name] for name in selected_names]

    def build_execution_order(
        self, selected: List[GeneratorRecord], all_generators: List[GeneratorRecord]
    ) -> List[GeneratorRecord]:
        selected_names = {g.name for g in selected}

        adj = {name: set() for name in selected_names}

        for g in all_generators:
            if g.name not in selected_names:
                continue

            for b in g.before:
                if b in selected_names:
                    adj[g.name].add(b)
            for a in g.after:
                if a in selected_names:
                    adj[a].add(g.name)

            for w in g.wants:
                if w in selected_names:
                    adj[w].add(g.name)
            for wb in g.wanted_by:
                if wb in selected_names:
                    adj[g.name].add(wb)

        in_degree = {name: 0 for name in selected_names}
        for u in adj:
            for v in adj[u]:
                in_degree[v] += 1

        queue = [name for name in selected_names if in_degree[name] == 0]

        order = []
        while queue:
            queue.sort()  # Ensure deterministic execution order
            curr = queue.pop(0)
            order.append(curr)
            for nxt in adj[curr]:
                in_degree[nxt] -= 1
                if in_degree[nxt] == 0:
                    queue.append(nxt)

        if len(order) != len(selected_names):
            raise GeneratorCycleError()

        gen_map = {g.name: g for g in selected}
        return [gen_map[name] for name in order]
