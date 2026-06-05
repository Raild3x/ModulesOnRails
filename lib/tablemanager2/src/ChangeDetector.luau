--!strict
--[=[
	@class ChangeDetector
	
	Detects and reports nested changes for any value transitions using snapshot-based comparison.
	
	## Responsibilities
	- Capture snapshots of values for later comparison
	- Compare new values against captured snapshots using the Diff module
	- Traverse diff trees using DFS (Depth-First Search) for efficient processing
	- Detect added, removed, and changed keys (including root-level changes)
	- Report granular changes for each nested modification
	- Coordinate with callback system for event firing
	
	## Architecture
	
	### Snapshot-Based Workflow
	ChangeDetector supports two workflows:
	
	**1. Capture-then-check (Recommended for ongoing monitoring):**
	```lua
	detector:CaptureSnapshot(myTable, {"data"})
	-- Make changes to myTable...
	detector:CheckForChanges(myTable) -- Detects changes since snapshot
	```
	
	**2. Direct comparison (For one-off comparisons):**
	```lua
	detector:CheckForChangesBetween(oldTable, newTable, {"data"})
	```
	
	### Example with All Callbacks
	```lua
	local detector = ChangeDetector.new({
		OnKeyAdded = function(path, key, newValue, metadata)
			print("[ADD]", key, "at", table.concat(path, "."), "=", newValue)
			if metadata.Diff then
				print("  Change type:", metadata.Diff.type)
			else
				print("  Ancestor notification - descendant was added")
			end
		end,
		OnKeyRemoved = function(path, key, oldValue, metadata)
			print("[REMOVE]", key, "from", table.concat(path, "."), "was", oldValue)
			if metadata.Diff then
				print("  Change type:", metadata.Diff.type)
			else
				print("  Ancestor notification - descendant was removed")
			end
		end,
		OnKeyChanged = function(path, key, newValue, oldValue, metadata)
			if metadata.Diff then
				-- Leaf change - values are meaningful
				print("[CHANGE]", key, "at", table.concat(path, "."), ":", oldValue, "->", newValue)
				print("  Direct change type:", metadata.Diff.type)
			else
				-- Ancestor notification - newValue/oldValue are nil
				print("[ANCESTOR]", key, "at", table.concat(path, "."), "has descendant changes")
			end
		end,
		OnValueChanged = function(path, newValue, oldValue, metadata)
			if metadata.Diff then
				print("[VALUE]", table.concat(path, "."), ":", oldValue, "->", newValue)
				print("  Change type:", metadata.Diff.type)
				
				-- Check for nested changes
				if metadata.Diff.children then
					print("  Has descendant changes")
				end
			else
				print("[ANCESTOR VALUE]", table.concat(path, "."), "has descendant changes")
			end
		end,
	})
	
	local gameData = {
		player = { name = "Alice", level = 5 },
		settings = { volume = 80 }
	}
	
	detector:CaptureSnapshot(gameData, {})
	
	-- Make various changes
	gameData.player.name = "Bob"           -- Change
	gameData.player.coins = 100            -- Add
	gameData.settings = nil                -- Remove (table to nil)
	
	detector:CheckForChanges(gameData)
	```
	
	### Comprehensive Change Detection
	ChangeDetector uses the Diff module to handle all value transition types:
	1. **Table → Table**: Deep comparison with nested change detection
	2. **Scalar → Scalar**: Simple value changes at any path level
	3. **Table → Scalar**: All table leaves removed, then scalar added
	4. **Scalar → Table**: Scalar removed, then all table leaves added
	5. **nil Transitions**: Proper handling of nil ↔ value changes
	6. **Root-Level Changes**: Supports changes at the root path (empty path)
	
	### Tree-Based Diffing
	The Diff module generates a tree structure representing changes:
	- Nodes contain `type`, `old`, `new`, and optional `children`
	- "descendantChanged" nodes represent containers with changed children
	- ChangeDetector uses DFS (Depth-First Search) to traverse the tree efficiently
	- DFS uses less memory than BFS (O(depth) vs O(width)) and has better cache locality
	- Callbacks are fired in depth-first order: parent containers, then their children recursively
	- After processing the diff tree, ancestor callbacks are fired up the path hierarchy
	- Snapshots capture both values and references for accurate change detection
	
	### Ancestor Propagation
	When changes are detected, callbacks fire for:
	1. **Leaf changes** (direct changes in the diff tree - each individual change)
	2. **Ancestor propagation** (all parent levels up to root - ONE notification per assignment)
	
	**Important:** The `OriginPath` in ancestor callbacks represents WHERE THE ASSIGNMENT OPERATION
	OCCURRED (the captured path), NOT individual leaf changes. This treats an assignment as a
	singular operation, even if multiple descendants changed.
	
	Example: If you capture at `Player.Stats` with path `{"Player", "Stats"}`,
	then assign a new stats table with changes to Health, Mana, and Level:
	
	**Leaf callbacks** (fired for each individual change):
	- `OnValueChanged({"Player", "Stats", "Health"}, 50, 100, metadata)` - metadata.Diff present
	- `OnValueChanged({"Player", "Stats", "Mana"}, 150, 100, metadata)` - metadata.Diff present  
	- `OnValueChanged({"Player", "Stats", "Level"}, 6, 5, metadata)` - metadata.Diff present
	
	**Ancestor callbacks** (fired ONCE for the entire assignment operation):
	- `OnValueChanged({"Player"}, nil, nil, metadata)` - metadata.Diff = nil, OriginPath = {"Player", "Stats"}
	- `OnValueChanged({}, nil, nil, metadata)` - metadata.Diff = nil, OriginPath = {"Player", "Stats"}
	
	Notice: Ancestors fire ONCE with OriginPath pointing to the assignment location, treating
	the entire multi-leaf change as a single operation. This prevents ancestors from being
	notified separately for every descendant change.
	
	### Event Callbacks
	ChangeDetector accepts callbacks for each type of change:
	- OnKeyAdded: Called when a new key is added (not called for root-level additions)
	- OnKeyRemoved: Called when a key is removed (not called for root-level removals)
	- OnKeyChanged: Called when a key's value changes (not called for root-level changes)
	- OnValueChanged: Called for any value change at any level (including root)
	
	**Leaf vs Ancestor Callbacks:**
	- **Leaf callbacks**: `metadata.Diff` is present, `newValue`/`oldValue` are meaningful
	- **Ancestor callbacks**: `metadata.Diff` is nil, `newValue`/`oldValue` are nil
	
	Ancestor callbacks indicate "a descendant changed" without providing the actual
	values at that level. This is by design to avoid expensive table traversals.
	If you need the actual values at ancestor levels, maintain your own state tracking.
	
	This allows the detector to remain independent of the event system.
]=]

