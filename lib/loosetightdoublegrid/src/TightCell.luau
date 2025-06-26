
type int = number
export type TightCell = {int}

local TightCell = {}

function TightCell.new(initiaLooseCellIndex: int): TightCell
    return {initiaLooseCellIndex}
end

function TightCell.remove(tightCell: TightCell, looseCellIndex: int)
    local index = table.find(tightCell, looseCellIndex)
    if index then -- Swap elements
        tightCell[index] = tightCell[#tightCell]
        tightCell[#tightCell] = nil
        return true
    end
    return false
end

function TightCell.insert(tightCell: TightCell, looseCellIndex: int)
    -- assert(typeof(looseCellIndex) == "number", "looseCellIndex must be a number")
    table.insert(tightCell, looseCellIndex)
end

return TightCell