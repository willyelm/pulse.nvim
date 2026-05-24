local M = {}
local window = require("pulse.ui.window")

local function list_contexts(value)
	if type(value) == "string" then
		return { value }
	end
	if vim.islist(value) then
		return value
	end
	return nil
end

local function panel_contexts(entry)
	return list_contexts(entry and entry.contexts) or { "workspace" }
end

local function is_visible_in_context(entry, context_name)
	for _, allowed in ipairs(panel_contexts(entry)) do
		if allowed == context_name then
			return true
		end
	end
	return false
end

local function build_header_layout(panels, active_name)
	local parts = {}
	local highlights = {}
	local blocks = {}
	local col = 0

	for i, entry in ipairs(panels or {}) do
		if i > 1 then
			parts[#parts + 1] = " "
			col = col + 1
		end
		local text = M.block_text(entry.label)
		local start_col = col
		parts[#parts + 1] = text
		highlights[#highlights + 1] = {
			start_col,
			start_col + #text,
			entry.name == active_name and "PulseActive" or "PulseNormal",
		}
		blocks[#blocks + 1] = {
			name = entry.name,
			start_col = start_col,
			end_col = start_col + #text,
		}
		col = col + #text
	end

	return table.concat(parts, ""), highlights, blocks
end

local function viewport_for(width, text, blocks, active_name)
	local available = math.max((width or 1) - 2, 1)
	local total = #text
	if total <= available then
		return 0, available
	end

	local active = nil
	for _, block in ipairs(blocks or {}) do
		if block.name == active_name then
			active = block
			break
		end
	end
	if not active then
		return 0, available
	end

	local center = math.floor((active.start_col + active.end_col) / 2)
	local max_offset = math.max(total - available, 0)
	local offset = math.min(math.max(center - math.floor(available / 2), 0), max_offset)
	return offset, available
end

function M.setup_hl()
	pcall(vim.api.nvim_set_hl, 0, "PulseNormal", { default = true })
	pcall(vim.api.nvim_set_hl, 0, "PulseActive", { bold = true, default = true })
end

function M.block_text(label)
	return " " .. label .. " "
end

function M.context_type(ctx)
	if not ctx then
		return "workspace"
	end
	if ctx.kind == "folder" then
		return "folder"
	end
	return "buffer"
end

function M.visible_panels(navigators, context_type)
	local visible = {}
	for _, navigator in ipairs(navigators or {}) do
		if navigator.panels and #navigator.panels > 0 then
			for _, entry in ipairs(navigator.panels) do
				if is_visible_in_context(entry, context_type) then
					visible[#visible + 1] = {
						name = entry.name,
						label = entry.label,
						navigator = navigator.name,
							panel = entry.name,
							start = entry.start or "",
							contexts = panel_contexts(entry),
						}
					end
				end
		end
	end
	return visible
end

function M.supports_context(navigator, context_name)
	for _, entry in ipairs((navigator and navigator.panels) or {}) do
		if is_visible_in_context(entry, context_name) then
			return true
		end
	end
	return false
end

function M.select(active_panels, panel_entry)
	if panel_entry and panel_entry.panel then
		active_panels[panel_entry.navigator] = panel_entry.panel
	end
	return panel_entry
end

function M.find_panel(panels, mode_name, panel_name)
	for _, entry in ipairs(panels or {}) do
		if entry.navigator == mode_name and entry.panel == panel_name then
			return entry
		end
	end
end

function M.default_panel(panels, initial_panel)
	for _, entry in ipairs(panels or {}) do
		if entry.name == initial_panel then
			return entry
		end
	end
	return panels and panels[1] or nil
end

function M.active_name(active_panels, mode_name, panels, initial_panel)
	if not panels or #panels == 0 then
		return nil
	end

	for _, panel in ipairs(panels) do
		if panel.name == initial_panel then
			active_panels[mode_name] = panel.name
			return panel.name
		end
	end

	local current = active_panels[mode_name]
	for _, panel in ipairs(panels) do
		if panel.name == current then
			return current
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

	local text, highlights, blocks = build_header_layout(panels, active_name)

	return {
		kind = "header",
		label = text,
		panel_highlights = highlights,
		panel_blocks = blocks,
		active_name = active_name,
		viewport_offset = 0,
	}
end

function M.render(target, ns, menu)
	if not (target and target.buf and vim.api.nvim_buf_is_valid(target.buf)) then
		return
	end

	if not menu then
		window.set_lines(target.buf, { "" }, { retry = true })
		vim.api.nvim_buf_clear_namespace(target.buf, ns, 0, -1)
		return
	end

	local width = vim.api.nvim_win_is_valid(target.win) and vim.api.nvim_win_get_width(target.win) or 1
	local full_text = tostring(menu.label or "")
	local offset, available = viewport_for(width, full_text, menu.panel_blocks, menu.active_name)
	local visible = full_text:sub(offset + 1, offset + available)
	menu.viewport_offset = offset
	local line = " " .. visible .. string.rep(" ", math.max(width - 2 - #visible, 0)) .. " "

	window.set_lines(target.buf, { line }, { retry = true })
	vim.api.nvim_buf_clear_namespace(target.buf, ns, 0, -1)
	for _, hl in ipairs(menu.panel_highlights or {}) do
		local start_col = math.max(hl[1], offset)
		local end_col = math.min(hl[2], offset + available)
		if start_col < end_col then
			pcall(vim.api.nvim_buf_set_extmark, target.buf, ns, 0, 1 + (start_col - offset), {
				end_row = 0,
				end_col = 1 + (end_col - offset),
				hl_group = hl[3],
			})
		end
	end
end

function M.hit_test(menu, col)
	local full_col = (tonumber(col) or 0) + (menu and menu.viewport_offset or 0)
	for _, block in ipairs((menu and menu.panel_blocks) or {}) do
		if full_col >= block.start_col and full_col < block.end_col then
			return block.name
		end
	end
end

return M
