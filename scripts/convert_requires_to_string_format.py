import re
from pathlib import Path

REQUIRE_PATTERN = re.compile(
    r"require\s*\(\s*(.*?)\s*\)",
    re.DOTALL
)


def parse_instance_path(expr: str):
    """
    Attempts to convert a Roblox Instance expression into a list of path parts.

    Returns:
        ("self", ["Child", "GrandChild"])
        ("parent", depth, ["Child"])
        None if expression is not statically resolvable.
    """

    expr = expr.strip()

    if not expr.startswith("script"):
        return None

    pos = len("script")

    parent_depth = 0
    parts = []

    while pos < len(expr):
        remaining = expr[pos:]

        # .Name
        m = re.match(r"\.([A-Za-z_][A-Za-z0-9_]*)", remaining)
        if m:
            name = m.group(1)

            if name == "Parent" and not parts:
                parent_depth += 1
            else:
                parts.append(name)

            pos += m.end()
            continue

        # ["Name"]
        m = re.match(r'\["([^"]+)"\]', remaining)
        if m:
            parts.append(m.group(1))
            pos += m.end()
            continue

        # :FindFirstChild("Name")
        m = re.match(
            r':FindFirstChild\(\s*"([^"]+)"\s*\)',
            remaining
        )
        if m:
            parts.append(m.group(1))
            pos += m.end()
            continue

        # :WaitForChild("Name")
        m = re.match(
            r':WaitForChild\(\s*"([^"]+)"\s*\)',
            remaining
        )
        if m:
            parts.append(m.group(1))
            pos += m.end()
            continue

        # unsupported dynamic expression
        return None

    if parent_depth == 0:
        return ("self", parts)

    return ("parent", parent_depth, parts)


def convert_require_path(expr: str):
    parsed = parse_instance_path(expr)

    if parsed is None:
        return None

    kind = parsed[0]

    if kind == "self":
        _, parts = parsed
        return f'@self/{"/".join(parts)}'

    _, depth, parts = parsed

    if depth == 1:
        prefix = "."
    else:
        prefix = "/".join(".." for _ in range(depth - 1))

    if parts:
        return f'{prefix}/{"/".join(parts)}'

    return prefix


def replace_requires(source: str):
    def repl(match):
        expr = match.group(1)

        converted = convert_require_path(expr)

        if converted is None:
            return match.group(0)

        return f'require("{converted}")'

    return REQUIRE_PATTERN.sub(repl, source)


def process_file(path: Path):
    original = path.read_text(encoding="utf-8")

    transformed = replace_requires(original)

    if transformed != original:
        path.write_text(transformed, encoding="utf-8")
        print(f"Updated: {path}")


def process_directory(root: str):
    root = Path(root)

    for file in root.rglob("*"):
        if file.suffix in (".lua", ".luau"):
            process_file(file)
