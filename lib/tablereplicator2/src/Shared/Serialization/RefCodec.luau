--!strict
--[=[
	@ignore
	@class RefCodec

	Model V table de-duplication for one wire message. A plain Luau table that
	is referenced from two or more places across a single message -- e.g. the
	same inner table living at both `A.B` and `C.B` -- is transmitted ONCE: its
	contents go into the message's `Refs` pool under a per-message id, and every
	occurrence in the items is replaced by a tiny placeholder `{ [Marker] = id }`.

	On the client, each placeholder is expanded back into an INDEPENDENT copy
	per top-level value (`ResolveValue`), so two managers that shared a table on
	the server end up with two equal-but-separate tables -- kept in sync by the
	server's per-manager fan-out ops. Aliasing WITHIN a single resolved value
	(and cycles) is preserved by a per-resolve memo.

	Ids are per-message (Model V needs no cross-frame identity), so this is a
	pure data transform with no module-level state -- no Roblox APIs, directly
	unit-testable. A later phase can fold this into the byte codec as identity
	table-interning (see the plan).
]=]

const FlatCodec = require("./FlatCodec")
const Types = require("../Types")

type RefId = number
type WireItem = Types.WireItem
type RefPool = { [RefId]: any }

-- Reserved single-key marker identifying a placeholder. NUL-prefixed so it
-- cannot collide with an ordinary user table key. A user table literally keyed
-- by this string is the one unsupported case (documented).
const MARKER = "\0RR_REF"

const RefCodec = {}
RefCodec.Marker = MARKER

-- Per-message encode state: reference counts plus the id/definition pool.
type EncodeCtx = {
	Counts: { [any]: number },
	IdByTable: { [any]: RefId },
	Refs: RefPool,
	NextId: RefId,
}

--------------------------------------------------------------------------------
--// Encode //--
--------------------------------------------------------------------------------

-- Tallies how many times each table is referenced across the walked value.
-- First visit descends; later visits don't, so a table's count is its true
-- in-degree and cycles terminate.
const function countRefs(value: any, counts: { [any]: number })
	if type(value) ~= "table" then
		return
	end
	const c = (counts[value] or 0) + 1
	counts[value] = c
	if c == 1 then
		for _, v in value do
			countRefs(v, counts)
		end
	end
end

-- Rebuilds `value` with every shared descendant swapped for a placeholder,
-- emitting each shared table's definition into `ctx.Refs` exactly once.
-- Self-recursive only (no forward declaration): a shared table reserves its id
-- before its children are walked, so a cycle back to it resolves to a
-- placeholder instead of recursing forever.
const function transform(ctx: EncodeCtx, value: any): any
	if type(value) ~= "table" then
		return value
	end

	if (ctx.Counts[value] or 0) >= 2 then
		local id = ctx.IdByTable[value]
		if id == nil then
			id = ctx.NextId
			ctx.NextId += 1
			ctx.IdByTable[value] = id

			const def = {}
			ctx.Refs[id] = def -- reserve before recursing (cycles)
			for k, v in value do
				def[k] = transform(ctx, v)
			end
		end
		return { [MARKER] = id }
	end

	-- Non-shared table: rebuild so any shared descendant becomes a placeholder.
	-- (Could skip the rebuild for subtrees with no shared descendant; kept
	-- simple for now and only ever runs in messages that actually share.)
	const out = {}
	for k, v in value do
		out[k] = transform(ctx, v)
	end
	return out
end

--[=[
	De-duplicates tables shared across `items`. Returns the (possibly rewritten)
	item list and a `Refs` pool, or the original items and `nil` when nothing is
	shared -- the common no-aliasing case pays only one counting walk and never
	copies.
]=]
function RefCodec.Encode(items: { WireItem }): ({ WireItem }, RefPool?)
	const counts: { [any]: number } = {}
	for _, item in items do
		const anyItem = item :: any
		if anyItem.Op == FlatCodec.Op.Create then
			countRefs(anyItem.Data, counts)
		elseif anyItem.Op == FlatCodec.Op.Ops then
			for _, op in anyItem.Ops do
				countRefs(op.Value, counts)
			end
		end
	end

	local hasShared = false
	for _, c in counts do
		if c >= 2 then
			hasShared = true
			break
		end
	end
	if not hasShared then
		return items, nil
	end

	const ctx: EncodeCtx = { Counts = counts, IdByTable = {}, Refs = {}, NextId = 1 }
	const outItems = table.create(#items) :: { WireItem }
	for i, item in items do
		const anyItem = item :: any
		if anyItem.Op == FlatCodec.Op.Create then
			const newItem = {}
			for k, v in anyItem do
				newItem[k] = v
			end
			newItem.Data = transform(ctx, anyItem.Data)
			outItems[i] = newItem :: any
		elseif anyItem.Op == FlatCodec.Op.Ops then
			const newOps = table.create(#anyItem.Ops)
			for j, op in anyItem.Ops do
				newOps[j] = { Kind = op.Kind, Path = op.Path, Index = op.Index, Value = transform(ctx, op.Value) }
			end
			outItems[i] = { Op = anyItem.Op, Id = anyItem.Id, Ops = newOps } :: any
		else
			outItems[i] = item
		end
	end

	return outItems, ctx.Refs
end

--------------------------------------------------------------------------------
--// Decode //--
--------------------------------------------------------------------------------

-- Rebuilds `value`, expanding each placeholder into a copy from `refs`. `memo`
-- is shared within a single top-level `ResolveValue` call so repeated refs and
-- cycles inside one value resolve to one node; separate calls get separate
-- copies (the Model V "client copies" rule). Self-recursive only.
const function resolveValue(value: any, refs: RefPool, memo: { [RefId]: any }): any
	if type(value) ~= "table" then
		return value
	end

	const id = value[MARKER]
	if id ~= nil then
		const existing = memo[id]
		if existing ~= nil then
			return existing
		end
		const out = {}
		memo[id] = out -- before recursing (cycles)
		for k, v in refs[id] do
			out[k] = resolveValue(v, refs, memo)
		end
		return out
	end

	const out = {}
	for k, v in value do
		out[k] = resolveValue(v, refs, memo)
	end
	return out
end

--[=[
	Resolves all placeholders in one top-level value against `refs`, returning a
	fresh independent copy (see `resolveValue` for the memo/aliasing rule). Call
	once per Create `Data` and once per op `Value`.
]=]
function RefCodec.ResolveValue(value: any, refs: RefPool): any
	return resolveValue(value, refs, {})
end

return RefCodec
