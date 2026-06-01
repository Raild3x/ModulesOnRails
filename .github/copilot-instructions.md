# ModulesOnRails Copilot Instructions

## Goal
This repository contains multiple Roblox Wally modules. Favor consistency inside the package you are editing over consistency with the rest of the repository.

## Priority Order
1. Follow the local style of the current package first.
2. Follow these repository-wide standards second.
3. Keep existing behavior unless the change explicitly requires behavior changes.

## Repository Layout
- `/lib`: Source for packages.
- `/test`: Test harness and stories, including tiniest usage.
- `/scripts`: Development, setup, and publish scripts.

## Package Layout
- `/src`: Package source.
- `/wally.toml`: Package configuration.

If a package is pure Luau and has multiple modules, do not use `init.luau` as the entry point. This keeps the package friendly for `lune` testing.

Publishing will generate an `init.luau` re-export automatically. Non-pure-Luau packages may use `init.luau` directly.

## Setup For Development
Use `npm run setup <package-name>` when deeper local package context is needed. This installs dependencies and arranges them similarly to live usage, improving autocomplete, linting, and diagnostics in VS Code.

## Luau Style Rules
- Use PascalCase for class names, table fields, and method names.
- Use camelCase for variable names.
- Use SCREAMING_SNAKE_CASE for constants.
- Prefix private fields and methods with `_`.
- Add explicit types for non-inferred parameters and function signatures.
- For Luau classes, define both a public type and an internal type.
- Internal type should extend public type with private fields and methods.
- Declare class methods with dot syntax and explicit `self: InternalType`.
- Call those methods with colon syntax.
- Keep existing comments and debug logic unless removal is explicitly requested or the content is now outdated.
- Methods/functions that yield or could potentially yield should be either suffixed with `Async` or return as a Promise to prevent unexpected behavior.
- Avoid magic numbers. That is, numbers with no obvious underlying meaning. You can attribute meaning to a number by assigning it to a variable or constant with a descriptive name, or by writing a comment explaining what the number's purpose is.
- Packages should always have relative paths for their requires. Never require another module with an absolute path.

## Documentation Style
- Public single-line docs: `---`
- Public multi-line docs: `--[=[]=]`
- Private single-line comments: `--`
- Private multi-line comments: `--[[]]`

## Constant Policy
Use `const` whenever a variable binding is never reassigned.

Important notes:
- `const` protects the variable binding, not table contents.
- Base-scope constants should use SCREAMING_SNAKE_CASE unless they are mutable-content tables.
- If a variable is declared and immediately assigned later, treat it as non-const for policy purposes.
- Exceptions to the constant naming policy may be made when justified by readability, practicality, or consistency with existing code. Ex: Roblox services and required modules should be consts at the base scope, but they should be PascalCase even though they are never reassigned.
- local functions should almost always be const.

Declaration matrix:

| Data Type | Scope | Usage Pattern | Declaration Policy |
| --- | --- | --- | --- |
| non-table | Base | Never reassigned | const with SCREAMING_SNAKE_CASE |
| non-table | Base | Assigned immediately | local with SCREAMING_SNAKE_CASE |
| non-table | Base | Assigned programmatically | local with PascalCase |
| table | Base | Never reassigned, contents never reassigned | const with SCREAMING_SNAKE_CASE |
| table | Base | Never reassigned, contents may be reassigned | const with PascalCase |
| table | Base | Assigned programmatically | local with PascalCase |
| any | Inner | Never reassigned | const with camelCase |
| any | Inner | Assigned immediately | local with camelCase |
| any | Inner | Assigned programmatically | local with camelCase |

## Testing Rules
- Use tiniest for tests. Analyze the examples under `/test/tiniest` for reference.
- TestEZ is deprecated in this codebase. NEVER use TestEZ or its syntax. They do not exist.
- Create tests in `.spec.luau` files.
- For pure Luau packages, run tests through `tests.luau` in VS Code.
- For non-pure-Luau packages, rely on developer-run manual testing and provided output.

## Debugging Rules
- Never assume root cause without validating with test output.
- Add rich diagnostics when debugging: use prints, warnings, and errors.
- Include at least 3 distinct pieces of information in debug output.
- Prefer extra context over minimal logs so follow-up decisions can be made from one run.

## Planning
- While planning, you must should come up with a flowchart to explain the current way things work and a separate flowchart to explain the new proposal. If a plan includes multiple separate changes, you need multiple separate before and after flowcharts.
- You must always include a list of to-dos in the final plan and they should be broken into discrete tasks that an agent can be tasked with.