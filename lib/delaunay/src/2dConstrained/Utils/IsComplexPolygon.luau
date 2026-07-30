
local EPSILON = 0.00001
local LEFT = "left"
local RIGHT = "right"

type Point = Vector2
type Edge = { Point }
type Event = { point: Point, type: string, edge: Edge }
type Polygon = { Point }
type EventQueue = {
    events: { Event },
    index: number,
    next: (self: EventQueue) -> Event?,
}
type SweepLine = {
    activeEdges: { Edge },
    add: (self: SweepLine, edge: Edge) -> (),
    remove: (self: SweepLine, edge: Edge) -> (),
    findNeighbors: (self: SweepLine, edge: Edge) -> (Edge?, Edge?),
}

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

local function comparePoints(p1: Point, p2: Point): number
    if p1.X ~= p2.X then
        return p1.X < p2.X and -1 or 1
    elseif p1.Y ~= p2.Y then
        return p1.Y < p2.Y and -1 or 1
    else
        return 0
    end
end

local function isLeft(p0: Point, p1: Point, p2: Point): number
    return (p1.X - p0.X) * (p2.Y - p0.Y) - (p2.X - p0.X) * (p1.Y - p0.Y)
end

local function edgesIntersect(e1: Edge, e2: Edge): boolean
    local p1, p2 = e1[1], e1[2]
    local q1, q2 = e2[1], e2[2]

    local d1 = isLeft(q1, q2, p1)
    local d2 = isLeft(q1, q2, p2)
    local d3 = isLeft(p1, p2, q1)
    local d4 = isLeft(p1, p2, q2)

    if d1 * d2 < 0 and d3 * d4 < 0 then
        return true
    end

    return false
end

--------------------------------------------------------------------------------
-- EventQueue Class
--------------------------------------------------------------------------------

local EventQueue = {}
EventQueue.__index = EventQueue

function EventQueue.new(polygon: Polygon): EventQueue
    local self = setmetatable({}, EventQueue)
    self.events = {}

    for i = 1, #polygon do
        local p1 = polygon[i]
        local p2 = polygon[i % #polygon + 1]

        if comparePoints(p1, p2) < 0 then
            table.insert(self.events, { point = p1, type = LEFT, edge = { p1, p2 } })
            table.insert(self.events, { point = p2, type = RIGHT, edge = { p1, p2 } })
        else
            table.insert(self.events, { point = p2, type = LEFT, edge = { p2, p1 } })
            table.insert(self.events, { point = p1, type = RIGHT, edge = { p2, p1 } })
        end
    end

    table.sort(self.events, function(a, b)
        return comparePoints(a.point, b.point) < 0
    end)

    self.index = 1
    return self
end

function EventQueue.next(self: EventQueue): Event?
    if self.index > #self.events then
        return nil
    end
    local event = self.events[self.index]
    self.index += 1
    return event
end

--------------------------------------------------------------------------------
-- SweepLine Class
--------------------------------------------------------------------------------

local SweepLine = {}
SweepLine.__index = SweepLine

function SweepLine.new(): SweepLine
    local self = setmetatable({}, SweepLine)
    self.activeEdges = {}
    return self
end

function SweepLine.add(self: SweepLine, edge: Edge)
    table.insert(self.activeEdges, edge)
    table.sort(self.activeEdges, function(e1, e2)
        return comparePoints(e1[1], e2[1]) < 0
    end)
end

function SweepLine.remove(self: SweepLine, edge: Edge)
    for i, activeEdge in ipairs(self.activeEdges) do
        if activeEdge == edge then
            table.remove(self.activeEdges, i)
            break
        end
    end
end

function SweepLine.findNeighbors(self: SweepLine, edge: Edge): (Edge?, Edge?)
    local prev, next = nil, nil
    for i, activeEdge in ipairs(self.activeEdges) do
        if activeEdge == edge then
            prev = self.activeEdges[i - 1]
            next = self.activeEdges[i + 1]
            break
        end
    end
    return prev, next
end

--------------------------------------------------------------------------------
-- IsComplex Function
--------------------------------------------------------------------------------

local function IsComplex(polygon: Polygon): boolean
    local eventQueue = EventQueue.new(polygon)
    local sweepLine = SweepLine.new()

    while true do
        local event = eventQueue:next()
        if not event then
            break
        end

        local edge = event.edge

        if event.type == LEFT then
            sweepLine:add(edge)
            local above, below = sweepLine:findNeighbors(edge)

            if above and edgesIntersect(above, edge) then
                return true
            end
            if below and edgesIntersect(below, edge) then
                return true
            end
        elseif event.type == RIGHT then
            local above, below = sweepLine:findNeighbors(edge)

            if above and below and edgesIntersect(above, below) then
                return true
            end

            sweepLine:remove(edge)
        end
    end

    return false
end

return IsComplex