local ui = require("pulse.ui")
local actions = require("pulse.actions")
local display = require("pulse.display")
local layout = require("pulse.layout")
local mode = require("pulse.mode")
local preview_data = require("pulse.preview")
local config = require("pulse.config")
local panel = require("pulse.panel")
local session_mod = require("pulse.session")

local M = {}

local state = {
	session = nil,
	list = nil,
	input = nil,
	preview = nil,
	items = {},
	states = {},
	active_panels = {},
	registry = {},
	source_bufnr = nil,
	source_win = nil,
	cwd = nil,
	picker_opts = nil,
	current = {
		mode_name = nil,
		mod = nil,
		state = nil,
		query = "",
		panel = nil,
		panel_header = nil,
	},
}

local refresh

local function picker_opts(opts)
	return session_mod.normalize_opts(vim.tbl_deep_extend("force", config.options or {}, opts or {}))
end

local function is_header(item)
	return item and item.kind == "header"
end

local function item_key(item)
	if not item or is_header(item) then
		return nil
	end
	if item.kind == "folder" or item.kind == "file" then
		return item.kind .. ":" .. tostring(item.path)
	end
	if item.filename then
		return tostring(item.kind) .. ":" .. tostring(item.filename) .. ":" .. tostring(item.lnum) .. ":" .. tostring(item.col)
	end
	if item.path then
		return tostring(item.kind) .. ":" .. tostring(item.path) .. ":" .. tostring(item.lnum) .. ":" .. tostring(item.col)
	end
	if item.command then
		return "command:" .. tostring(item.command)
	end
	if item.symbol then
		return tostring(item.kind) .. ":" .. tostring(item.symbol) .. ":" .. tostring(item.filename or item.path) .. ":" .. tostring(item.lnum)
	end
end

local function find_item_index(items, key)
	for i, item in ipairs(items or {}) do
		if item_key(item) == key then
			return i
		end
	end
end

local function item_count(items)
	local count = 0
	for _, item in ipairs(items or {}) do
		if not is_header(item) then
			count = count + 1
		end
	end
	return count
end

local function first_selectable(items)
	for _, item in ipairs(items or {}) do
		if not is_header(item) then
			return item
		end
	end
end

local function is_visible()
	return state.session and state.session:is_visible()
end

local function schedule_refresh()
	vim.schedule(function()
		if is_visible() then
			refresh()
		end
	end)
end

local function current_item()
	local item = state.list and state.list:selected_item() or nil
	return (item and not is_header(item)) and item or nil
end

local function jump_in_source(item)
	local jumped
	local function do_jump()
		jumped = actions.jump_to(item)
	end
	pcall(vim.cmd, "stopinsert")
	if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
		pcall(vim.api.nvim_win_call, state.source_win, do_jump)
	else
		do_jump()
	end
	return jumped
end

local function hide()
	if is_visible() then
		pcall(vim.cmd, "stopinsert")
		state.session:hide()
		if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
			vim.api.nvim_set_current_win(state.source_win)
		end
	end
end

local function hook_ctx(reason, item)
	return {
		item = item or current_item(),
		state = state.current.state,
		query = state.current.query,
		reason = reason,
		close = hide,
		jump = jump_in_source,
		input = state.input,
		refresh = refresh,
		mode = state.current.mod and state.current.mod.mode,
	}
end

local function update_active(reason)
	local mod, item = state.current.mod, current_item()
	if item and mod and type(mod.on_active) == "function" then
		mod.on_active(hook_ctx(reason, item))
	end
end

local function picker_state(mode_name)
	local current = state.states[mode_name]
	if current then
		return current
	end

	current = state.registry[mode_name].init({
		on_update = function()
			if not is_visible() then
				return
			end
			schedule_refresh()
		end,
		bufnr = state.source_bufnr,
		win = state.source_win,
		cwd = state.cwd,
		opts = config.for_picker(mode_name),
	})
	state.states[mode_name] = current
	return current
end

local function should_show_preview(preview_cfg, item)
	return item and ((type(preview_cfg) == "function" and preview_cfg(item) == true) or preview_cfg == true)
end

