type OutputPattern = true | string | { string }

type OutputSpec = {
	print: OutputPattern?,
	warn: OutputPattern?,
	error: OutputPattern?,
}

type expectChain = {
	exists: () -> expectChain,
	never_exists: () -> expectChain,
	is: (value: any) -> expectChain,
	is_not: (value: any) -> expectChain,
	never_is: (value: any) -> expectChain,
	is_shallow_equal: (value: { [any]: any }) -> expectChain,
	is_deep_equal: (value: { [any]: any }) -> expectChain,
	is_true: () -> expectChain,
	never_is_true: () -> expectChain,
	is_a: (valueType: string) -> expectChain,
	never_is_a: (valueType: string) -> expectChain,
	has_key: (key: any) -> expectChain,
	never_has_key: (key: any) -> expectChain,
	has_value: (value: any) -> expectChain,
	never_has_value: (value: any) -> expectChain,
	fails: () -> expectChain,
	never_fails: () -> expectChain,
	fails_with: (message: string) -> expectChain,
	never_fails_with: (message: string) -> expectChain,
	outputs: (spec: OutputSpec, timeout: number?) -> expectChain,
	never_outputs: (spec: OutputSpec, timeout: number?) -> expectChain,
	prints: (pattern: OutputPattern?, timeout: number?) -> expectChain,
	never_prints: (pattern: OutputPattern?, timeout: number?) -> expectChain,
	warns: (pattern: OutputPattern?, timeout: number?) -> expectChain,
	never_warns: (pattern: OutputPattern?, timeout: number?) -> expectChain,
	errors: (pattern: OutputPattern?, timeout: number?) -> expectChain,
	never_errors: (pattern: OutputPattern?, timeout: number?) -> expectChain,
	is_greater_than: (value: number) -> expectChain,
	is_less_than: (value: number) -> expectChain,
	is_greater_or_equal_to: (value: number) -> expectChain,
	is_less_or_equal_to: (value: number) -> expectChain,
	with_context: (...any) -> expectChain,
}

type expect = (value: any) -> expectChain

type contextEntry = {
	id: any,
	data: any,
	is_anonymous: boolean,
}

type context = {
	push: (id_or_data: any, data: any?) -> any,
	set: (id: any, data: any) -> (),
	get: (...any) -> { contextEntry },
	get_all: (...any) -> { contextEntry },
	pop: (...any) -> (),
	clear: () -> (),
}

export type tiniest = {
	expect: expect,
	context: context,
	test: (name: string, fn: () -> ()) -> (),
	describe: (name: string, fn: () -> ()) -> (),
}
