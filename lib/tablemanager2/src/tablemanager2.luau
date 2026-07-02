--!strict
local TableManager = require("./TableManager")

export type Proxy<T, S> = TableManager.Proxy<T, S>
export type AppliedOp = TableManager.AppliedOp
export type DuplicateReferenceMode = TableManager.DuplicateReferenceMode
export type TableManagerConfig = TableManager.TableManagerConfig
export type ForOptions = TableManager.ForOptions
export type TableManager<T = { [any]: any }> = TableManager.TableManager<T>
export type OpaqueWrapper<T> = TableManager.OpaqueWrapper<T>
export type TM_Internal<T = { [any]: any }> = TableManager.TM_Internal<T>

return TableManager