local function preview_spec(item, mod)
	if not item or not mod or type(mod.preview_item) ~= "function" then
		return 0, nil
	end
	local lines, ft, highlights, line_numbers, focus_row = mod.preview_item(item)
	return math.max(#(lines or {}), 1), { lines, ft, highlights, line_numbers, focus_row }
end

local function list_need()
	local count = item_count(state.items)
	return math.max(count == 0 and state.list.min_visible or count, state.list.min_visible)
end

local function split_body_height(total, list_height, preview_height)
	if preview_height <= 0 then
		return math.min(list_height, total), 0
	end

	local available = math.max(total - 1, 2)
	local half_low = math.floor(available / 2)
	local half_high = available - half_low

	if list_height > half_low and preview_height > half_low then
		return half_high, half_low
	end

	local resolved_preview = math.min(preview_height, math.max(available - list_height, 1))
	return available - resolved_preview, resolved_preview
end

local function resolve_body_layout()
	local item = current_item() or first_selectable(state.items)
	local show_panels = state.current.panel_header ~= nil
	local panel_rows = show_panels and 2 or 0
	local total_height = math.max(layout.resolve_max_height(state.picker_opts.height) - 2 - panel_rows, 1)
	local list_height = math.min(list_need(), total_height)
	local preview_height, spec = 0, nil

	if should_show_preview(state.current.mod and state.current.mod.preview, item) then
		preview_height, spec = preview_spec(item, state.current.mod)
		list_height, preview_height = split_body_height(total_height, list_height, preview_height)
	end

	return {
		show_panels = show_panels,
		list_height = list_height,
		preview_height = preview_height,
		preview_spec = spec,
	}
end

local function render()
	if not is_visible() then
		return
	end

	local body = resolve_body_layout()
	state.list:set_max_visible(body.list_height)
	state.session.layout:apply(state.list.visible_count, body.preview_height, {
		list = state.list,
		preview = state.preview,
		input = state.input,
		panels = state.session.panels,
		show_panels = body.show_panels,
	})

	panel.render(state.session.panels, state.session.panels_ns, state.current.panel_header)
	if body.preview_spec and state.preview and state.preview.win and vim.api.nvim_win_is_valid(state.preview.win) then
		state.preview:set(unpack(body.preview_spec))
	end
	state.list:render(vim.api.nvim_win_get_width(state.list.win))
end

local function move_selection(delta)
	state.list:move(delta, is_header)
	update_active("navigation")
	render()
end

refresh = function()
	local prompt = state.input:get_value()
	local mode_name, query = mode.parse_prompt(prompt)
	local mod = state.registry[mode_name]
	local picker = picker_state(mode_name)
	local mode_switched = mode_name ~= state.current.mode_name
	local selected = item_key(current_item())
	local active_panel = panel.active_name(state.active_panels, mode_name, mod and mod.panels, state.picker_opts.initial_panel)
	local items = mod.items(picker, query, active_panel)
	local found = item_count(items)

	if found == 0 and #items > 0 then
		items = {}
	end

	state.current.mode_name = mode_name
	state.current.mod = mod
	state.current.state = picker
	state.current.query = query
	state.current.panel = active_panel
	state.current.panel_header = panel.header_item(mod and mod.panels, active_panel)
	state.items = items

	state.list:set_items(items)
	state.list:set_allow_empty_selection(mod and mod.allow_empty_selection == true)
	if mode_switched then
		state.list:set_selected((mod and mod.allow_empty_selection == true) and 0 or 1)
	elseif selected then
		state.list:set_selected(find_item_index(items, selected) or state.list.selected)
	end

	local total = found
	if mod and type(mod.total_count) == "function" then
		local ok, count = pcall(mod.total_count, picker, active_panel)
		if ok and type(count) == "number" then
			total = math.max(count, found)
		end
	end

	local picker_mode = mod and mod.mode or {}
	state.input:set_prompt(" " .. (picker_mode.icon or "") .. " ")
	state.input:set_addons({
		ghost = query == "" and picker_mode.placeholder or nil,
		right = { text = string.format("%d/%d", found, total), hl = "LineNr" },
	})

	if is_header(state.list:selected_item()) then
		state.list:move(1, is_header)
	end

	update_active("refresh")
	render()
end

local function switch_panel(direction)
	local mod = state.current.mod
	local panels = mod and mod.panels
	local idx = panel.active_index(panels, state.current.panel)
	if not idx then
		return false
	end

	idx = idx + direction
	if idx < 1 or idx > #panels then
		return false
	end

	state.active_panels[state.current.mode_name] = panels[idx].name
	schedule_refresh()
	return true
end

local function submit()
	local mod, item = state.current.mod, current_item()
	if mod and type(mod.on_submit) == "function" then
		mod.on_submit(hook_ctx(nil, item))
	elseif item and jump_in_source(item) then
		hide()
	end
end

local function apply_tab_action(selected)
	selected = selected or current_item()
	if not selected then
		return
	end

	local on_tab = state.current.mod and state.current.mod.on_tab
	if on_tab == false then
		return
	end
	if type(on_tab) == "function" then
		on_tab(hook_ctx(nil, selected))
	else
		jump_in_source(selected)
	end
end

local function click_tab_action()
	local mouse = vim.fn.getmousepos()
	if type(mouse) ~= "table" then
		return
	end

	if state.session.panels.win and mouse.winid == state.session.panels.win then
		local panels = state.current.mod and state.current.mod.panels
		local name = panels and panel.hit_test(panels, math.max((mouse.column or 1) - 2, 0))
		if name then
			state.active_panels[state.current.mode_name] = name
			refresh()
		end
		return
	end

	if mouse.winid ~= state.list.win then
		return
	end

	state.list:set_selected(tonumber(mouse.line) or 1)
	update_active("mouse")
	render()
	apply_tab_action()
end

local function move_panel_from_input(direction)
	local panels = state.current.mod and state.current.mod.panels
	local idx = panel.active_index(panels, state.current.panel)
	if not idx then
		return false
	end
	local line = state.input:get_value()
	if vim.api.nvim_win_get_cursor(state.input.win)[2] < #line then
		return false
	end
	local next_idx = idx + direction
	return next_idx >= 1 and next_idx <= #(panels or {}) and switch_panel(direction) or false
end

local function setup_keymaps()
	local map_opts = { noremap = true, silent = true }
	local function map(mode_names, lhs, rhs, buffer)
		vim.keymap.set(mode_names, lhs, rhs, vim.tbl_extend("force", map_opts, { buffer = buffer }))
	end

	for lhs, delta in pairs({ ["<Down>"] = 1, ["<Up>"] = -1 }) do
		map("n", lhs, function() move_selection(delta) end, state.list.buf)
	end
	for lhs, delta in pairs({ ["<Right>"] = 1, ["<Left>"] = -1 }) do
		map("n", lhs, function()
			local panels = state.current.mod and state.current.mod.panels
			if panels and #panels > 1 then
				switch_panel(delta)
			end
		end, state.list.buf)
	end
	map("n", "<LeftMouse>", click_tab_action, state.list.buf)
	map({ "n", "i" }, "<LeftMouse>", click_tab_action, state.input.buf)
	map("n", "<CR>", submit, state.list.buf)
	map("n", "<Tab>", apply_tab_action, state.list.buf)
	map("n", "<Esc>", hide, state.list.buf)
end

local function bind_widgets()
	local sections = state.session.layout.sections

	if not state.list then
		state.list = ui.list.new({
			buf = sections.list.buf,
			win = sections.list.win,
			max_visible = 15,
			min_visible = 1,
			render_item = display.to_display,
		})
		state.preview = preview_data.new({ buf = sections.preview.buf, win = sections.preview.win })

		local files_picker = state.registry.files
		state.input = ui.input.new({
			buf = sections.input.buf,
			win = sections.input.win,
			prompt = " " .. ((files_picker and files_picker.mode and files_picker.mode.icon) or "") .. " ",
			on_change = refresh,
			on_submit = submit,
			on_escape = hide,
			on_down = function() move_selection(1) end,
			on_up = function() move_selection(-1) end,
			on_tab = apply_tab_action,
			on_left = function() return move_panel_from_input(-1) end,
			on_right = function() return move_panel_from_input(1) end,
		})
		setup_keymaps()
		return
	end

	state.input:set_win(sections.input.win)
	state.list:set_win(sections.list.win)
	local preview = sections.preview
	state.preview:set_target(preview and preview.buf or nil, preview and preview.win or nil)
end

local function show(opts)
	panel.setup_hl()
	state.registry = config.options._picker_registry or {}
	state.picker_opts = picker_opts(opts)
	state.session = session_mod.ensure(state.picker_opts)
	state.source_bufnr = vim.api.nvim_get_current_buf()
	state.source_win = vim.api.nvim_get_current_win()
	state.cwd = state.picker_opts.cwd or vim.fn.getcwd()

	local ok, err = state.session:mount(refresh)
	if not ok then
		vim.notify("Pulse: unable to open panel (" .. tostring(err) .. ")", vim.log.levels.WARN)
		return
	end

	state.session.layout:apply(10, 8, {})
	bind_widgets()

	if state.picker_opts.initial_prompt and state.picker_opts.initial_prompt ~= "" then
		state.input:set_value(state.picker_opts.initial_prompt)
	end

	refresh()
	state.input:focus(state.picker_opts.initial_mode ~= "normal")
end

function M.open(opts)
	show(opts)
end

function M.toggle(opts)
	state.picker_opts = picker_opts(opts)
	state.session = state.session or session_mod.ensure(state.picker_opts)
	if is_visible() then
		hide()
	else
		show(opts)
	end
end

function M.get_prompt()
	return state.input and state.input:get_value() or nil
end

return M
