-- The file or folder the Files panel has copied or cut: set by its actions, read by the row that marks it.
local M = {}

local staged

-- `row` is the row's own `item.path`, so that row can recognise itself. The row stays marked until `marked` is
-- cleared; what was staged stays pasteable either way.
function M.stage(kind, path, row)
	staged = { kind = kind, path = path, row = row, marked = true }
	return staged
end

function M.clear()
	staged = nil
end

function M.get()
	return staged
end

-- "copy" or "cut" for the row that was staged, while it is marked.
function M.kind_of(row)
	return staged and staged.marked and staged.row == row and staged.kind or nil
end

return M
