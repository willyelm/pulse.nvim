local display = require("pulse.display")

local M = {}

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
end

function M.setup_hl()
	pcall(vim.api.nvim_set_hl, 0, "PulseNormal", { default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseActive", { bold = true, default = true })
end

function M.block_text(index, label)
	local separator = index > 1 and " " or ""
	return separator .. " " .. label .. " "
end

function M.active_name(active_panels, mode_name, panels, initial_panel)
	if not panels or #panels == 0 then
		return nil
	end

	local current = active_panels[mode_name]
	for _, panel in ipairs(panels) do
		if panel.name == current then
			return current
		end
	end

	for _, panel in ipairs(panels) do
		if panel.name == initial_panel then
			active_panels[mode_name] = panel.name
			return panel.name
		end
	end

	active_panels[mode_name] = panels[1].name
	return active_panels[mode_name]
end

function M.active_index(panels, active_name)
	if not active_name or not panels or #panels < 2 then
		return nil
	end
	for i, panel in ipairs(panels) do
		if panel.name == active_name then
			return i
		end
	end
end

function M.header_item(panels, active_name)
	if not panels or #panels < 2 then
		return nil
	end

	local parts = {}
	local highlights = {}
	local col = 0
	for i, panel in ipairs(panels) do
		local text = M.block_text(i, panel.label)
		local start_col = col + (i > 1 and 1 or 0)
		parts[#parts + 1] = text
		highlights[#highlights + 1] = {
			start_col,
			col + #text,
			panel.name == active_name and "PulseActive" or "PulseNormal",
		}
		col = col + #text
	end

	return {
		kind = "header",
		label = table.concat(parts, ""),
		panel_highlights = highlights,
	}
end

function M.render(target, ns, panel_header)
	if not (target and target.buf and vim.api.nvim_buf_is_valid(target.buf)) then
		return
	end

	if not panel_header then
		set_lines(target.buf, { "" })
		vim.api.nvim_buf_clear_namespace(target.buf, ns, 0, -1)
		return
	end

	local rendered = display.to_display(panel_header)
	local width = vim.api.nvim_win_is_valid(target.win) and vim.api.nvim_win_get_width(target.win) or 1
	local text = " " .. tostring(rendered.left or "")
	local line = text .. string.rep(" ", math.max(width - vim.fn.strdisplaywidth(text), 0))

	set_lines(target.buf, { line })
	vim.api.nvim_buf_clear_namespace(target.buf, ns, 0, -1)
	for _, hl in ipairs(rendered.left_matches or {}) do
		pcall(vim.api.nvim_buf_set_extmark, target.buf, ns, 0, 1 + hl[1], {
			end_row = 0,
			end_col = 1 + hl[2],
			hl_group = hl[3],
		})
	end
end

function M.hit_test(panels, col)
	local offset = 0
	for i, panel in ipairs(panels or {}) do
		offset = offset + #M.block_text(i, panel.label)
		if col < offset then
			return panel.name
		end
	end
end

return M
