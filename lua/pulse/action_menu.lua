local M = {}

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
end

local function shortcut(lhs)
	return tostring(lhs or ""):gsub("[<>]", "")
end

function M.render(target, ns, labels, active_actions, ordered_keys, block_text)
	if not (target and target.buf and vim.api.nvim_buf_is_valid(target.buf)) then
		return
	end

	local parts = {}
	local spans = {}
	local col = 0

	for _, lhs in ipairs(ordered_keys or {}) do
		local run = active_actions and active_actions[lhs]
		local label = labels and labels[lhs]
		if type(run) == "function" and type(label) == "string" and label ~= "" then
			if #parts > 0 then
				parts[#parts + 1] = " "
				col = col + 1
			end
			local text = block_text(string.format("%s (%s)", label, shortcut(lhs)))
			parts[#parts + 1] = text
			spans[#spans + 1] = { start_col = col, end_col = col + #text }
			col = col + #text
		end
	end

	set_lines(target.buf, { table.concat(parts) })
	vim.api.nvim_buf_clear_namespace(target.buf, ns, 0, -1)
	for _, span in ipairs(spans) do
		pcall(vim.api.nvim_buf_set_extmark, target.buf, ns, 0, span.start_col, {
			end_row = 0,
			end_col = span.end_col,
			hl_group = "PulseNormal",
		})
	end
end

return M