local Diff = require("./Diff")
local PathHelpers = require("./PathHelpers")

--// Types //--
type Path = PathHelpers.Path

--[=[
	A snapshot object that captures the state of a table at a specific point in time.
	This object can be passed to CheckForChanges() to detect changes at any point
	in the table's history.
	
	**Structure:**
	- `RootTable`: Reference to the root table being tracked (for ancestor navigation)
	- `Path`: The path where the snapshot was captured (e.g., {"Player", "Stats"})
	- `Data`: The Diff.Snapshot of the value at the captured path
	- `Timestamp`: Optional timestamp for debugging
	
	**Benefits:**
	- Historical diffing: Compare current state against any previous snapshot
	- Better encapsulation: Snapshot carries all context needed for diffing
	- Multiple snapshots: Track changes from different points simultaneously
	- Ancestor value access: Root table + path allows callbacks to navigate to true values
	
	```lua
	local gameState = { player = { stats = { Health = 100 } } }
	
	-- Capture snapshot at a nested path
	local snapshot = detector:CaptureSnapshot(gameState, {"player", "stats"})
	
	-- Make changes
	gameState.player.stats.Health = 50
	
	-- Check changes against specific snapshot
	detector:CheckForChanges(snapshot)
	
	-- Can keep multiple snapshots for different comparison points
	local snapshot2 = detector:CaptureSnapshot(gameState, {"player", "stats"})
	gameState.player.stats.Health = 25
	detector:CheckForChanges(snapshot1) -- Shows Health: 100 -> 25
	detector:CheckForChanges(snapshot2) -- Shows Health: 50 -> 25
	```
]=]
export type Snapshot = {
	RootTable: { [any]: any }, -- Reference to root table (for navigation)
	Path: Path, -- Path where snapshot was captured
	Data: Diff.Snapshot, -- Diff.Snapshot of the value at Path
	Timestamp: number, -- Timestamp when snapshot was captured
}

