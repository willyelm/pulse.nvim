local ui = require("pulse.ui")
local action = require("pulse.action")
local action_menu = require("pulse.action_menu")
local display = require("pulse.display")
local layout = require("pulse.layout")
local context_view = require("pulse.context")
local config = require("pulse.config")
local panel = require("pulse.panel_menu")
local session_mod = require("pulse.session")
local scope = require("pulse.scope")

local M = {}
local sync_panel_action_keymaps

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
	fullscreen = false,
	pending_initial_panel = nil,
	scope = nil,
	current = {
		mode_name = nil,
		mod = nil,
		state = nil,
		query = "",
		panel = nil,
		panel_entry = nil,
		panels = nil,
		menu = nil,
	},
	bound_action_keys = {},
	selected_items = {},
	pending_selected_key = nil,
}

local refresh
local hide
local jump_in_source
local preview_in_source

local function is_header(item)
	return item and item.kind == "header"
end

local function item_key(item)
	if not item or is_header(item) then
		return nil
	end
	if item.kind == "git_commit" then
		return "git_commit:" .. tostring(item.commit)
	end
	if item.kind == "git_commit_file" then
		return "git_commit_file:" .. tostring(item.commit) .. ":" .. tostring(item.path)
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

local function item_source_count(items)
	if type(items) == "table" and type(items.count) == "function" then
		return math.max(tonumber(items:count()) or 0, 0)
	end
	return #(items or {})
end

local function item_source_get(items, index)
	index = tonumber(index) or 0
	if index < 1 then
		return nil
	end
	if type(items) == "table" then
		if type(items.get) == "function" then
			return items:get(index)
		end
	end
	return items and items[index] or nil
end

local function analyse_items(items, selected_key)
	local stats = {
		count = 0,
		first = nil,
		first_index = nil,
		selected_index = nil,
	}
	for i = 1, item_source_count(items) do
		local item = item_source_get(items, i)
		if not is_header(item) then
			stats.count = stats.count + 1
			if not stats.first then
				stats.first = item
				stats.first_index = i
			end
			if selected_key and stats.selected_index == nil and item_key(item) == selected_key then
				stats.selected_index = i
			end
		end
	end
	return stats
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

local function schedule_focus_input()
	vim.schedule(function()
		if is_visible() and state.input then
			state.input:focus(true)
		end
	end)
end

local function set_prompt_mode(name)
	if state.input then
		state.input:set_value(config.switch_prompt(state.input:get_value(), name), { move_cursor_end = true })
	end
end

local function current_box_opts()
	if state.fullscreen then
		return {
			width = vim.o.columns,
			height = vim.o.lines - vim.o.cmdheight,
			row = 0,
			col = 0,
			border = "none",
		}
	end
	return {
		width = state.navigator_opts.width,
		height = state.navigator_opts.height,
		row = (state.navigator_opts.position == "top") and 1 or nil,
		col = 0.5,
		border = (state.navigator_opts.border == true) and "single" or state.navigator_opts.border,
	}
end

local function apply_box_size()
	if not (state.session and state.session.box) then
		return
	end
	state.session.box:update(current_box_opts())
end

local function visible_panels(scope_value)
	return panel.visible_panels(state.modules, panel.scope_type(scope_value or state.scope))
end

local function buffer_only_navigator(navigator)
	return panel.supports_scope(navigator, "buffer")
		and not panel.supports_scope(navigator, "workspace")
		and not panel.supports_scope(navigator, "folder")
end

local function apply_scope_change(scope_value)
	vim.schedule(function()
		if not is_visible() then
			return
		end
		state.scope = scope_value
		local target = panel.default_panel(visible_panels(scope_value), nil)
		if target then
			panel.select(state.active_panels, target)
			set_prompt_mode(target.navigator)
		end
		refresh()
		if scope_value ~= nil then
			schedule_focus_input()
		end
	end)
end

