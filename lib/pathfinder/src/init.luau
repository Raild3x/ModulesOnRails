-- Author: Logan Hunt (Raild3x)
-- Marc 6, 2025
--[=[
    @class Pathfinder
]=]

local Pathfinder = {}

local RailUtil = require(script.RailUtil)
local Heap = require(script.Heap)
type Heap<T> = Heap.Heap<T>

type PathResult<T> = {
    Success: boolean,
}

function Pathfinder.AStar<T>(config: {
    StartNode: T,
    EndNode: T,
    GetNeighbors: (node: T) -> {T},
    GetTraversalCost: (fromNode: T, toNode: T) -> number,
    Heuristic: (node: T) -> number, -- H-Cost, estimates how favorable the node is to the end node

    PartialPath: boolean?
})
    local startNode, endNode = config.StartNode, config.EndNode
    local getNeighbors, getTraversalCost, heuristic = config.GetNeighbors, config.GetTraversalCost, config.Heuristic
    local partialPath = config.PartialPath or false

    local openSet: Heap<T> = Heap.min()
    local closedSet: {[T]: boolean} = {}

    local cameFrom: {[T]: T} = {}
    local gScore: {[T]: number} = {[startNode] = 0}
    local fCostMap: {[T]: number} = {[startNode] = heuristic(startNode)}

    openSet:Push(startNode, heuristic(startNode))

    local function ReconstructPath(): {T}
        local current = endNode
        local path = {current}
        while current ~= startNode do
            current = cameFrom[current]
            table.insert(path, current)
        end
        RailUtil.Table.Reverse(path)
        return path
    end

    while not openSet:IsEmpty() do
        local current = openSet:Pop()

        if closedSet[current] then
            continue
        end
        closedSet[current] = true
        
        if current == endNode then
            return ReconstructPath()
        end
        
        for _, neighbor in ipairs(getNeighbors(current)) do
            if closedSet[neighbor] then
                continue
            end
            
            local tentativeGScore = gScore[current] + getTraversalCost(current, neighbor)
            if tentativeGScore < (gScore[neighbor] or math.huge) then
                cameFrom[neighbor] = current
                gScore[neighbor] = tentativeGScore
                local fCost = tentativeGScore + heuristic(neighbor)
                
                if partialPath then
                    fCostMap[neighbor] = fCost
                end
                
                openSet:Push(neighbor, fCost)
            end
        end
    end

    if partialPath then
        local bestNode, bestScore = nil, math.huge
        for node, score in pairs(fCostMap) do
            if score < bestScore then
                bestNode, bestScore = node, score
            end
        end
        
        if bestNode then
            local path = {}
            while bestNode do
                table.insert(path, 1, bestNode)
                bestNode = cameFrom[bestNode]
            end
            return path
        end
    end
    
    return nil -- No path found
end

return Pathfinder