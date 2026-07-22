-- This file is just here so I can test enum-backed APIs in Lune. It is ignored in actual Roblox code.

if Enum then
	return Enum
end

return {
	RaycastFilterType = {
		Include = 1,
		Exclude = 2,
	},
}