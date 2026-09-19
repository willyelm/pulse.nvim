local M = {}

function M.notify(message, level)
	vim.notify("Pulse: " .. message, level or vim.log.levels.WARN)
end

-- The pair every location-based navigator uses: <CR> jumps to the item and closes, <Tab> previews it in place.
function M.jump_actions(jump_label)
	local function has_item(ctx)
		return ctx and ctx.item ~= nil
	end
	return {
		{
			key = "<CR>",
			name = jump_label or "jump",
			when = has_item,
			run = function(ctx)
				ctx.jump(ctx.item)
				ctx.close()
				return false
			end,
		},
		{
			key = "<Tab>",
			name = "preview",
			when = has_item,
			run = function(ctx)
				ctx.preview(ctx.item)
			end,
		},
	}
end

return M
