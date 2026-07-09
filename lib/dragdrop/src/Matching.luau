--[[
	DragDrop — payload/target compatibility gates.

	The single place that decides whether a payload may drop on a target: tag
	overlap first (see Types.Payload), then the target's optional CanDrop.
]]

const Types = require("./Types")

type Payload = Types.Payload
type SourceEntry = Types.SourceEntry
type TargetEntry = Types.TargetEntry

const Matching = {}

-- Does the payload's `Tags` share at least one entry with the target's `Accepts`?
-- A target with no `Accepts` (nil or empty) takes anything. Tags travel with the
-- payload, so a source whose contents vary matches per lift.
function Matching.TagsAccepted(targetEntry: TargetEntry, payload: Payload): boolean
	const accepts = targetEntry.Options.Accepts
	if accepts == nil or #accepts == 0 then
		return true
	end
	const tags = payload.Tags
	if tags == nil then
		return false
	end
	for _, tag in tags do
		if table.find(accepts, tag) then
			return true
		end
	end
	return false
end

-- Full drop gate: tag compatibility, then the target's optional CanDrop.
function Matching.CanDropInto(sourceEntry: SourceEntry?, targetEntry: TargetEntry?, payload: Payload): boolean
	if not sourceEntry or not targetEntry then
		return false
	end
	if not Matching.TagsAccepted(targetEntry, payload) then
		return false
	end
	const predicate = targetEntry.Options.CanDrop
	if predicate then
		const ok, result = pcall(predicate, payload)
		return ok and result == true
	end
	return true
end

return Matching