local function clear_prefix()
	vim.schedule(function()
		if not (is_visible() and state.input) then
			return
		end
		local value = state.input:get_value()
		local start = state.current.panel_entry and state.current.panel_entry.start or ""
		if start ~= "" and value:sub(1, #start) == start then
			state.input:set_value(value:sub(#start + 1), { move_cursor_end = true })
		end
		refresh()
		schedule_focus_input()
	end)
end

local function current_item()
	local item = state.list and state.list:selected_item() or nil
	return (item and not is_header(item)) and item or nil
end

local function selection_key(mode_name, panel_name, scoped)
	return table.concat({
		tostring(mode_name or ""),
		tostring(panel_name or ""),
		scope.key(scoped),
	}, "|")
end

local function remember_selection(mode_name, panel_name, scoped, item)
	local key = selection_key(mode_name, panel_name, scoped)
	local item_id = item_key(item)
	if item_id then
		state.selected_items[key] = item_id
	else
		state.selected_items[key] = nil
	end
end

local function remembered_selection(mode_name, panel_name, scoped)
	return state.selected_items[selection_key(mode_name, panel_name, scoped)]
end

local function action_ctx(item)
	return {
		item = item or current_item(),
		has_selection = state.list and (state.list.selected or 0) > 0 or false,
		state = state.current.state,
		query = state.current.query,
		panel = state.current.panel_entry,
		scope = state.scope,
		input = state.input,
		source_scope = function()
			if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
				return scope.from_buffer(vim.api.nvim_win_get_buf(state.source_win))
			end
			return nil
		end,
			refresh = schedule_refresh,
			focus = schedule_focus_input,
			set_scope = function(scope_value)
				state.scope = scope_value
				schedule_refresh()
			end,
			enter_scope = apply_scope_change,
			clear_scope = function()
				apply_scope_change(nil)
			end,
		clear_prefix = clear_prefix,
		close = hide,
		jump = jump_in_source,
		preview = preview_in_source,
		set_query = function(value, opts)
			if state.input then
				state.input:set_value(value or "", { move_cursor_end = not opts or opts.move_cursor_end ~= false })
			end
		end,
		exec = function(command)
			local commands = require("pulse.navigators.commands")
			commands.execute(command)
		end,
	}
end

local function panel_actions(item)
	local ctx = action_ctx(item)
	local item_value = ctx.item
	local actions = {}
	local ordered = {}
	local defs = {}
	local mode_actions = state.current.mod and state.current.mod.actions
	if type(mode_actions) == "function" then
		defs = mode_actions(ctx) or {}
	elseif type(mode_actions) == "table" then
		defs = mode_actions
	end
	for _, def in ipairs(defs) do
		local lhs = type(def) == "table" and def.key or nil
		local run = type(def) == "table" and (def.action or def.run) or nil
		if type(lhs) == "string" and lhs ~= "" and type(run) == "function" then
			local enabled = true
			local kinds = def["for"]
			if kinds ~= nil then
				enabled = false
				if item_value then
					for _, kind in ipairs(kinds) do
						if item_value.kind == kind then
							enabled = true
							break
						end
					end
				end
			end
			if enabled and type(def.when) == "function" and def.when(ctx, item_value) == false then
				enabled = false
			end
			local label = def.name or def.label
			if type(label) == "function" then
				label = label(ctx, item_value)
			end
			actions[lhs] = {
				run = run,
				label = label,
				enabled = enabled,
			}
			ordered[#ordered + 1] = lhs
		end
	end
	return actions, ordered
end

local function run_in_source(item, opts)
	opts = opts or {}
	local jumped
	local function do_jump()
		jumped = action.jump_to(item)
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
		schedule_focus_input()
	end
	return jumped
end

jump_in_source = function(item)
	return run_in_source(item)
end

preview_in_source = function(item)
	return run_in_source(item, { stopinsert = false, refocus_input = true })
end

hide = function()
	if is_visible() then
		pcall(vim.cmd, "stopinsert")
		state.session:hide()
		if state.source_win and vim.api.nvim_win_is_valid(state.source_win) then
			vim.api.nvim_set_current_win(state.source_win)
		end
	end
end

local function update_active()
	local mod, item = state.current.mod, current_item()
	if item and mod and type(mod.on_active) == "function" then
		mod.on_active(action_ctx(item))
	end
end

local function navigator_state(mode_name)
	local current = state.states[mode_name]
	local mod = state.registry[mode_name]
	local scoped = mod and (panel.supports_scope(mod, "buffer") or panel.supports_scope(mod, "folder")) or false
	local current_scope_key = scoped and scope.key(state.scope) or ""
	if current and (not scoped or current._scope_key == current_scope_key) then
		return current
	end

	local bufnr = state.source_bufnr
	if state.scope and state.scope.kind == "file" then
		bufnr = state.scope.bufnr or vim.fn.bufnr(state.scope.path)
		if not bufnr or bufnr < 1 then
			bufnr = vim.fn.bufadd(state.scope.path)
		end
	end

	local win = state.source_win
	if not (win and vim.api.nvim_win_is_valid(win)) then
		win = 0
	end

	current = mod.init({
		on_update = function()
			if not is_visible() then
				return
			end
			schedule_refresh()
		end,
		bufnr = bufnr,
		win = win,
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

	if list_height > half_high and context_height > half_low then
		return half_high, half_low
	end
	if context_height <= half_low then
		return math.max(available - context_height, 1), context_height
	end
	if list_height <= half_high then
		return list_height, math.max(available - list_height, 1)
	end

	return half_high, half_low
end

local function reconcile_scope(prompt, mode_name, mod, current_scope)
	if not (state.scope and mod and not panel.supports_scope(mod, current_scope)) then
		return mode_name, mod, current_scope, false
	end
	if current_scope == "buffer" and config.by_start()[prompt:sub(1, 1)] == nil then
		local target = panel.default_panel(visible_panels(state.scope), nil)
		if target then
			panel.select(state.active_panels, target)
			local next_mod = state.registry[target.navigator]
			return target.navigator, next_mod, current_scope, false
		end
	end
	if buffer_only_navigator(mod) then
		state.scope = scope.from_buffer(state.source_bufnr)
	elseif panel.supports_scope(mod, "workspace") then
		state.scope = nil
	end
	return mode_name, mod, panel.scope_type(state.scope), false
end

local function ensure_buffer_scope(mod)
	if not state.scope and buffer_only_navigator(mod) then
		state.scope = scope.from_buffer(state.source_bufnr)
	end
end

local function resolve_panel(prompt, mode_name, mod, initial_panel)
	local current_panel = panel.active_name(state.active_panels, mode_name, mod and mod.panels, initial_panel)
	local panels = visible_panels()
	local active_panel = panel.find_panel(panels, mode_name, current_panel)
	if active_panel then
		return panels, active_panel, false
	end

	active_panel = panel.default_panel(vim.tbl_filter(function(entry)
		return entry.navigator == mode_name
	end, panels), initial_panel) or panel.default_panel(panels, initial_panel)
	panel.select(state.active_panels, active_panel)
	if active_panel then
		local next_prompt = config.switch_prompt(prompt, active_panel.navigator)
		if next_prompt ~= prompt then
			state.input:set_value(next_prompt, { move_cursor_end = true })
			return panels, active_panel, true
		end
	end
	return panels, active_panel, false
end

local function prompt_ui(mod, navigator, query, active_panel, found, total_text)
	local prompt_prefix = " " .. ((mod and mod.icon) or "") .. " "
	local root_scope = scope.workspace(state.cwd)
	local scoped = nil
	if mod and type(mod.input_scope) == "function" then
		scoped = mod.input_scope(navigator, state.scope)
	end
	if scoped and scoped.kind == "workspace" then
		scoped = nil
	end
	local root_text = state.navigator_opts.workspace_label == true and scope.prompt_text(root_scope, { no_icon = true }) or ""
	local scope_text = scope.prompt_text(scoped)
	local prompt = prompt_prefix .. root_text
	if root_text ~= "" and scope_text ~= "" then
		prompt = prompt .. "  "
	end
	prompt = prompt .. scope_text
	if scope_text ~= "" then
		prompt = prompt .. " "
	elseif prompt:sub(-1) ~= " " then
		prompt = prompt .. " "
	end
	local prompt_matches = {}
	if root_text ~= "" then
		prompt_matches[#prompt_matches + 1] = { #prompt_prefix, #prompt_prefix + #root_text, "Title" }
	end
	local scope_start = #prompt_prefix + #root_text + (root_text ~= "" and scope_text ~= "" and 2 or 0)
	local scope_matches = scope.prompt_matches(scoped, scope_start)
	if scope_matches then
		vim.list_extend(prompt_matches, scope_matches)
	end
	return {
		prompt = prompt,
		addons = {
			ghost = query == "" and active_panel and active_panel.label or nil,
			right = { text = string.format("%d/%s", found, total_text), hl = "LineNr" },
			prompt_matches = prompt_matches,
		},
	}
end

local function compute_body_layout(items, stats, mod, panels, active_panel)
	local item = current_item() or stats.first
	local show_panels = active_panel ~= nil and panel.header_item(panels, active_panel.name or nil) ~= nil
	local panel_rows = show_panels and 2 or 0
	local actions, ordered = panel_actions(item)
	local action_rows = 0
	for _, lhs in ipairs(ordered) do
		if actions[lhs] and actions[lhs].enabled then
			action_rows = 2
			break
		end
	end
	local total_height = math.max(layout.resolve_max_height(current_box_opts().height) - 2 - panel_rows - action_rows, 1)
	local item_total = stats.count
	local list_need = math.max(item_total == 0 and state.list.min_visible or item_total, state.list.min_visible)
	local list_height = state.fullscreen and total_height or math.min(list_need, total_height)
	local context_height, spec = 0, nil

	if should_show_context(mod and mod.context, item) then
		context_height, spec = context_spec(item, mod)
		list_height, context_height = split_body_height(total_height, list_height, context_height)
	elseif state.fullscreen then
		list_height = total_height
	end

	return {
		show_panels = show_panels,
		list_height = list_height,
		context_height = context_height,
		context_spec = spec,
	}
end

local function render_current_view(body, menu, opts)
	opts = opts or {}
	local action_runs, action_labels, ordered = {}, {}, {}
	do
		local actions, all = panel_actions()
		for _, lhs in ipairs(all) do
			local entry = actions[lhs]
			if entry and entry.enabled then
				action_runs[lhs] = entry.run
				action_labels[lhs] = entry.label
				ordered[#ordered + 1] = lhs
			end
		end
	end
	state.list:set_max_visible(body.list_height)
	state.list:set_fill_height(state.fullscreen)
	state.session.layout:apply(state.list.visible_count, body.context_height, {
		list = state.list,
		context = state.context,
		input = state.input,
		panels = state.session.panels,
		actions = state.session.actions,
		show_panels = body.show_panels,
		show_actions = #ordered > 0,
	})
	panel.render(state.session.panels, state.session.panels_ns, menu)
	action_menu.render(
		state.session and state.session.actions,
		state.session and state.session.actions_ns,
		action_labels,
		action_runs,
		ordered
	)
	if state.context and state.context.win and vim.api.nvim_win_is_valid(state.context.win) then
		if body.context_spec then
			state.context:set(unpack(body.context_spec))
		else
			state.context:set({}, "text", {}, nil, 1)
		end
	end
	if not opts.keep_scroll then
		state.list:ensure_visible()
	end
	state.list:render(vim.api.nvim_win_get_width(state.list.win))
end

local function move_selection(delta)
	if not state.list:move(delta, is_header) then
		return
	end
	update_active()
	local stats = analyse_items(state.items)
	render_current_view(
		compute_body_layout(state.items, stats, state.current.mod, state.current.panels, state.current.panel_entry),
		state.current.menu
	)
end

local function scroll_list(delta)
	if not state.list then
		return false
	end
	local mouse = vim.fn.getmousepos()
	if type(mouse) ~= "table" or mouse.winid ~= state.list.win then
		return false
	end
	state.list:scroll(delta)
	vim.schedule(function()
		if not is_visible() or not state.list then
			return
		end
		local width = (state.list.win and vim.api.nvim_win_is_valid(state.list.win)) and vim.api.nvim_win_get_width(state.list.win)
			or nil
		state.list:render(width)
	end)
	return true
end

local function toggle_fullscreen()
	if not is_visible() then
		return
	end
	state.fullscreen = not state.fullscreen
	apply_box_size()
	refresh()
	schedule_focus_input()
end

local function compute_view_model()
	local prompt = state.input:get_value()
	local mode_name, query = config.parse_prompt(prompt)
	local mod = state.registry[mode_name]
	local current_scope = panel.scope_type(state.scope)

	mode_name, mod, current_scope, redirected = reconcile_scope(prompt, mode_name, mod, current_scope)
	if redirected then
		return nil, true
	end
	ensure_buffer_scope(mod)

	local initial_panel = state.pending_initial_panel
	local panels, active_panel, redirected_panel = resolve_panel(prompt, mode_name, mod, initial_panel)
	if redirected_panel then
		return nil, true
	end

	mode_name = active_panel and active_panel.navigator or mode_name
	mod = state.registry[mode_name]
	local active_panel_name = active_panel and active_panel.panel or panel.active_name(state.active_panels, mode_name, mod and mod.panels, initial_panel)
	local navigator = navigator_state(mode_name)
	navigator.scope = state.scope
	local mode_switched = mode_name ~= state.current.mode_name
	local selected = item_key(current_item())
	local items = mod.items(navigator, query, active_panel_name)
	local stats = analyse_items(items, selected)
	local found = stats.count
	local total = found
	local total_plus = false
	if mod and type(mod.total_count) == "function" then
		local ok, count = pcall(mod.total_count, navigator, active_panel_name)
		if ok and type(count) == "table" then
			if type(count.count) == "number" then
				total = math.max(count.count, found)
			end
			total_plus = count.plus == true
		elseif ok and type(count) == "number" then
			total = math.max(count, found)
		end
	end
	local total_text = tostring(total) .. (total_plus and "+" or "")
	return {
		mode_name = mode_name,
		mod = mod,
		state_obj = navigator,
		query = query,
		panel = active_panel_name,
		panel_entry = active_panel,
		panels = panels,
		menu = panel.header_item(panels, active_panel and active_panel.name or nil),
		items = items,
		item_stats = stats,
		prompt_ui = prompt_ui(mod, navigator, query, active_panel, found, total_text),
		mode_switched = mode_switched,
		selected_key = selected,
	}, false
end

local function apply_view_model(vm)
	local query_changed = vm.query ~= state.current.query
	state.current.mode_name = vm.mode_name
	state.current.mod = vm.mod
	state.current.state = vm.state_obj
	state.current.query = vm.query
	state.current.panel = vm.panel
	state.current.panel_entry = vm.panel_entry
	state.current.panels = vm.panels
	state.current.menu = vm.menu
	state.items = vm.items
	state.pending_initial_panel = nil

	state.list:set_items(vm.items)
	state.list:set_allow_empty_selection(vm.mod and vm.mod.allow_empty_selection == true)
	if state.pending_selected_key and not (vm.mod and vm.mod.allow_empty_selection == true) then
		state.list:set_selected(analyse_items(vm.items, state.pending_selected_key).selected_index or state.list.selected)
		state.pending_selected_key = nil
	elseif query_changed then
		state.list.viewport_top = 1
		state.list:set_selected(vm.item_stats.first_index or ((vm.mod and vm.mod.allow_empty_selection == true) and 0 or 1))
	elseif vm.mode_switched then
		state.list:set_selected((vm.mod and vm.mod.allow_empty_selection == true) and 0 or 1)
	elseif vm.selected_key then
		state.list:set_selected(vm.item_stats.selected_index or state.list.selected)
	end
	if is_header(state.list:selected_item()) then
		state.list:move(1, is_header)
	end

	state.input:set_prompt(vm.prompt_ui.prompt, { move_cursor_end = true })
	state.input:set_addons(vm.prompt_ui.addons)
	sync_panel_action_keymaps()
	render_current_view(compute_body_layout(vm.items, vm.item_stats, vm.mod, vm.panels, vm.panel_entry), vm.menu)
end

refresh = function()
	local vm, redirected = compute_view_model()
	if redirected or not vm then
		return
	end
	update_active()
	apply_view_model(vm)
end

local function switch_panel(direction)
	remember_selection(state.current.mode_name, state.current.panel, state.scope, current_item())
	local panels = visible_panels()
	local active = panel.find_panel(panels, state.current.mode_name, state.current.panel)
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
		panel.select(state.active_panels, target)
		state.pending_selected_key = remembered_selection(target.navigator, target.panel, state.scope)
		if not is_visible() or not state.input then
			return
		end
			state.input:set_value(config.switch_prompt(state.input:get_value(), target.navigator), { move_cursor_end = true })
			refresh()
	end)
	return true
end

local function run_panel_action(lhs)
	local entry = (panel_actions())[lhs]
	if entry and entry.enabled and type(entry.run) == "function" then
		if entry.run(action_ctx()) ~= false then
			schedule_focus_input()
		end
		return true
	end
	return entry ~= nil
end

local function apply_tab_action()
	run_panel_action("<Tab>")
end

sync_panel_action_keymaps = function()
	if not state.input or not state.list then
		return
	end
	local enabled, next = panel_actions()
	local next_keys = {}
	for _, lhs in ipairs(next) do
		if enabled[lhs] and type(enabled[lhs].run) == "function" then
			next_keys[#next_keys + 1] = lhs
		end
	end

	if vim.deep_equal(state.bound_action_keys, next_keys) then
		return
	end

	for _, lhs in ipairs(state.bound_action_keys or {}) do
		pcall(vim.keymap.del, { "n", "i" }, lhs, { buffer = state.input.buf })
		pcall(vim.keymap.del, "n", lhs, { buffer = state.list.buf })
	end

	state.bound_action_keys = next_keys

	for _, lhs in ipairs(state.bound_action_keys) do
		vim.keymap.set({ "n", "i" }, lhs, function() return run_panel_action(lhs) end, {
			buffer = state.input.buf,
			noremap = true,
			silent = true,
		})
		vim.keymap.set("n", lhs, function() return run_panel_action(lhs) end, {
			buffer = state.list.buf,
			noremap = true,
			silent = true,
		})
	end
end

local function click_tab_action()
	local mouse = vim.fn.getmousepos()
	if type(mouse) ~= "table" then
		return
	end

	if state.session.panels.win and mouse.winid == state.session.panels.win then
		local name = state.current.menu and panel.hit_test(state.current.menu, math.max((mouse.column or 1) - 2, 0))
		if name then
			for _, target in ipairs(visible_panels()) do
				if target.name == name then
					state.pending_selected_key = remembered_selection(target.navigator, target.panel, state.scope)
					panel.select(state.active_panels, target)
					state.input:set_value(config.switch_prompt(state.input:get_value(), target.navigator), { move_cursor_end = true })
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

	state.list:set_selected(state.list:item_index_for_row(mouse.line) or state.list.selected)
	update_active()
	local stats = analyse_items(state.items)
	render_current_view(
		compute_body_layout(state.items, stats, state.current.mod, state.current.panels, state.current.panel_entry),
		state.current.menu
	)
	apply_tab_action()
end

local function move_panel_from_input(direction)
	local panels = visible_panels()
	local active = panel.find_panel(panels, state.current.mode_name, state.current.panel)
	local idx = panel.active_index(panels, active and active.name or nil)
	if not idx then
		return false
	end
	if not state.input:is_cursor_at_end() then
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
	local function map_expr(mode_names, lhs, rhs, buffer)
		vim.keymap.set(mode_names, lhs, rhs, vim.tbl_extend("force", map_opts, { buffer = buffer, expr = true }))
	end

	for lhs, delta in pairs({ ["<Down>"] = 1, ["<Up>"] = -1 }) do
		map("n", lhs, function() move_selection(delta) end, state.list.buf)
	end
	for lhs, delta in pairs({ ["<Right>"] = 1, ["<Left>"] = -1 }) do
		map("n", lhs, function()
			local panels = visible_panels()
			if panels and #panels > 1 then
				switch_panel(delta)
			end
		end, state.list.buf)
	end
	map("n", "<LeftMouse>", click_tab_action, state.list.buf)
	map({ "n", "i" }, "<LeftMouse>", click_tab_action, state.input.buf)
	map({ "n", "i" }, "<ScrollWheelDown>", function() return scroll_list(3) end, state.list.buf)
	map({ "n", "i" }, "<ScrollWheelUp>", function() return scroll_list(-3) end, state.list.buf)
	map_expr({ "n", "i" }, "<ScrollWheelDown>", function()
		return scroll_list(3) and "" or "<ScrollWheelDown>"
	end, state.input.buf)
	map_expr({ "n", "i" }, "<ScrollWheelUp>", function()
		return scroll_list(-3) and "" or "<ScrollWheelUp>"
	end, state.input.buf)
	map({ "n", "i" }, "<ScrollWheelLeft>", function() return true end, state.list.buf)
	map({ "n", "i" }, "<ScrollWheelRight>", function() return true end, state.list.buf)
	map_expr({ "n", "i" }, "<ScrollWheelLeft>", function()
		local mouse = vim.fn.getmousepos()
		return (type(mouse) == "table" and mouse.winid == state.list.win) and "" or "<ScrollWheelLeft>"
	end, state.input.buf)
	map_expr({ "n", "i" }, "<ScrollWheelRight>", function()
		local mouse = vim.fn.getmousepos()
		return (type(mouse) == "table" and mouse.winid == state.list.win) and "" or "<ScrollWheelRight>"
	end, state.input.buf)
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
		state.context = context_view.new({
			buf = (sections.context and sections.context.buf) or vim.api.nvim_create_buf(false, true),
			win = sections.context and sections.context.win or nil,
		})

		local files_navigator = state.registry.files
		state.input = ui.input.new({
			buf = sections.input.buf,
			win = sections.input.win,
			prompt = " " .. ((files_navigator and files_navigator.icon) or "") .. " ",
			debounce_ms = 50,
			on_change = refresh,
			on_shift_enter = toggle_fullscreen,
			on_escape = hide,
			on_down = function() move_selection(1) end,
			on_up = function() move_selection(-1) end,
			on_left = function() return move_panel_from_input(-1) end,
			on_right = function() return move_panel_from_input(1) end,
			on_backspace = function(value)
				local scoped = nil
				if state.current.mod and type(state.current.mod.input_scope) == "function" then
					scoped = state.current.mod.input_scope(state.current.state, state.scope)
				end
				local start = state.current.panel_entry and state.current.panel_entry.start or ""
					if scoped and scoped.kind ~= "workspace" and start ~= "" and value == start then
						clear_prefix()
						return true
					end
					if scoped and scoped.kind ~= "workspace" and value == "" then
						apply_scope_change(nil)
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
	state.registry = config.registry()
	state.modules = config.options.navigators or {}
	state.navigator_opts = session_mod.normalize_opts(vim.tbl_deep_extend("force", config.options or {}, opts or {}))
	state.fullscreen = state.navigator_opts.fullscreen == true
	state.pending_initial_panel = state.navigator_opts.initial_panel
	state.session = session_mod.ensure(state.navigator_opts)
	state.source_bufnr = vim.api.nvim_get_current_buf()
	state.source_win = vim.api.nvim_get_current_win()
	local next_cwd = state.navigator_opts.cwd or vim.fn.getcwd()
	local preserved_files = (state.cwd == next_cwd) and state.states.files or nil
	local preserved_scope = (state.cwd == next_cwd) and state.scope or nil
	state.cwd = next_cwd
	if state.navigator_opts.scope ~= nil then
		state.scope = state.navigator_opts.scope
	else
		state.scope = preserved_scope
	end
	state.states = preserved_files and { files = preserved_files } or {}

	local ok, err = state.session:mount(refresh)
	if not ok then
		vim.notify("Pulse: unable to open navigator (" .. tostring(err) .. ")", vim.log.levels.WARN)
		return
	end

	local last_dims = state.session.layout.last_dims or {}
	state.session.layout:apply(last_dims.body or 10, last_dims.context or 0, { show_panels = last_dims.panels == true })
	bind_widgets()

	if state.navigator_opts.initial_prompt and state.navigator_opts.initial_prompt ~= "" then
		state.input:set_value(state.navigator_opts.initial_prompt, { move_cursor_end = true })
	end

	apply_box_size()
	refresh()
	state.input:focus(true)
end

function M.open(opts)
	show(opts)
end

function M.toggle(opts)
	state.navigator_opts = session_mod.normalize_opts(vim.tbl_deep_extend("force", config.options or {}, opts or {}))
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
