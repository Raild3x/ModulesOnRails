--!nocheck
-- Emitted by coverage-engine; do not edit.
local TOTAL = 87
local hits = table.create(TOTAL, 0)
local rt = { hits = hits, total = TOTAL, map_sha = "<SHA>" }
function rt.cov(i) hits[i] += 1 end
function rt.covd(i, v) if v then hits[i] += 1 else hits[i + 1] += 1 end return v end
function rt.covl(i, n) if n == 0 then hits[i] += 1 elseif n == 1 then hits[i + 1] += 1 else hits[i + 2] += 1 end end
function rt.new_baseline() return table.create(TOTAL, 0) end
function rt.delta(prev)
	local changed = {}
	for i = 1, TOTAL do
		local h = hits[i]
		if h ~= prev[i] then
			table.insert(changed, i)
			prev[i] = h
		end
	end
	return changed
end
_G.__TM_COVERAGE_RT__ = rt
return rt
