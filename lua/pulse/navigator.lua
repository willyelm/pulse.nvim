local ui = require("pulse.ui")
local actions = require("pulse.actions")
local display = require("pulse.display")
local layout = require("pulse.layout")
local mode = require("pulse.mode")
local context_view = require("pulse.context")
local config = require("pulse.config")
local panel = require("pulse.panel")
local session_mod = require("pulse.session")
local scope = require("pulse.scope")

local M = {}

local state = {
	session = nil,
	list = nil,
	input = nil,
	context = nil,
	items = {},
	states = {},
	active_panels = {},
	registry = {},
	modules = {},
	source_bufnr = nil,
	source_win = nil,
	cwd = nil,
	navigator_opts = nil,
	pending_initial_panel = nil,
	scope = nil,
	current = {
		mode_name = nil,
		mod = nil,
		state = nil,
		query = "",
		panel = nil,
		surface = nil,
		panel_header = nil,
	},
}

local refresh

local function scope_key(value)
	return scope.key(value)
end

local function navigator_opts(opts)
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

local function run_in_source(item, opts)
	opts = opts or {}
	local jumped
	local function do_jump()
		jumped = actions.jump_to(item)
	end
	if opts.stopinsert ~= false then
		pcall(vim.cmd, "stopinsert")
	end
	if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
		pcall(vim.api.nvim_win_call, state.source_win, do_jump)
	else
		do_jump()
	end
	if jumped and opts.refocus_input and state.input then
		state.input:focus(true)
	end
	return jumped
end

local function jump_in_source(item)
	return run_in_source(item)
end

local function preview_in_source(item)
	return run_in_source(item, { stopinsert = false, refocus_input = true })
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
		preview = preview_in_source,
		scope = state.scope,
		set_scope = function(next_scope)
			state.scope = next_scope
			schedule_refresh()
		end,
		clear_scope = function()
			local switch_to_files = state.current.mod and state.current.mod.scope_clears_to_files
			vim.schedule(function()
				if not is_visible() then
					return
				end
				state.scope = nil
				if switch_to_files and state.input then
					state.input:set_value(mode.switch_prompt(state.input:get_value(), "files"))
				end
				refresh()
			end)
		end,
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

local function navigator_state(mode_name)
	local current = state.states[mode_name]
	local mod = state.registry[mode_name]
	local current_scope_key = mod and mod.scope_aware and scope_key(state.scope) or ""
	if current and (not mod.scope_aware or current._scope_key == current_scope_key) then
		return current
	end

	current = mod.init({
		on_update = function()
			if not is_visible() then
				return
			end
			schedule_refresh()
		end,
		bufnr = state.source_bufnr,
		win = state.source_win,
		cwd = state.cwd,
		opts = config.for_navigator(mode_name),
		scope = state.scope,
	})
	current._scope_key = current_scope_key
	state.states[mode_name] = current
	return current
end

local function should_show_context(context_cfg, item)
	return item and ((type(context_cfg) == "function" and context_cfg(item) == true) or context_cfg == true)
end

