"use strict";(self.webpackChunkdocs=self.webpackChunkdocs||[]).push([[8455],{29614:e=>{e.exports=JSON.parse('{"functions":[{"name":"snap","desc":"Takes a value and snaps it to the closest one of the following values.","params":[{"name":"v","desc":"The value to snap.","lua_type":"number"},{"name":"...","desc":"The array or variadic of number values to snap to.","lua_type":"number | { number }"}],"returns":[{"desc":"The closest value to the given value.","lua_type":"number"}],"function_type":"static","source":{"line":27,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"random","desc":"Returns a random float between the given min and max.","params":[{"name":"min","desc":"The minimum value.","lua_type":"number"},{"name":"max","desc":"The maximum value.","lua_type":"number"}],"returns":[{"desc":"The random float.","lua_type":"number"}],"function_type":"static","source":{"line":50,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"randomFromNumberRange","desc":"Returns a random float in the given number range.","params":[{"name":"numberRange","desc":"The number range to generate a random number from.","lua_type":"NumberRange"}],"returns":[{"desc":"The generated random number.","lua_type":"number"}],"function_type":"static","source":{"line":62,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"randomFromArray","desc":"Gets a random number within the given array.","params":[{"name":"tbl","desc":"The array to get a random number from.","lua_type":"{number}"}],"returns":[{"desc":"The random number.","lua_type":"number"}],"function_type":"static","source":{"line":72,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"randomFromRanges","desc":"Gets a random number within the given ranges.\\nBy default the numbers within the ranges have an equal chance of being selected\\n(unless the given table has a `Weight` index)\\n\\n```lua\\nlocal n = MathUtil.randomFromRanges({1, 10}, {20, 40}) -- Returns a random number between 1 and 10 or 20 and 40.\\n```","params":[{"name":"...","desc":"","lua_type":"{number} | NumberRange"}],"returns":[{"desc":"","lua_type":"number\\r\\n"}],"function_type":"static","source":{"line":85,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"randomFromNumberSequence","desc":"Generates a random number from a NumberSequence. It uses the sequence like a weight table\\nand returns a random number from the sequence.","params":[{"name":"sequence","desc":"The sequence to generate a random number from.","lua_type":"NumberSequence"}],"returns":[{"desc":"The generated random number.","lua_type":"number"}],"function_type":"static","private":true,"unreleased":true,"source":{"line":122,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"tryRandom","desc":"Trys to return a random number from the given data. It parses the data to try and figure out\\nwhich random methodology to use.","params":[{"name":"data","desc":"The data to try and generate a random number from.","lua_type":"number | NumberRange | NumberSequence | { number }"},{"name":"...","desc":"The optional arguments to pass to the random function.","lua_type":"any"}],"returns":[{"desc":"","lua_type":"number\\r\\n"}],"function_type":"static","source":{"line":133,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"round","desc":"Rounds a number to the nearest specified multiple.","params":[{"name":"numToRound","desc":"The number to round.","lua_type":"number"},{"name":"multiple","desc":"The multiple to round to. If not specified, will round to the nearest integer.","lua_type":"number?"}],"returns":[{"desc":"","lua_type":"The rounded number."}],"function_type":"static","source":{"line":163,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"lerp","desc":"Lerps a `number` between two other numbers based on a given alpha.","params":[{"name":"a","desc":"The first number.","lua_type":"number"},{"name":"b","desc":"The second number.","lua_type":"number"},{"name":"t","desc":"The alpha to lerp between the two numbers.","lua_type":"number"}],"returns":[{"desc":"","lua_type":"The lerped number."}],"function_type":"static","source":{"line":181,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"isBetween","desc":"Checks if a number is between two other numbers.","params":[{"name":"numToCheck","desc":"The number to check.","lua_type":"number"},{"name":"bound1","desc":"The first bound.","lua_type":"number"},{"name":"bound2","desc":"The second bound.","lua_type":"number"}],"returns":[{"desc":"Whether or not the number is between the two bounds.","lua_type":"boolean"}],"function_type":"static","source":{"line":192,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"isClose","desc":"Checks if two numbers are close to each other within a given epsilon.","params":[{"name":"num1","desc":"The first number.","lua_type":"number"},{"name":"num2","desc":"The second number.","lua_type":"number"},{"name":"epsilon","desc":"The epsilon to check between the two numbers. Defaults to `0.0001`.","lua_type":"number?"}],"returns":[{"desc":"Whether or not the two numbers are close to each other.","lua_type":"boolean"}],"function_type":"static","source":{"line":206,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"numbersToSequence","desc":"Converts a table of numbers to a NumberSequence grouped by split points. This is very useful when working with UI Gradient\'s transparency.\\n\\n```lua\\nlocal values = {4, 8}\\nlocal sequence = MathUtil.numbersToSequence(values, 0.5)\\n\\n-- The sequence will be 4 at 0, 4 at 0.5, 8 at 0.5 + EPSILON, and 8 at 1.\\n```","params":[{"name":"values","desc":"The values to convert to a NumberSequence.","lua_type":"{ number } | number"},{"name":"splitPoints","desc":"The points along the line at which the values are split. Optional only if there is one value.","lua_type":"({number} | number)?"}],"returns":[{"desc":"The generated NumberSequence.","lua_type":"NumberSequence"}],"function_type":"static","source":{"line":225,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}},{"name":"operate","desc":"Performs a math operation on two numbers.","params":[{"name":"a","desc":"","lua_type":"number"},{"name":"operator","desc":"","lua_type":"string"},{"name":"b","desc":"","lua_type":"number"}],"returns":[{"desc":"","lua_type":"number\\r\\n"}],"function_type":"static","source":{"line":280,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}}],"properties":[],"types":[{"name":"MathOperation","desc":"A type consisting of all the valid math operations in string format.","lua_type":"(\\"+\\" | \\"-\\" | \\"*\\" | \\"/\\" | \\"^\\" | \\"%\\")","source":{"line":15,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}}],"name":"MathUtil","desc":"A library of useful math functions.","source":{"line":9,"path":"lib/tablereplicator/_Index/raild3x_railutil@1.7.1/railutil/MathUtil.luau"}}')}}]);