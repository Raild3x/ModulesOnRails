local RunService = game:GetService("RunService")

local Packages = script.Parent.Parent
local Option = require(Packages.Option)

local Util = {}

Util.IsServer = RunService:IsServer()
Util.WaitForChildTimeout = 60
Util.DefaultCommFolderName = "__comm__"
Util.None = newproxy()

function Util.GetCommSubFolder(parent: Instance, subFolderName: string): Option.Option<any>
	local subFolder: Instance = nil
	if Util.IsServer then
		subFolder = parent:FindFirstChild(subFolderName) :: Instance
		if not subFolder then
			local folder = Instance.new("Folder")
			folder.Name = subFolderName
			folder.Parent = parent
			subFolder = folder
		end
	else
		subFolder = parent:WaitForChild(subFolderName, Util.WaitForChildTimeout) :: Instance
	end
	return Option.Wrap(subFolder)
end

return Util
