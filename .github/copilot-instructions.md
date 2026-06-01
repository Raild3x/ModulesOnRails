# Project Overview

This codebase contains the source for various Roblox Wally modules.

## Repository Structure

- `/lib`: Contains the source code for the game.
- `/test`: Contains our testing framework `tiniest`.
- `/scripts`: Contains various scripts for development and testing purposes.

Some packages are old and use outdated code styles and practices. When working on a particular package, try and follow the code style within that package and avoid looking outside of it so we dont end up mixing something old into something new.

## Package Structure

- `/src`: Contains the source code for the package.
- `/wally.toml`: The configuration file for the package within Wally.

If the package would consist of more than one module and is pure luau based, then
it should avoid using `init.luau` style entry points. This is to allow testing via `lune`.
When publishing, our build process will automatically create an `init.luau` file that re-exports all modules in the package. If the package is not pure luau based, then it can use an `init.luau` file as an entry point.

We can use `npm run setup <package-name>` to set up a package for development. This will install any needed wally dependencies and reorganize them in a fashion similar to how they would be used
in a live environment. This is not required to be able to work on a package, but it can be helpful as it will provide better autocompletion, linting, and error checking in VSCode.

## Coding Standards

- Use PascalCase for class names, table fields, method names.
- Use camelCase for variable names.
- Use SCREAMING_SNAKE_CASE for constants.
- Private fields and methods should be prefixed with an underscore (_).
- All non inferred parameters and functions should be type defined.
- Luau "Classes" should have a public type def and an internal type def. The internal type def will just union the public type def with any private fields and methods.
- Luau Class Methods should explicitly define `self` as the first parameter, utilizing the internal type def. We will use dot syntax for method declarations, but they should still be called with colon syntax. This is to allow for better type checking and inference.
- Used moonwave style --- for single line comments and --[=[]=] for multi-line comments for public documentation. Private documentation should keep with just -- and --[[]] style.
- When adjusting code, ensure we keep any existing comments or debug parts. Only remove them if  specifically asked or they become outdated with new functionality.

## Constants
In Luau, variables can be declared as constants using the const keyword. The const keyword will prevent a variable from being reassigned after its declaration. The const keyword should <i>always</i> be used whenever declaring a variable that never changes. The const keyword does not apply to the inside of tables, so a table that's edited later can still be const. Constant variables assigned at the base scope level should be written using SCREAMING_SNAKE_CASE. Constant tables at the base scope should use const and regular camelCase if they're edited later in the script - they should only use SCREAMING_SNAKE_CASE if they aren't edited later in the script. If we declare a variable and then immediately write to it, we consider that constant even if we may not be able to use the const keyword.

Data Type	Scope	Usage Pattern	Declaration Policy
non-table	Base	Never reassigned	const with SCREAMING_SNAKE_CASE
non-table	Base	Assigned immediately	local with SCREAMING_SNAKE_CASE
non-table	Base	Assigned programmatically	local with camelCase
table	Base	Never reassigned, and contents never reassigned	const with SCREAMING_SNAKE_CASE
table	Base	Never reassigned, and contents may be reassigned	const with camelCase
table	Base	Assigned immediately, and contents never reassigned	local with SCREAMING_SNAKE_CASE
table	Base	Assigned immediately, and contents may be reassigned	local with camelCase
table	Base	Assigned programmatically	local with camelCase
any	Inner	Never reassigned	const with camelCase
any	Inner	Assigned immediately	local with camelCase
any	Inner	Assigned programmatically	local with camelCase

## Testing
- Use tiniest for testing. TestEZ is deprecated.
- Testing should be done by making `.spec.luau` files.
- If the package is pure Luau code then it can be run in VSCode via `/tests.luau`.
- If the package is not pure Luau code, then it must be tested manually by the developer. You do not have the ability to run Roblox code, so you will need to rely on the developer to run the tests and provide you with the output. You can use this output to help debug any issues that arise.

## Debugging

While debugging, the user has the ability to copy and paste the output contents to help inform you. Always use plenty of prints, warnings, and errors so that you can extract value from the output. Never assume you know what the problem is without running a test and using the output to confirm it.

Respect the user's time. When adding prints and warnings to help debug, add no less than three distinct pieces of information to the output. Think ahead about what decision you might make in the future and anticipate the information you'll need at that point. Don't be afraid to add copious amounts of prints and warnings to get as much context into the output as possible.