export type ChangeDetector = {
	CaptureSnapshot: (self: ChangeDetector, rootTable: { [any]: any }, path: Path) -> Snapshot,
	CheckForChanges: (self: ChangeDetector, snapshot: Snapshot) -> (),
	CheckForChangesBetween: (
		self: ChangeDetector,
		oldValue: any,
		newValue: any,
		basePath: Path,
		rootTable: { [any]: any }?
	) -> (),
	SetDebugMode: (self: ChangeDetector, enabled: boolean) -> (),
	--- Suspends change detection. While suspended, `CaptureSnapshot` and
	--- `CheckForChanges` are no-ops (O(1)). Used by `TableManager:Batch()`.
	Suspend: (self: ChangeDetector) -> (),
	--- Resumes change detection after a `Suspend` call.
	Resume: (self: ChangeDetector) -> (),
}

--[=[
	Metadata about a detected change, providing rich context to callbacks.
	
	This structure is designed to clearly distinguish between leaf changes (individual
	modifications) and ancestor notifications (parent levels being informed of the operation).
	
	**Structure:**
	- `Diff`: The DiffNode for this callback's level (nil for ancestor callbacks)
	- `OriginPath`: The path where the ASSIGNMENT OPERATION occurred (captured path)
	- `OriginDiff`: The root DiffNode of the assignment operation (ALWAYS present)
	- `Snapshot`: The snapshot object used for this comparison (provides full context)
	
	**For leaf callbacks** (individual changes within the operation):
	- `Diff` is present (details of this specific change)
	- `path` parameter shows where this specific leaf changed
	- `newValue`/`oldValue` parameters reflect this leaf's actual changed values
	- `OriginPath` points to the assignment operation that caused this leaf to change
	- Use `metadata.Diff.type` to determine change type: "added", "removed", "changed"
	
	**For ancestor callbacks** (parent levels being notified of the operation):
	- `Diff` is nil (no direct change at this level)
	- `OriginPath` points to where the assignment operation occurred (captured path)
	- `OriginDiff` contains the root diff of the entire operation
	- `newValue` parameter contains the TRUE current value at that ancestor level
	- `oldValue` parameter is the same as `newValue` (not meaningful for ancestors)
	- `Snapshot` provides full context (root table + path)
	- Ancestors are notified ONCE per assignment operation, not per leaf change
	
	**Ancestor Values:**
	Unlike the old design, ancestor callbacks now receive the TRUE current value as `newValue`.
	The detector navigates to each ancestor level using `snapshot.RootTable` and the path,
	then passes the actual current value to the callback. This is much more convenient than
	requiring every callback to navigate manually.
	
	```lua
	OnKeyChanged = function(path, key, newValue, oldValue, metadata)
		if metadata.Diff == nil then  -- Ancestor callback
			-- newValue is the TRUE current value at this level!
			print(`Ancestor at {table.concat(path, ".")}.{key}`)
			print(`Current value: {newValue}`)  -- Already navigated for you
			print(`Origin: {table.concat(metadata.OriginPath, ".")}`)
		else
			-- Leaf callback
			print(`Leaf change: {oldValue} -> {newValue}`)
		end
	end
	```
	
	**Key Concept - Assignment as Operation:**
	When you assign `player.stats = newStats` (captured at `{"player", "stats"}`),
	the OriginPath is `{"player", "stats"}` for ALL callbacks (leaf and ancestor),
	because that's where the assignment operation occurred. This treats the entire
	change (possibly affecting Health, Mana, Level, etc.) as a single operation.
	
	**Why OriginDiff is Always Present:**
	Every callback is triggered because SOME change was detected. That change is
	represented by `OriginDiff` (the root diff at the captured path). Whether it's
	a leaf callback or ancestor callback, there's always an origin diff that caused
	the notification. There's no case where we'd fire a callback without a change.
	
	Example:
	```lua
	-- Capture at {"player", "stats"}
	-- Assign new stats: { health = 50, mana = 150, level = 6 }
	
	OnValueChanged = function(path, newValue, oldValue, metadata)
		if metadata.Diff then
			-- Leaf callback - one per changed field
			print("Leaf change at:", table.concat(path, "."))  -- e.g., "player.stats.health"
			print("Value:", oldValue, "->", newValue)
			print("Operation at:", table.concat(metadata.OriginPath, "."))  -- "player.stats"
		else
			-- Ancestor callback - fired ONCE for entire operation
			print("Ancestor at:", table.concat(path, "."))  -- e.g., "player"
			print("Current value:", newValue)  -- TRUE current player table!
			print("Operation at:", table.concat(metadata.OriginPath, "."))  -- "player.stats"
		end
	end
	```
]=]
export type ChangeMetadata = {
	-- The diff node for the current callback's level
	-- Present for leaf changes, nil for ancestor notifications
	Diff: Diff.DiffNode?,

	-- The path where the assignment operation occurred (captured path)
	-- Always present for all callbacks
	OriginPath: Path,

	-- The root diff node of the assignment operation
	-- ALWAYS present (not optional) - every callback has an origin diff
	OriginDiff: Diff.DiffNode,

	-- The snapshot object used for this comparison
	-- Provides root table reference and path for ancestor value navigation
	Snapshot: Snapshot,
}

