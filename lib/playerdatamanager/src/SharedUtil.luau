-- Authors: Logan Hunt (Raildex)
-- June 01, 2026
--[=[
    @class SharedUtil
    @ignore

    Shared constants and helpers used by both ClientPlayerDataManager and ServerPlayerDataManager.
]=]

local RunService = game:GetService("RunService")

local SharedUtil = {
	DEFAULT_MANAGER_NAME = "DefaultManager",
	REGISTERED_MANAGERS_FOLDER_NAME = "RegisteredServerManagers",
	ACTIVE_NAMESPACE_REGISTRY_FOLDER_NAME = "ActivePlayerDataManagers",
	CLIENT_ERROR_PREFIX = "[📥]",
	SERVER_ERROR_PREFIX = "[📤]",
	TOKEN_SEPARATOR = "/",
}

--- Returns the error prefix and manager class name for the active run context.
function SharedUtil.getRunContextInfo(): (string, string)
	if RunService:IsServer() then
		return SharedUtil.SERVER_ERROR_PREFIX, "ServerPlayerDataManager"
	end
	return SharedUtil.CLIENT_ERROR_PREFIX, "ClientPlayerDataManager"
end

--- Builds a duplicate-namespace error message using the current run context.
function SharedUtil.getDuplicateNamespaceMessage(nameSpace: string): string
	local prefix, contextName = SharedUtil.getRunContextInfo()
	return `{prefix} A {contextName} instance already exists for namespace '{nameSpace}'. Use a unique namespace.`
end

--- Gets a named Folder child or creates it if it does not already exist.
function SharedUtil.getOrCreateFolder(parent: Instance, name: string): Folder
	local existingFolder = parent:FindFirstChild(name)
	if existingFolder then
		return existingFolder :: Folder
	end

	local newFolder = Instance.new("Folder")
	newFolder.Name = name
	newFolder.Parent = parent
	return newFolder
end

--- Reserves a namespace by creating a Folder under a registry Folder.
function SharedUtil.reserveFolderNamespace(registryName: string, nameSpace: string, errorMessage: string?): Folder
	local registryFolder = SharedUtil.getOrCreateFolder(script.Parent, registryName)
	assert(
		not registryFolder:FindFirstChild(nameSpace),
		errorMessage or SharedUtil.getDuplicateNamespaceMessage(nameSpace)
	)

	local reservationFolder = Instance.new("Folder")
	reservationFolder.Name = nameSpace
	reservationFolder.Parent = registryFolder
	return reservationFolder
end

--- Creates the fully-qualified token name used by client/server replicators.
function SharedUtil.getTokenName(nameSpace: string, managerName: string): string
	return `{nameSpace}{SharedUtil.TOKEN_SEPARATOR}{managerName}`
end

return table.freeze(SharedUtil)
