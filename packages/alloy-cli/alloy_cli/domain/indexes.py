import json
from typing import List, Dict, Tuple, Optional, Iterable
from .facts import FactsService
from ..data.state import IndexesRepository
from ..data.models import IndexRecord
from .exceptions import (
    IndexNotDefinedError,
    IndexAllocationFailedError,
    IndexStateCorruptedError,
    FactFileNotFoundError,
)


class IndexesService:
    def __init__(self, indexes_repo: IndexesRepository, facts_service: FactsService):
        self.indexes_repo = indexes_repo
        self.facts_service = facts_service

    def get_generation_plan(
        self, names: Optional[List[str]] = None
    ) -> List[IndexRecord]:
        if not names:
            return self.indexes_repo.find_all()

        plan = []
        for name in names:
            record = self.indexes_repo.find_by_name(name)
            if not record:
                raise IndexNotDefinedError(name)
            plan.append(record)

        return plan

    def allocate_index(
        self, record: IndexRecord, force: bool = False, add_to_git: bool = False
    ) -> Tuple[bool, int]:
        """
        Allocates IDs for an index and syncs the backing fact file.
        Returns a tuple (changed: bool, size: int).
        """
        existing_state, file_exists = self._read_state(record, force)
        current_state = {k: v for k, v in existing_state.items() if k in record.keys}

        unallocated_keys = sorted([k for k in record.keys if k not in current_state])
        needed = len(unallocated_keys)

        if needed > 0:
            available_values = self._compute_allocations(
                current_state.values(), needed, record
            )
            for k in unallocated_keys:
                current_state[k] = available_values.pop(0)

        # if current_state == existing_state and not force:
        if current_state == existing_state and file_exists:
            return False, len(current_state)

        self.facts_service.set(
            record.fact_name,
            json.dumps(current_state, indent=2, sort_keys=True),
            force=True,
            add_to_git=add_to_git,
        )
        return True, len(current_state)

    def _read_state(self, record: IndexRecord, force: bool) -> Tuple[dict, bool]:
        index_name = record.name
        existing_state = {}
        try:
            raw_data = self.facts_service.get(record.fact_name)
            try:
                existing_state = json.loads(raw_data)
                if not isinstance(existing_state, dict):
                    raise IndexStateCorruptedError(
                        index_name, record.fact_name, "root is not a JSON object"
                    )

                seen_values = set()
                for k, v in existing_state.items():
                    if not isinstance(v, int):
                        raise IndexStateCorruptedError(
                            index_name,
                            record.fact_name,
                            f"value for key '{k}' is not an integer",
                        )
                    if v < record.min_value or v > record.max_value:
                        raise IndexStateCorruptedError(
                            index_name,
                            record.fact_name,
                            f"value {v} for key '{k}' is out of bounds [{record.min_value}, {record.max_value}]",
                        )
                    if v in seen_values:
                        raise IndexStateCorruptedError(
                            index_name,
                            record.fact_name,
                            f"duplicate value {v} found for key '{k}'",
                        )
                    seen_values.add(v)
            except (json.JSONDecodeError, IndexStateCorruptedError) as e:
                if force:
                    return {}, True
                if isinstance(e, json.JSONDecodeError):
                    raise IndexStateCorruptedError(index_name, record.fact_name)
                raise e
        except FactFileNotFoundError:
            return {}, False

        return existing_state, True

    def _compute_allocations(
        self, used_values: Iterable[int], needed: int, record: IndexRecord
    ) -> List[int]:
        used_sorted = sorted(used_values)
        available_values = []
        candidate = record.min_value

        for used_val in used_sorted:
            if len(available_values) >= needed:
                break
            while (
                candidate < used_val
                and len(available_values) < needed
                and candidate <= record.max_value
            ):
                available_values.append(candidate)
                candidate += 1
            candidate = max(candidate, used_val + 1)

        while len(available_values) < needed and candidate <= record.max_value:
            available_values.append(candidate)
            candidate += 1

        if len(available_values) < needed:
            raise IndexAllocationFailedError(
                record.name, needed, record.min_value, record.max_value
            )

        return available_values

    def check_consistency(self, record: IndexRecord) -> None:
        """
        Checks if the index is in a consistent state.
        Raises IndexStateCorruptedError if not.
        """
        state, _ = self._read_state(record, force=False)

        expected_keys = set(record.keys)
        actual_keys = set(state.keys())

        if expected_keys != actual_keys:
            missing = expected_keys - actual_keys
            extra = actual_keys - expected_keys
            msg = "Keys mismatch."
            if missing:
                msg += f" Missing allocated keys: {', '.join(sorted(missing))}."
            if extra:
                msg += f" Extra keys in state: {', '.join(sorted(extra))}."
            raise IndexStateCorruptedError(record.name, record.fact_name, msg)

    def check_all_consistency(self) -> None:
        """
        Checks consistency for all defined indexes.
        """
        for record in self.indexes_repo.find_all():
            self.check_consistency(record)
