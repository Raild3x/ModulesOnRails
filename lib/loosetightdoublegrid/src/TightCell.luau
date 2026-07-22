type int = number
export type TightCell = { int }

local TightCell = {}

function TightCell.new(initialLooseCellIndex: int): TightCell
	return { initialLooseCellIndex }
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
	table.insert(tightCell, looseCellIndex)
end

return TightCell
