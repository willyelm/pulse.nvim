local M = {}

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
end

local function friendly_key(lhs)
	lhs = tostring(lhs or "")
	local named = {
		["<CR>"] = "enter",
		["<Tab>"] = "tab",
		["<Esc>"] = "esc",
		["<Left>"] = "left",
		["<Right>"] = "right",
		["<Up>"] = "up",
		["<Down>"] = "down",
	}
	if named[lhs] then
		return named[lhs]
	end
	local ctrl = lhs:match("^<C%-(.)>$")
	if ctrl then
		return "ctrl+" .. string.lower(ctrl)
	end
	return lhs:gsub("[<>]", ""):lower()
end

function M.render(target, ns, labels, active_actions, ordered_keys)
	if not (target and target.buf and vim.api.nvim_buf_is_valid(target.buf)) then
		return
	end

	local chunks = {}
	local spans = {}
	local text_width = 0

	for i = #(ordered_keys or {}), 1, -1 do
		local lhs = ordered_keys[i]
		local run = active_actions and active_actions[lhs]
		local label = labels and labels[lhs]
		if type(run) == "function" and type(label) == "string" and label ~= "" then
			label = string.lower(label)
			if #chunks > 0 then
				chunks[#chunks + 1] = " "
				text_width = text_width + 1
			end
			local key_text = friendly_key(lhs)
			local label_text = " " .. label
			local text = key_text .. label_text
			chunks[#chunks + 1] = text
			spans[#spans + 1] =
				{ hl = "LineNr", start_col = text_width + #key_text, end_col = text_width + #text }
			text_width = text_width + #text
		end
	end

	local full_line = table.concat(chunks)
	local width = (target.win and vim.api.nvim_win_is_valid(target.win)) and vim.api.nvim_win_get_width(target.win)
		or #full_line
	local inner_width = math.max(width - 2, 0)
	local offset = math.max(#full_line - inner_width, 0)
	local line = offset > 0 and full_line:sub(offset + 1) or full_line
	local left_pad = math.max(inner_width - vim.fn.strdisplaywidth(line), 0)
	set_lines(target.buf, {
		" " .. string.rep(" ", left_pad) .. line .. string.rep(" ", math.max(inner_width - left_pad - #line, 0)) .. " ",
	})
	vim.api.nvim_buf_clear_namespace(target.buf, ns, 0, -1)
	for _, span in ipairs(spans) do
		local start_col = math.max(span.start_col, offset)
		local end_col = math.min(span.end_col, offset + #line)
		if start_col < end_col then
			pcall(vim.api.nvim_buf_set_extmark, target.buf, ns, 0, 1 + left_pad + (start_col - offset), {
			end_row = 0,
				end_col = 1 + left_pad + (end_col - offset),
			hl_group = span.hl,
		})
		end
	end
end

return M
