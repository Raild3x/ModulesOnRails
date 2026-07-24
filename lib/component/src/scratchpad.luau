--!strict

local extension = {}
extension.Methods = {}

function extension.Methods.test(self: CLASS, arg: number): string
	return `test: {arg}`
end

local class = {}
function class.method(self: CLASS, arg: number): string
	return `method: {arg}`
end

function new<A>(config, methods: A): typeof(A)
	return nil :: any
end

local x = new({}, class)