local function context_spec(item, mod)
	if not item or not mod or type(mod.context_item) ~= "function" then
		return 0, nil
	end
	local lines, ft, highlights, line_numbers, focus_row = mod.context_item(item)
	return math.max(#(lines or {}), 1), { lines, ft, highlights, line_numbers, focus_row }
end

local function split_body_height(total, list_height, context_height)
	if context_height <= 0 then
		return math.min(list_height, total), 0
	end

	local available = math.max(total - 1, 2)
	local half_low = math.floor(available / 2)
	local half_high = available - half_low

	if list_height > half_low and context_height > half_low then
		return half_high, half_low
	end

	local resolved_context = math.min(context_height, math.max(available - list_height, 1))
	return available - resolved_context, resolved_context
end

local function input_scope()
	local mod = state.current.mod
	if mod and type(mod.input_scope) == "function" then
		return mod.input_scope(state.current.state, state.scope)
	end
	return nil
end

local function visible_surfaces()
	return panel.visible_panels(state.modules, panel.scope_type(state.scope))
end

local function current_surface(panels)
	return panel.find_surface(panels, state.current.mode_name, state.current.panel)
end

local function panels_visible(mod, navigator_state_value)
	return state.current.panel_header ~= nil
end

local function resolve_body_layout()
	local item = current_item() or first_selectable(state.items)
	local show_panels = panels_visible(state.current.mod, state.current.state)
	local panel_rows = show_panels and 2 or 0
	local total_height = math.max(layout.resolve_max_height(state.navigator_opts.height) - 2 - panel_rows, 1)
	local item_total = item_count(state.items)
	local list_need = math.max(item_total == 0 and state.list.min_visible or item_total, state.list.min_visible)
	local list_height = math.min(list_need, total_height)
	local context_height, spec = 0, nil

	if should_show_context(state.current.mod and state.current.mod.context, item) then
		context_height, spec = context_spec(item, state.current.mod)
		list_height, context_height = split_body_height(total_height, list_height, context_height)
	end

	return {
		show_panels = show_panels,
		list_height = list_height,
		context_height = context_height,
		context_spec = spec,
	}
end

local function render()
	if not is_visible() then
		return
	end

	local body = resolve_body_layout()
	state.list:set_max_visible(body.list_height)
	state.session.layout:apply(state.list.visible_count, body.context_height, {
		list = state.list,
		context = state.context,
		input = state.input,
		panels = state.session.panels,
		show_panels = body.show_panels,
	})

	panel.render(state.session.panels, state.session.panels_ns, state.current.panel_header)
	if body.context_spec and state.context and state.context.win and vim.api.nvim_win_is_valid(state.context.win) then
		state.context:set(unpack(body.context_spec))
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
	if not state.scope and panel.is_buffer_only(mod) then
		state.scope = scope.from_buffer(state.source_bufnr)
	end
	local initial_panel = state.pending_initial_panel
	local current_panel = panel.active_name(state.active_panels, mode_name, mod and mod.panels, initial_panel)
	local surfaces = visible_surfaces()
	local active_surface = panel.find_surface(surfaces, mode_name, current_panel)
	if not active_surface then
		active_surface = panel.default_surface(surfaces, initial_panel)
		if active_surface then
			if active_surface.panel then
				state.active_panels[active_surface.navigator] = active_surface.panel
			end
			local next_prompt = mode.switch_prompt(prompt, active_surface.navigator)
			if next_prompt ~= prompt then
				state.input:set_value(next_prompt)
				return
			end
		end
	end

	mode_name = active_surface and active_surface.navigator or mode_name
	mod = state.registry[mode_name]
	local active_panel = active_surface and active_surface.panel or panel.active_name(state.active_panels, mode_name, mod and mod.panels, initial_panel)
	local navigator = navigator_state(mode_name)
	navigator.scope = state.scope
	local mode_switched = mode_name ~= state.current.mode_name
	local selected = item_key(current_item())
	local items = mod.items(navigator, query, active_panel)
	local found = item_count(items)

	if found == 0 and #items > 0 then
		items = {}
	end

	state.current.mode_name = mode_name
	state.current.mod = mod
	state.current.state = navigator
	state.current.query = query
	state.current.panel = active_panel
	state.current.surface = active_surface
	state.current.panel_header = panel.header_item(surfaces, active_surface and active_surface.name or nil)
	state.items = items
	state.pending_initial_panel = nil

	state.list:set_items(items)
	state.list:set_allow_empty_selection(mod and mod.allow_empty_selection == true)
	if mode_switched then
		state.list:set_selected((mod and mod.allow_empty_selection == true) and 0 or 1)
	elseif selected then
		state.list:set_selected(find_item_index(items, selected) or state.list.selected)
	end

	local total = found
	if mod and type(mod.total_count) == "function" then
		local ok, count = pcall(mod.total_count, navigator, active_panel)
		if ok and type(count) == "number" then
			total = math.max(count, found)
		end
	end

	local navigator_mode = mod and mod.mode or {}
	local prompt_prefix = " " .. (navigator_mode.icon or "") .. " "
	local scoped = input_scope()
	local scope_text = scope.prompt_text(scoped)
	local prompt = prompt_prefix .. scope_text
	if scope_text ~= "" then
		prompt = prompt .. " "
	end
	state.input:set_prompt(prompt)
	state.input:set_addons({
		ghost = query == "" and active_surface and active_surface.label or nil,
		right = { text = string.format("%d/%d", found, total), hl = "LineNr" },
		prompt_matches = scope.prompt_matches(scoped, #prompt_prefix),
	})

	if is_header(state.list:selected_item()) then
		state.list:move(1, is_header)
	end

	update_active("refresh")
	render()
end

local function switch_panel(direction)
	local panels = visible_surfaces()
	local active = current_surface(panels)
	local idx = panel.active_index(panels, active and active.name or nil)
	if not idx then
		return false
	end

	idx = idx + direction
	if idx < 1 or idx > #panels then
		return false
	end

	local target = panels[idx]
	vim.schedule(function()
		if target.panel then
			state.active_panels[target.navigator] = target.panel
		end
		if not is_visible() or not state.input then
			return
		end
		state.input:set_value(mode.switch_prompt(state.input:get_value(), target.navigator))
		refresh()
	end)
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
		local name = state.current.panel_header and panel.hit_test(state.current.panel_header, math.max((mouse.column or 1) - 2, 0))
		if name then
			for _, target in ipairs(visible_surfaces()) do
				if target.name == name then
					if target.panel then
						state.active_panels[target.navigator] = target.panel
					end
					state.input:set_value(mode.switch_prompt(state.input:get_value(), target.navigator))
					break
				end
			end
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
	local panels = visible_surfaces()
	local active = current_surface(panels)
	local idx = panel.active_index(panels, active and active.name or nil)
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
			local panels = visible_surfaces()
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
		state.context = context_view.new({ buf = sections.context.buf, win = sections.context.win })

		local files_navigator = state.registry.files
		state.input = ui.input.new({
			buf = sections.input.buf,
			win = sections.input.win,
			prompt = " " .. ((files_navigator and files_navigator.mode and files_navigator.mode.icon) or "") .. " ",
			on_change = refresh,
			on_submit = submit,
			on_escape = hide,
			on_down = function() move_selection(1) end,
			on_up = function() move_selection(-1) end,
			on_tab = apply_tab_action,
			on_left = function() return move_panel_from_input(-1) end,
			on_right = function() return move_panel_from_input(1) end,
			on_backspace = function(value)
				local scoped = input_scope()
				local start = state.current.surface and state.current.surface.start or ""
				local clears_scope = state.current.mod and state.current.mod.scope_clears_to_files
				if scoped and (value == "" or (clears_scope and start ~= "" and value == start)) then
					hook_ctx("backspace"):clear_scope()
					return true
				end
				return false
			end,
		})
		setup_keymaps()
		return
	end

	state.input:set_win(sections.input.win)
	state.list:set_win(sections.list.win)
	local context = sections.context
	state.context:set_target(context and context.buf or nil, context and context.win or nil)
end

local function show(opts)
	panel.setup_hl()
	state.registry = config.options._navigator_registry or {}
	state.modules = config.options.navigators or {}
	state.navigator_opts = navigator_opts(opts)
	state.pending_initial_panel = state.navigator_opts.initial_panel
	state.session = session_mod.ensure(state.navigator_opts)
	state.source_bufnr = vim.api.nvim_get_current_buf()
	state.source_win = vim.api.nvim_get_current_win()
	local next_cwd = state.navigator_opts.cwd or vim.fn.getcwd()
	local preserved_files = (state.cwd == next_cwd) and state.states.files or nil
	state.cwd = next_cwd
	state.scope = state.navigator_opts.scope
	state.states = preserved_files and { files = preserved_files } or {}

	local ok, err = state.session:mount(refresh)
	if not ok then
		vim.notify("Pulse: unable to open navigator (" .. tostring(err) .. ")", vim.log.levels.WARN)
		return
	end

	state.session.layout:apply(10, 8, {})
	bind_widgets()

	if state.navigator_opts.initial_prompt and state.navigator_opts.initial_prompt ~= "" then
		state.input:set_value(state.navigator_opts.initial_prompt)
	end

	refresh()
	state.input:focus(state.navigator_opts.initial_mode ~= "normal")
end

function M.open(opts)
	show(opts)
end

function M.toggle(opts)
	state.navigator_opts = navigator_opts(opts)
	state.session = state.session or session_mod.ensure(state.navigator_opts)
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
