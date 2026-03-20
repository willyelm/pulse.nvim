local ui = require("pulse.ui")
local actions = require("pulse.actions")
local display = require("pulse.display")
local mode = require("pulse.mode")
local preview_data = require("pulse.preview")
local config = require("pulse.config")
local layout_mod = require("pulse.layout")
local panel = require("pulse.panel")

local M = {}

local function is_header(item)
	return item and item.kind == "header"
end

local function active_or_first(selected, items)
	if selected and not is_header(selected) then
		return selected
	end
	for _, item in ipairs(items or {}) do
		if not is_header(item) then
			return item
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

function M.open(opts)
	panel.setup_hl()

	local picker_opts = vim.tbl_deep_extend("force", {
		initial_mode = "insert",
		position = "top",
		width = 0.70,
		height = 0.50,
		border = true,
	}, opts or {})

	local source_bufnr = vim.api.nvim_get_current_buf()
	local source_win = vim.api.nvim_get_current_win()
	local cwd = vim.fn.getcwd()
	local states, items = {}, {}
	local active_panels = {}
	local closed, input, refresh = false, nil, nil
	local registry = config.options._picker_registry or {}
	local current = {
		mode_name = nil,
		mod = nil,
		query = "",
		panel = nil,
		panel_header = nil,
	}

	local box = ui.box.new({
		width = picker_opts.width or 0.70,
		height = picker_opts.height or 0.50,
		row = (picker_opts.position == "top") and 1 or nil,
		col = 0.5,
		border = (picker_opts.border == true) and "single" or picker_opts.border,
		focusable = true,
		zindex = 60,
		winhl = "Normal:NormalFloat,FloatBorder:FloatBorder",
	})

	local main_win, _, mount_err = box:mount()
	if not main_win then
		vim.notify("Pulse: unable to open panel (" .. tostring(mount_err) .. ")", vim.log.levels.WARN)
		return
	end

	local lifecycle_group = vim.api.nvim_create_augroup("PulseUIPalette" .. box.buf, { clear = true })
	local list, preview
	local panels = { buf = nil, win = nil }
	local panels_ns = vim.api.nvim_create_namespace("pulse_ui_panels")
	local layout = layout_mod.new(box)

	local function close_palette()
		if closed then
			return
		end
		closed = true
		if input then
			vim.g.pulse_last_prompt = input:get_value()
			vim.g.pulse_last_selected = list.selected
		end
		for mode_name, state in pairs(states) do
			local mod = registry[mode_name]
			if mod and type(mod.dispose) == "function" then
				pcall(mod.dispose, state)
			end
		end
		box:unmount()
		if vim.api.nvim_win_is_valid(source_win) then
			vim.api.nvim_set_current_win(source_win)
		end
	end

	vim.api.nvim_create_autocmd("WinClosed", {
		group = lifecycle_group,
		pattern = tostring(box.win),
		once = true,
		callback = close_palette,
	})

	local function ensure_state(mode_name)
		if states[mode_name] then
			return states[mode_name]
		end
		states[mode_name] = registry[mode_name].init({
			on_update = function()
				if not closed and refresh then
					vim.schedule(refresh)
				end
			end,
			bufnr = source_bufnr,
			win = source_win,
			cwd = cwd,
		})
		return states[mode_name]
	end

	-- Initialize layout sections
	layout:apply(10, 8, {})

	list = ui.list.new({
		buf = layout.sections.list.buf,
		win = layout.sections.list.win,
		max_visible = 15,
		min_visible = 1,
		render_item = display.to_display,
	})
	preview = preview_data.new({ buf = layout.sections.preview.buf, win = layout.sections.preview.win })

	local function switch_panel(direction)
		local mod = current.mod
		local idx = panel.active_index(mod and mod.panels, current.panel)
		local picker_panels = mod and mod.panels
		if not idx or not picker_panels then
			return false
		end

		local next_idx = idx + direction
		if next_idx < 1 or next_idx > #picker_panels then
			return false
		end

		active_panels[current.mode_name] = picker_panels[next_idx].name
		vim.schedule(function()
			if not closed and refresh then
				refresh()
			end
		end)
		return true
	end

	local function current_item()
		local selected = list:selected_item()
		return (selected and not is_header(selected)) and selected or nil
	end

	local function hook_ctx(item)
		return {
			item = item,
			query = current.query,
			close = close_palette,
			jump = jump_in_source,
			input = input,
			mode = current.mod and current.mod.mode,
		}
	end

	local function update_active_item()
		local item = current_item()
		if current.mod and type(current.mod.on_active) == "function" and item then
			current.mod.on_active(hook_ctx(item))
		end
	end

	local function rerender()
		if closed then
			return
		end

		local preview_cfg = current.mod and current.mod.preview
		local preview_item = active_or_first(list:selected_item(), items)
		local show_preview = preview_item and ((type(preview_cfg) == "function" and preview_cfg(preview_item) == true) or preview_cfg == true)
		local panel_rows = panels.buf and 2 or 0
		local max_total = layout_mod.resolve_max_height(picker_opts.height)
		local body_height = math.min(list.visible_count, math.max(max_total - 2 - panel_rows, 1))
		local preview_height = 0
		local preview_spec

		if show_preview and preview_item then
			local lines, ft, highlights, line_numbers, focus_row = preview_data.for_item(preview_item, current.mod and current.mod.preview_item)
			local line_count = math.max(#(lines or {}), 1)
			local available = math.max(max_total - 3 - panel_rows, 2)
			body_height = math.min(list.visible_count, available - 1)
			preview_height = math.min(line_count, available - body_height)
			preview_spec = { lines, ft, highlights, line_numbers, focus_row }
		end

		layout:apply(body_height, preview_height, {
			list = list,
			preview = preview,
			input = input,
			panels = panels,
			show_panels = current.panel_header ~= nil,
		})
		panel.render(panels, panels_ns, current.panel_header)

		if preview_spec and preview and preview.win and vim.api.nvim_win_is_valid(preview.win) then
			preview:set(unpack(preview_spec))
		end

		list:render(vim.api.nvim_win_get_width(list.win))
	end

	local function move_selection(delta)
		list:move(delta, is_header)
		update_active_item()
		rerender()
	end

	local function jump_in_source(item)
		local jumped
		local function do_jump()
			jumped = actions.jump_to(item)
		end
		if vim.api.nvim_win_is_valid(source_win) then
			pcall(vim.api.nvim_win_call, source_win, do_jump)
		else
			do_jump()
		end
		return jumped
	end

	function refresh()
		local prompt = input:get_value()
		local mode_name, query = mode.parse_prompt(prompt)
		local mod = registry[mode_name]
		local state = ensure_state(mode_name)
		local mode_switched = mode_name ~= current.mode_name
		local active_panel = panel.active_name(active_panels, mode_name, mod and mod.panels, picker_opts.initial_panel)

		local next_items = mod.items(state, query, active_panel)
		local found = item_count(next_items)

		if found == 0 and #next_items > 0 then
			next_items = {}
		end

		current.mode_name = mode_name
		current.mod = mod
		current.query = query
		current.panel = active_panel
		current.panel_header = panel.header_item(mod and mod.panels, active_panel)
		items = next_items

		list:set_items(items)

		if mode_switched then
			local allows_empty = mod and mod.allow_empty_selection == true
			list:set_allow_empty_selection(allows_empty)
			list:set_selected(allows_empty and 0 or 1)
		elseif prompt == vim.g.pulse_last_prompt and vim.g.pulse_last_selected then
			-- Restore previous selection if prompt matches
			list:set_selected(vim.g.pulse_last_selected)
		end

		local total = found
		if mod and type(mod.total_count) == "function" then
			local ok, count = pcall(mod.total_count, state, active_panel)
			if ok and type(count) == "number" then
				total = math.max(count, found)
			end
		end

		local picker_mode = mod and mod.mode
		local placeholder = picker_mode and picker_mode.placeholder or ""
		input:set_prompt(" " .. (picker_mode and picker_mode.icon or "") .. " ")
		input:set_addons({
			ghost = query == "" and placeholder ~= "" and placeholder or nil,
			right = { text = string.format("%d/%d", found, total), hl = "LineNr" },
		})

		if is_header(list:selected_item()) then list:move(1, is_header) end
		update_active_item()

		rerender()
	end

	local function submit()
		local item = current_item()

		if current.mod and type(current.mod.on_submit) == "function" then
			current.mod.on_submit(hook_ctx(item))
			return
		end

		if item and jump_in_source(item) then
			close_palette()
		end
	end

	local function apply_tab_action(selected)
		selected = selected or current_item()
		if not selected then
			return
		end

		local on_tab = current.mod and current.mod.on_tab
		if on_tab == false then
			return
		end

		if type(on_tab) == "function" then
			on_tab(hook_ctx(selected))
			return
		end

		jump_in_source(selected)
	end

	local function click_tab_action()
		local mouse = vim.fn.getmousepos()
		if type(mouse) ~= "table" then
			return
		end
		if panels.win and mouse.winid == panels.win then
			local mod = current.mod
			local picker_panels = mod and mod.panels
			if not picker_panels or #picker_panels < 2 then
				return
			end
			local col = math.max((mouse.column or 1) - 2, 0)
			local name = panel.hit_test(picker_panels, col)
			if name then
				active_panels[current.mode_name] = name
				refresh()
				return
			end
		elseif mouse.winid == list.win then
			list:set_selected(tonumber(mouse.line) or 1)
			rerender()
			apply_tab_action()
		end
	end

	local function on_input_left()
		local current_idx = panel.active_index(current.mod and current.mod.panels, current.panel)
		if not current_idx then
			return false
		end

		local line = input:get_value()
		local cursor = vim.api.nvim_win_get_cursor(input.win)
		if cursor[2] >= #line and current_idx > 1 then
			return switch_panel(-1)
		end
		return false
	end

	local function on_input_right()
		local mod = current.mod
		local current_idx = panel.active_index(mod and mod.panels, current.panel)
		if not current_idx then
			return false
		end

		local line = input:get_value()
		local cursor = vim.api.nvim_win_get_cursor(input.win)
		if cursor[2] >= #line then
			return current_idx < #(mod.panels or {}) and switch_panel(1) or false
		end
		return false
	end

	local files_picker = registry["files"]
	input = ui.input.new({
		buf = layout.sections.input.buf,
		win = layout.sections.input.win,
		prompt = " " .. (files_picker and files_picker.mode and files_picker.mode.icon or "") .. " ",
		on_change = refresh,
		on_submit = submit,
		on_escape = close_palette,
		on_down = function() move_selection(1) end,
		on_up = function() move_selection(-1) end,
		on_tab = apply_tab_action,
		on_left = on_input_left,
		on_right = on_input_right,
	})


	-- Setup keymaps for list
	local list_buf = layout.sections.list.buf
	vim.keymap.set("n", "<Down>", function() move_selection(1) end, { buffer = list_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<Up>", function() move_selection(-1) end, { buffer = list_buf, noremap = true, silent = true })
	-- Left/Right switch panels if multiple panels exist
	vim.keymap.set("n", "<Right>", function()
		local mod = current.mod
		if mod and mod.panels and #mod.panels > 1 then
			switch_panel(1)
		end
	end, { buffer = list_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<Left>", function()
		local mod = current.mod
		if mod and mod.panels and #mod.panels > 1 then
			switch_panel(-1)
		end
	end, { buffer = list_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<LeftMouse>", click_tab_action, { buffer = list_buf, noremap = true, silent = true })
	vim.keymap.set({ "n", "i" }, "<LeftMouse>", click_tab_action, { buffer = input.buf, noremap = true, silent = true })
	vim.keymap.set("n", "<CR>", submit, { buffer = list_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<Tab>", apply_tab_action, { buffer = list_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<Esc>", close_palette, { buffer = list_buf, noremap = true, silent = true })

	vim.api.nvim_create_autocmd("VimResized", {
		group = lifecycle_group,
		callback = function()
			box:update()
			rerender()
		end,
	})

	if picker_opts.initial_prompt and picker_opts.initial_prompt ~= "" then
		input:set_value(picker_opts.initial_prompt)
	end

	refresh()
	input:focus(picker_opts.initial_mode ~= "normal")
end

return M
