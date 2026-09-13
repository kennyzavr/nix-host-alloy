from rich.tree import Tree
from typing import Callable, Any, Iterable


def build_nested_dict(items: Iterable[Any], name_getter: Callable[[Any], str]):
    root = {}
    for item in items:
        name = name_getter(item)
        parts = name.split("/")
        current = root
        for part in parts[:-1]:
            if part not in current:
                current[part] = {}
            current = current[part]
        current[parts[-1]] = {"__data__": item}
    return root


def render_tree_view(
    tree: Tree,
    items: Iterable[Any],
    name_getter: Callable[[Any], str],
    render_leaf: Callable[[Tree, str, Any], None],
    flat: bool = False,
):
    if flat:
        for item in sorted(items, key=name_getter):
            render_leaf(tree, name_getter(item), item)
        return

    nested = build_nested_dict(items, name_getter)

    def _render(node, current_dict):
        for key in sorted(current_dict.keys()):
            val = current_dict[key]
            if "__data__" in val:
                render_leaf(node, key, val["__data__"])
            else:
                dir_key = key
                curr_val = val
                while (
                    len(curr_val) == 1 and "__data__" not in list(curr_val.values())[0]
                ):
                    next_key = list(curr_val.keys())[0]
                    dir_key += f" / {next_key}"
                    curr_val = curr_val[next_key]

                dir_node = node.add(f"{dir_key}")
                _render(dir_node, curr_val)

    _render(tree, nested)