--------------------------------------------------------------------------------
--// Module //--
--------------------------------------------------------------------------------

local ChangeDetector = {}
local ChangeDetector_MT = { __index = ChangeDetector }

--------------------------------------------------------------------------------
--// Constructor //--
--------------------------------------------------------------------------------

--[=[
	Creates a new ChangeDetector instance.
	
	@param callbacks -- Callbacks for different change events
	@param debugMode -- Optional flag to enable debug logging
	@return ChangeDetector
]=]
function ChangeDetector.new(
	callbacks: {
		OnKeyAdded: (path: Path, key: any, newValue: any, metadata: ChangeMetadata) -> ()?,
		OnKeyRemoved: (path: Path, key: any, oldValue: any, metadata: ChangeMetadata) -> ()?,
		OnKeyChanged: (path: Path, key: any, newValue: any, oldValue: any, metadata: ChangeMetadata) -> ()?,
		OnValueChanged: (path: Path, newValue: any, oldValue: any?, metadata: ChangeMetadata) -> ()?,
		FireDescendantChangedNodes: boolean?,
	},
	debugMode: boolean?
): ChangeDetector
	callbacks.OnKeyAdded = callbacks.OnKeyAdded or function() end
	callbacks.OnKeyRemoved = callbacks.OnKeyRemoved or function() end
	callbacks.OnKeyChanged = callbacks.OnKeyChanged or function() end
	callbacks.OnValueChanged = callbacks.OnValueChanged or function() end

	local self = setmetatable(
		{
			_callbacks = callbacks,
			_fireDescendantChangedNodes = callbacks.FireDescendantChangedNodes ~= false,
			_debugMode = debugMode or false,
			_suspended = false,
			-- Sentinel snapshot: a fixed table that CaptureSnapshot returns when
			-- suspended. CheckForChanges recognises it and returns immediately.
			_sentinelSnapshot = {} :: any,
		} :: any,
		ChangeDetector_MT
	) :: ChangeDetector

	return self
end

--------------------------------------------------------------------------------
--// Public Methods //--
--------------------------------------------------------------------------------

--[=[
	Captures a snapshot of the table at the specified path and returns a snapshot object.
	
	This method navigates to the value at the given path, captures a Diff.Snapshot of it,
	and returns a snapshot object that can be passed to CheckForChanges() later to detect
	changes at any point in the table's history.
	
	**Returns:** A Snapshot object containing:
	- RootTable: Reference to the root table (for ancestor navigation)
	- Path: The path where the snapshot was captured
	- Data: The Diff.Snapshot of the value at that path
	- Timestamp: When the snapshot was captured
	
	@param rootTable -- The root table to track changes on
	@param path -- The path to the value to snapshot (e.g., {"player", "stats"})
	@return Snapshot object that can be passed to CheckForChanges()
	
	```lua
	local detector = ChangeDetector.new({
		OnValueChanged = function(path, newValue, oldValue, metadata)
			if metadata.Diff then
				print("Changed at:", table.concat(path, "."))
				print("  Old:", oldValue, "-> New:", newValue)
			else
				-- Ancestor callback - can access true value via snapshot
				local current = metadata.Snapshot.RootTable
				for _, k in ipairs(path) do
					current = current[k]
				end
				print("Ancestor at:", table.concat(path, "."))
				print("  Current value:", current)
			end
		end,
	})
	
	local gameState = { 
		player = { 
			health = 50, 
			level = 1 
		} 
	}
	
	-- Capture the current state and get snapshot object
	local snapshot = detector:CaptureSnapshot(gameState, {"player"})
	
	-- Make changes to gameState
	gameState.player.health = 100
	gameState.player.level = 5
	
	-- Detect changes using the snapshot
	detector:CheckForChanges(snapshot)
	
	-- Can capture multiple snapshots for different comparison points
	local snapshot2 = detector:CaptureSnapshot(gameState, {"player"})
	gameState.player.health = 25
	
	detector:CheckForChanges(snapshot)  -- Shows changes from first capture
	detector:CheckForChanges(snapshot2) -- Shows changes from second capture
	```
]=]
function ChangeDetector:CaptureSnapshot(rootTable: { [any]: any }, path: Path): Snapshot
	-- While suspended, skip all snapshot work and return the sentinel.
	-- CheckForChanges will recognise it and return immediately too.
	if self._suspended then
		return self._sentinelSnapshot
	end

	if type(rootTable) ~= "table" then
		error("CaptureSnapshot expects rootTable to be a plain table.")
	end

	if self._debugMode then
		print("CaptureSnapshot called:")
		print("  path:", table.concat(path, "."))
		print("  rootTable type:", type(rootTable))
	end

	-- Navigate to the value at the path
	local valueAtPath = rootTable
	for _, key in ipairs(path) do
		if valueAtPath == nil then
			error(`Failed to reach key: {key}, Path {table.concat(path, ".")} does not exist in table`)
		end
		valueAtPath = valueAtPath[key]
	end

	-- Create snapshot using Diff.snapshot (includes reference tracking)
	local snapshot: Snapshot = {
		RootTable = rootTable, -- Keep reference to root (not copied)
		Path = table.clone(path), -- Clone the path array
		Data = Diff.snapshot(valueAtPath), -- Diff.Snapshot with ref tracking
		Timestamp = os.clock(),
	}

	return snapshot
