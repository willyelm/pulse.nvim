local ui = require("pulse.ui")
local actions = require("pulse.actions")
local display = require("pulse.display")
local mode = require("pulse.mode")
local preview_data = require("pulse.preview")
local config = require("pulse.config")

local M = {}

local function is_header(item)
	return item and item.kind == "header"
end

local function resolve_max_height(height_cfg)
	local total = vim.o.lines - vim.o.cmdheight
	local h = type(height_cfg) == "number" and height_cfg or 0.5
	return math.max((h > 0 and h < 1) and math.floor(total * h) or math.floor(h), 6)
end

local function new_layout(box)
	local layout = { sections = {}, last_dims = {} }

	local function upsert(name, opts)
		local current = layout.sections[name]
		if current and current.buf and vim.api.nvim_buf_is_valid(current.buf) then
			opts.buf = current.buf
		end
		layout.sections[name] = box:create_section(name, opts)
		return layout.sections[name]
	end

	local function draw_divider(buf, width)
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("─", width) })
		vim.bo[buf].modifiable = false
	end

	function layout:apply(body_height, preview_height, refs)
		local width = vim.api.nvim_win_get_width(box.win)
		local show_preview = preview_height > 0
		if
			self.sections.input
			and self.last_dims.body == body_height
			and self.last_dims.preview == preview_height
			and self.last_dims.width == width
		then
			return
		end

		box:update({ height = body_height + (show_preview and preview_height or 0) + (show_preview and 3 or 2) })
		width = vim.api.nvim_win_get_width(box.win)

		local specs = {
			{ name = "input", row = 0, height = 1, focusable = true, winhl = "Normal:NormalFloat" },
			{ name = "divider", row = 1, height = 1, focusable = false, winhl = "Normal:FloatBorder", divider = true },
			{ name = "list", row = 2, height = body_height, focusable = true, winhl = "Normal:NormalFloat,CursorLine:CursorLine" },
		}

		if show_preview then
			specs[#specs + 1] = { name = "body_divider", row = 2 + body_height, height = 1, focusable = false, winhl = "Normal:FloatBorder", divider = true }
			specs[#specs + 1] = { name = "preview", row = 3 + body_height, height = preview_height, focusable = true, winhl = "Normal:NormalFloat" }
		else
			box:close_section("body_divider")
			box:close_section("preview")
			self.sections.body_divider = nil
			self.sections.preview = nil
		end

		for _, s in ipairs(specs) do
			local section = upsert(s.name, {
				row = s.row,
				col = 0,
				width = width,
				height = s.height,
				focusable = s.focusable,
				enter = false,
				winhl = s.winhl,
			})
			if s.divider then
				draw_divider(section.buf, width)
			end
		end

		if refs.list then
			refs.list.win = self.sections.list.win
		end
		if refs.input then
			refs.input:set_win(self.sections.input.win)
		end
		if refs.preview then
			local buf, win = show_preview and self.sections.preview.buf or nil, show_preview and self.sections.preview.win or nil
			refs.preview:set_target(buf, win)
		end

		self.last_dims = { body = body_height, preview = preview_height, width = width }
	end

	return layout
end

function M.open(opts)
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
	local active_mode = "files"
	local closed, input, refresh = false, nil, nil
	local registry = config.options._picker_registry or {}

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
	local layout = new_layout(box)

	local function close_palette()
		if closed then
			return
		end
		closed = true
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

	local function rerender()
		if closed then
			return
		end
		local max_total = resolve_max_height(picker_opts.height)
		local selected = list:selected_item()
		local preview_item

		-- Determine if preview should be shown
		local mod = registry[active_mode]
		local should_preview = false
		if mod then
			local preview_cfg = mod.preview
			if type(preview_cfg) == "function" then
				-- Dynamic preview: call function with selected item
				if not is_header(selected) then
					should_preview = preview_cfg(selected) == true
				else
					-- Try first non-header item
					for _, item in ipairs(items) do
						if not is_header(item) then
							should_preview = preview_cfg(item) == true
							break
						end
					end
				end
			elseif preview_cfg == true then
				-- Static preview enabled
				should_preview = true
			end
		end

		if should_preview then
			if not is_header(selected) then
				preview_item = selected
			else
				for _, item in ipairs(items) do
					if not is_header(item) then
						preview_item = item
						break
					end
				end
			end
		end

		local preview_height, body_height
		if preview_item then
			local lines, ft, highlights, line_numbers, focus_row = preview_data.for_item(preview_item)
			local line_count = math.max(#(lines or {}), 1)
			local available = math.max(max_total - 3, 2)
			body_height = math.min(list.visible_count, available - 1)
			preview_height = math.min(line_count, available - body_height)

			layout:apply(body_height, preview_height, { list = list, preview = preview, input = input })

			-- Set preview content AFTER layout is applied to ensure window is valid
			if preview and preview.win and vim.api.nvim_win_is_valid(preview.win) then
				preview:set(lines, ft, highlights, line_numbers, focus_row)
			end
		else
			body_height = math.min(list.visible_count, math.max(max_total - 2, 1))
			preview_height = 0
			layout:apply(body_height, preview_height, { list = list, preview = preview, input = input })
		end

		list:render(vim.api.nvim_win_get_width(list.win))
	end

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

	local function move_selection(delta)
		list:move(delta, is_header)
		local selected = list:selected_item()
		local mod = registry[active_mode]
		if mod and type(mod.on_active) == "function" and selected and not is_header(selected) then
			mod.on_active({
				item = selected,
				query = select(2, mode.parse_prompt(input:get_value())),
				close = close_palette,
				jump = jump_in_source,
				input = input,
				mode = registry[active_mode] and registry[active_mode].mode,
			})
		end
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

	local function update_counter(mode_name, query, found, total)
		local picker = registry[mode_name]
		local picker_mode = picker and picker.mode
		input:set_prompt(" " .. (picker_mode and picker_mode.icon or "") .. " ")
		local placeholder = picker_mode and picker_mode.placeholder or ""
		input:set_addons({
			ghost = (query or "") == "" and placeholder ~= "" and placeholder or nil,
			right = { text = string.format("%d/%d", found, total), hl = "LineNr" },
		})
	end

	function refresh()
		local prompt = input:get_value()
		local mode_name, query = mode.parse_prompt(prompt)
		local mod = registry[mode_name]
		local state = ensure_state(mode_name)
		local mode_switched = mode_name ~= active_mode
		active_mode = mode_name

		local next_items = mod.items(state, query)
		local found = 0
		for _, item in ipairs(next_items or {}) do
			if not is_header(item) then
				found = found + 1
			end
		end

		if found == 0 and #next_items > 0 then
			next_items = {}
		end

		items = next_items
		list:set_items(next_items)

		if mode_switched then
			local allows_empty = mod and mod.allow_empty_selection == true
			list:set_allow_empty_selection(allows_empty)
			list:set_selected(allows_empty and 0 or 1)
		end

		local total = found
		if mod and type(mod.total_count) == "function" then
			local ok, count = pcall(mod.total_count, state)
			if ok and type(count) == "number" then
				total = math.max(count, found)
			end
		end

		update_counter(mode_name, query, found, total)

		if is_header(list:selected_item()) then
			list:move(1, is_header)
		end

		-- Call on_active hook for newly selected item
		local selected = list:selected_item()
		if mod and type(mod.on_active) == "function" and selected and not is_header(selected) then
			mod.on_active({
				item = selected,
				query = query,
				close = close_palette,
				jump = jump_in_source,
				input = input,
				mode = registry[active_mode] and registry[active_mode].mode,
			})
		end

		rerender()
	end

	local function make_hook_ctx(mode_name, item)
		return {
			item = item,
			query = select(2, mode.parse_prompt(input:get_value())),
			close = close_palette,
			jump = jump_in_source,
			input = input,
			mode = registry[mode_name] and registry[mode_name].mode,
		}
	end

	local function submit(prompt)
		local mode_name, query = mode.parse_prompt(prompt)
		local selected = list:selected_item()
		local mod = registry[mode_name]
		local item = (selected and not is_header(selected)) and selected or nil

		if mod and type(mod.on_submit) == "function" then
			mod.on_submit(make_hook_ctx(mode_name, item))
			return
		end

		if item and jump_in_source(item) then
			close_palette()
		end
	end

	local function apply_tab_action(selected)
		selected = selected or list:selected_item()
		if not selected or is_header(selected) then
			return
		end

		local mod = registry[active_mode]
		local on_tab = mod and mod.on_tab
		if on_tab == false then
			return
		end

		if type(on_tab) == "function" then
			on_tab(make_hook_ctx(active_mode, selected))
			return
		end

		jump_in_source(selected)
	end

	local function click_tab_action()
		local mouse = vim.fn.getmousepos()
		if type(mouse) == "table" and mouse.winid == list.win then
			list:set_selected(tonumber(mouse.line) or 1)
			rerender()
			apply_tab_action()
		end
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
	})

	-- Setup keymaps
	local list_buf = layout.sections.list.buf
	vim.keymap.set("n", "<Down>", function() move_selection(1) end, { buffer = list_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<Right>", function() move_selection(1) end, { buffer = list_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<Up>", function() move_selection(-1) end, { buffer = list_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<Left>", function() move_selection(-1) end, { buffer = list_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<LeftMouse>", click_tab_action, { buffer = list_buf, noremap = true, silent = true })
	vim.keymap.set({ "n", "i" }, "<LeftMouse>", click_tab_action, { buffer = input.buf, noremap = true, silent = true })
	vim.keymap.set("n", "<CR>", function() submit(input:get_value()) end, { buffer = list_buf, noremap = true, silent = true })
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