end

--[=[
	Checks for changes between a captured snapshot and the current state of the table.
	
	This method accepts a snapshot object (returned from CaptureSnapshot) and compares
	it against the current state of the table, detecting all changes that occurred.
	The snapshot object contains all the context needed: the root table reference, the
	path, and the captured data.
	
	@param snapshot -- The snapshot object to compare against (from CaptureSnapshot)
	
	```lua
	local detector = ChangeDetector.new({
		OnKeyRemoved = function(path, key, oldValue, metadata)
			print("Key removed:", key, "from", table.concat(path, "."))
			print("  Had value:", oldValue)
		end,
		OnValueChanged = function(path, newValue, oldValue, metadata)
			if metadata.Diff then
				print("Value at", table.concat(path, "."), "changed")
				print("  ", oldValue, "->", newValue)
			else
				-- Ancestor callback - access true value via snapshot
				local current = metadata.Snapshot.RootTable
				for _, k in ipairs(path) do
					current = current[k]
				end
				print("Ancestor at", table.concat(path, "."), "has changes")
				print("  Current:", current)
			end
		end,
	})
	
	local myTable = { 
		player = { 
			name = "Alice", 
			inventory = { "sword", "shield" } 
		} 
	}
	
	local snapshot = detector:CaptureSnapshot(myTable, {"player"})
	
	-- Make changes...
	myTable.player.name = "Bob"
	myTable.player.inventory = nil
	
	-- Detect changes
	detector:CheckForChanges(snapshot)
	
	-- Output:
	-- Value at player.name changed
	--   Alice -> Bob
	-- Key removed: inventory from player
	--   Had value: table
	-- Ancestor at player has changes
	--   Current: { name = "Bob" }
	```
]=]
function ChangeDetector:CheckForChanges(snapshot: Snapshot)
	-- Sentinel returned by CaptureSnapshot while suspended — nothing to diff.
	if snapshot == self._sentinelSnapshot then
		return
	end

	if not snapshot or not snapshot.RootTable then
		error("Invalid snapshot object. Must be created with CaptureSnapshot().")
	end

	if type(snapshot.RootTable) ~= "table" then
		error("Invalid snapshot object. Snapshot.RootTable must be a plain table.")
	end

	if self._debugMode then
		print("CheckForChanges called:")
		print("  path:", table.concat(snapshot.Path, "."))
		print("  timestamp:", snapshot.Timestamp)
	end

	-- Navigate to current state using stored path and root table reference
	local currentValue = snapshot.RootTable
	for _, key in ipairs(snapshot.Path) do
		currentValue = currentValue[key]
		if currentValue == nil then
			-- Path no longer exists - entire subtree was removed
			break
		end
	end

	-- Use diffFromSnapshot to compare against the captured Diff.Snapshot
	local rootDiffNode = Diff.diffFromSnapshot(snapshot.Data, currentValue)

	-- Process the root node if there are changes
	if rootDiffNode then
		local rootParentPath: Path = {}
		local rootKey: any? = nil
		if #snapshot.Path > 0 then
			rootParentPath = table.create(#snapshot.Path - 1)
			table.move(snapshot.Path, 1, #snapshot.Path - 1, 1, rootParentPath)
			rootKey = snapshot.Path[#snapshot.Path]
		end

		-- Process all leaf changes via DFS
		-- Pass the snapshot to all callbacks for context
		self:_processDiffNode(
			rootDiffNode,
			snapshot.Path,
			rootParentPath,
			rootKey,
			snapshot.Path,
			rootDiffNode,
			snapshot
		)

		-- Fire ancestor callbacks for the captured level
		-- The origin is the captured path (where the assignment happened)
		self:_fireAncestorCallbacks(snapshot.Path, rootDiffNode, snapshot)
	end
end

--[=[
	Directly compares two values and detects changes without requiring a snapshot.
	
	This is a convenience method for one-off comparisons when you don't need
	the snapshot-based workflow. Use this when you have both old and new values
	available at the same time.
	
	@param oldValue -- The old value (before change)
	@param newValue -- The new value (after change)
	@param basePath -- The path to this value in the table hierarchy
	
	```lua
	local detector = ChangeDetector.new({
		OnKeyChanged = function(path, key, newValue, oldValue, changeType)
			print("Key", key, "changed at", table.concat(path, "."))
			print("  Old:", oldValue, "-> New:", newValue)
		end,
		OnKeyAdded = function(path, key, newValue, changeType)
			print("Key", key, "added at", table.concat(path, "."))
			print("  Value:", newValue)
		end,
	})
	
	local oldTable = { 
		config = { 
			host = "localhost", 
			port = 8080 
		} 
	}
	local newTable = { 
		config = { 
			host = "example.com", 
			port = 8080,
			ssl = true
		} 
	}
	
	-- Direct comparison without snapshot
	detector:CheckForChangesBetween(oldTable, newTable, {"server"})
	
	-- Output:
	-- Key host changed at server.config.host
	--   Old: localhost -> New: example.com
	-- Key ssl added at server.config.ssl
	--   Value: true
	```
]=]
function ChangeDetector:CheckForChangesBetween(oldValue: any, newValue: any, basePath: Path, rootTable: { [any]: any }?)
	if self._debugMode then
		print("CheckForChangesBetween called:")
		print("  basePath:", table.concat(basePath, "."))
		print("  oldValue type:", type(oldValue))
		print("  newValue type:", type(newValue))
	end

	-- Create a temporary snapshot for the old value.
	-- If no real root table is provided, synthesize one so ancestor callbacks remain
	-- backward-compatible and can still navigate values at `basePath`.
	local tempRootTable: { [any]: any }
	if rootTable then
		tempRootTable = rootTable
	else
		warn(
			"No Root Table Provided. Ancestor callbacks will receive a synthetic root with the changed value at the base path."
		)
		if #basePath == 0 then
			tempRootTable = if type(newValue) == "table" then newValue else { __value = newValue }
		else
			tempRootTable = {}
			local cursor: any = tempRootTable
			for i = 1, #basePath - 1 do
				local segment = basePath[i]
				cursor[segment] = {}
				cursor = cursor[segment]
			end
			cursor[basePath[#basePath]] = newValue
		end
	end
	local tempSnapshot: Snapshot = {
		RootTable = tempRootTable,
		Path = basePath,
		Data = Diff.snapshot(oldValue), -- Snapshot the old value
		Timestamp = os.clock(),
	}

	-- Use Diff module to generate tree
	local rootDiffNode = Diff.diff(oldValue, newValue)

	-- Process the root node if there are changes
	if rootDiffNode then
		local rootParentPath: Path = {}
		local rootKey: any? = nil
		if #basePath > 0 then
			rootParentPath = table.create(#basePath - 1)
			table.move(basePath, 1, #basePath - 1, 1, rootParentPath)
			rootKey = basePath[#basePath]
		end

		-- Process all leaf changes via DFS
		-- Pass the basePath as both the current path and origin
		-- Include the temporary snapshot for context
		self:_processDiffNode(rootDiffNode, basePath, rootParentPath, rootKey, basePath, rootDiffNode, tempSnapshot)

		-- Fire ancestor callbacks for the base level
		-- The origin is the basePath (where the assignment happened)
		self:_fireAncestorCallbacks(basePath, rootDiffNode, tempSnapshot)
	end
end

--[=[
	Sets debug mode on or off.
	
	@param enabled -- Whether to enable debug logging
]=]
function ChangeDetector:SetDebugMode(enabled: boolean)
	self._debugMode = enabled
end

--[=[
	Suspends change detection.

	While suspended, `CaptureSnapshot` returns a cheap sentinel value and
	`CheckForChanges` is a no-op when given that sentinel. This means every
	assignment through `ProxyManager.__newindex` costs O(1) instead of performing
	a full snapshot + diff cycle.

	Used by `TableManager:Suspend()` / `TableManager:Batch()`. Always pair with
	a matching `Resume()` call.
]=]
function ChangeDetector:Suspend()
	self._suspended = true
end

--[=[
	Resumes change detection after a `Suspend` call.
]=]
function ChangeDetector:Resume()
	self._suspended = false
end

--------------------------------------------------------------------------------
--// Private Methods //--
--------------------------------------------------------------------------------

--[=[
	Helper to fire callbacks for a single node in the diff tree.
	Encapsulates the common callback firing logic to reduce duplication.
]=]
local function fireNodeCallbacks(
	callbacks: any,
	basePath: Path,
	nodePath: Path,
	nodeKey: any?,
	diffNode: Diff.DiffNode,
	metadata: ChangeMetadata
)
	local OnKeyAdded = callbacks.OnKeyAdded
	local OnKeyRemoved = callbacks.OnKeyRemoved
	local OnKeyChanged = callbacks.OnKeyChanged
	local OnValueChanged = callbacks.OnValueChanged

	if diffNode.type == "changed" or diffNode.type == "descendantChanged" then
		-- Only fire OnKeyChanged if there's actually a key (not at root level)
		if nodeKey ~= nil then
			OnKeyChanged(basePath, nodeKey, diffNode.new, diffNode.old, metadata)
		end
		OnValueChanged(nodePath, diffNode.new, diffNode.old, metadata)
	elseif diffNode.type == "added" then
		-- Only fire OnKeyAdded if there's actually a key (not at root level)
		if nodeKey ~= nil then
			OnKeyAdded(basePath, nodeKey, diffNode.new, metadata)
		end
		OnValueChanged(nodePath, diffNode.new, nil, metadata)
	elseif diffNode.type == "removed" then
		-- Only fire OnKeyRemoved if there's actually a key (not at root level)
		if nodeKey ~= nil then
			OnKeyRemoved(basePath, nodeKey, diffNode.old, metadata)
		end
		OnValueChanged(nodePath, nil, diffNode.old, metadata)
	end
end

--[=[
	Processes a single diff node and recursively processes its children using DFS.
	
	This method processes nodes in depth-first order:
	1. Recursively process all children (depth-first)
	2. Fire callbacks for leaf nodes (actual changes)
	
	**Important:** `descendantChanged` nodes are NOT leaf changes - they're containers.
	We only fire callbacks for actual changes (added, removed, changed), not for containers.
	
	The `OriginPath` in metadata represents the captured path (where the assignment occurred),
	NOT the individual leaf path. The `OriginDiff` represents the root diff of the entire
	operation. The `Snapshot` provides context for ancestor callbacks to access true values.
	
	@param node -- The diff node to process
	@param nodePath -- The full path to this node in the hierarchy
	@param originPath -- The path where the assignment operation occurred (captured path)
	@param originDiff -- The root diff node of the assignment operation
	@param snapshot -- The snapshot object used for this comparison
]=]
function ChangeDetector:_processDiffNode(
	node: Diff.DiffNode,
	nodePath: Path,
	parentPath: Path,
	nodeKey: any?,
	originPath: Path,
	originDiff: Diff.DiffNode,
	snapshot: Snapshot
)
	local callbacks = self._callbacks
	local debugMode = self._debugMode

	if debugMode then
		print(`Processing diff node at path: {table.concat(nodePath, ".")}, type: {node.type}`)
	end

	-- Recurse into children if present
	if node.children then
		for key, childNode in node.children do
			local childKey = if key ~= "" then key else nil
			local childPath = table.clone(nodePath)
			local childParentPath = parentPath
			local childNodeKey = childKey

			if childKey then
				table.insert(childPath, childKey)
				childParentPath = nodePath
			else
				-- Sentinel child ("") represents a scalar replacement at this exact node.
				-- It keeps the same nodePath and key as its parent node.
				childNodeKey = nodeKey
			end

			-- Pass the same origin path, origin diff, and snapshot down through recursion
			self:_processDiffNode(childNode, childPath, childParentPath, childNodeKey, originPath, originDiff, snapshot)
		end
	end

	if node.type == "descendantChanged" and not self._fireDescendantChangedNodes then
		return
	end

	-- Create metadata for this node
	-- OriginPath is the captured path (where the assignment occurred)
	-- OriginDiff is the root diff (the entire operation)
	-- Snapshot provides context for ancestor value navigation
	local metadata: ChangeMetadata = {
		Diff = node,
		OriginPath = originPath, -- Where the assignment happened
		OriginDiff = originDiff, -- The root diff of the entire operation
		Snapshot = snapshot, -- Snapshot object with root table + path
	}

	-- Fire callbacks for this node
	fireNodeCallbacks(callbacks, parentPath, nodePath, nodeKey, node, metadata)
end

--[=[
	Fires OnKeyChanged and OnValueChanged callbacks for all ancestor levels above the captured base path.
	
	This propagates changes up through the hierarchy for levels that are parents of the captured
	snapshot point. The origin represents WHERE THE ASSIGNMENT OPERATION OCCURRED, not individual
	leaf changes. This method navigates to the true current values at each ancestor level and
	passes them to the callbacks.
	
	For example, if you capture at `Player.Stats` with path `{"Player", "Stats"}`,
	and change multiple descendants (Health, Mana), this fires ancestor callbacks with 
	`OriginPath = {"Player", "Stats"}` because that's where the assignment happened:
	- Player level: OnKeyChanged({}, "Player", <current player table>, nil, metadata)
	- Player value: OnValueChanged({"Player"}, <current player table>, nil, metadata)
	- Root level: OnValueChanged({}, <current root table>, nil, metadata)
	
	All ancestors receive the SAME origin - the captured path - because the entire change
	is a single operation at that level, even if it contains multiple leaf changes.
	
	**Note:** We pass the true current value as `newValue` but `oldValue` is nil because
	we don't have the old ancestor values captured. This is by design - ancestor callbacks
	are about notification that descendants changed, not about tracking the ancestor's
	own value changes.
	
	@param capturedPath -- The path where the snapshot was captured (where the assignment happened)
	@param rootDiff -- The root diff node representing the captured level's changes
	@param snapshot -- The snapshot object used for this comparison
]=]
function ChangeDetector:_fireAncestorCallbacks(capturedPath: Path, rootDiff: Diff.DiffNode, snapshot: Snapshot)
	-- If captured at root level (empty path), no ancestors to notify
	if #capturedPath == 0 then
		return
	end

	if self._debugMode then
		print(`Firing ancestor callbacks above captured path: {table.concat(capturedPath, ".")}`)
	end

	local callbacks = self._callbacks
	local OnKeyChanged = callbacks.OnKeyChanged
	local OnValueChanged = callbacks.OnValueChanged

	-- Create metadata for ancestor notifications
	-- Diff is nil to indicate these are ancestor notifications
	-- OriginPath is the captured path (where the assignment operation occurred)
	-- Snapshot provides context for ancestor value access
	local metadata: ChangeMetadata = {
		Diff = nil,
		OriginPath = capturedPath,
		OriginDiff = rootDiff,
		Snapshot = snapshot,
	}

	-- Walk up from the PARENT of the captured level to root
	-- Start at i = #capturedPath - 1 to skip the captured level (already processed by DFS)
	for i = #capturedPath - 1, 1, -1 do
		local currentPath = { unpack(capturedPath, 1, i) }
		local parentPath = if i > 1 then { unpack(capturedPath, 1, i - 1) } else {}
		local key = capturedPath[i]

		-- Navigate to the current value at this ancestor level once and reuse it.
		local currentValue = snapshot.RootTable
		for _, k in ipairs(currentPath) do
			currentValue = currentValue[k]
			if currentValue == nil then
				break
			end
		end

		-- Get the value at the key for OnKeyChanged
		local keyValue = nil
		if currentValue ~= nil and type(currentValue) == "table" then
			keyValue = currentValue[key]
		end

		if self._debugMode then
			print(
				`  Ancestor: parentPath=[{table.concat(parentPath, ", ")}], key={key}, currentPath=[{table.concat(
					currentPath,
					", "
				)}], value type={type(keyValue)}`
			)
		end

		-- Fire OnKeyChanged for this level with the true current value
		OnKeyChanged(parentPath, key, keyValue, nil, metadata)

		-- Fire OnValueChanged for this level with the true current value
		OnValueChanged(currentPath, currentValue, currentValue, metadata)
	end

	-- Always fire OnValueChanged for root (unless captured at root)
	if #capturedPath > 0 then
		-- Root is just the RootTable itself
		OnValueChanged({}, snapshot.RootTable, snapshot.RootTable, metadata)
	end
end

return ChangeDetector
