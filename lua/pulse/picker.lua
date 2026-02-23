local ui = require("pulse.ui")
local actions = require("pulse.actions")
local display = require("pulse.display")
local mode = require("pulse.mode")
local preview_data = require("pulse.preview")

local modules = {
	files = require("pulse.pickers.files"),
	commands = require("pulse.pickers.commands"),
	symbol = require("pulse.pickers.symbols"),
	workspace_symbol = require("pulse.pickers.workspace_symbols"),
	live_grep = require("pulse.pickers.live_grep"),
	fuzzy_search = require("pulse.pickers.fuzzy_search"),
	git_status = require("pulse.pickers.git_status"),
	diagnostics = require("pulse.pickers.diagnostics"),
}

local M = {}

local function is_header(item)
	return item and item.kind == "header"
end

local function count_non_headers(items)
	local count = 0
	for _, item in ipairs(items or {}) do
		if not is_header(item) then
			count = count + 1
		end
	end
	return count
end

local function find_preview_item(selected, items_list)
	if not is_header(selected) then return selected end
	for _, item in ipairs(items_list) do
		if not is_header(item) then return item end
	end
	return nil
end

local function total_for_mode(mod, state, found)
	if mod and type(mod.total_count) == "function" then
		local ok, total = pcall(mod.total_count, state)
		if ok and type(total) == "number" then return math.max(total, found) end
	end
	return found
end

local function update_counter(input, mode_name, query, found, total)
	input:set_prompt(" " .. mode.icon(mode_name) .. " ")
	local placeholder = mode.placeholder(mode_name)
	input:set_addons({
		ghost = (query or "") == "" and placeholder ~= "" and placeholder or nil,
		right = { text = string.format("%d/%d", found, total), hl = "LineNr" },
	})
end

local function resolve_max_height(height_cfg)
	local total = vim.o.lines - vim.o.cmdheight
	local h = type(height_cfg) == "number" and height_cfg or 0.5
	return math.max((h > 0 and h < 1) and math.floor(total * h) or math.floor(h), 6)
end

local function new_layout(box)
	local layout = { sections = {}, state = { body = nil, preview = nil, width = nil } }

	local function upsert(name, opts)
		local current = layout.sections[name]
		if current and current.buf and vim.api.nvim_buf_is_valid(current.buf) then opts.buf = current.buf end
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
		if self.sections.input and self.state.body == body_height and self.state.preview == preview_height and self.state.width == width then
			return
		end

		box:update({ height = body_height + (show_preview and preview_height or 0) + (show_preview and 3 or 2) })
		width = vim.api.nvim_win_get_width(box.win)
		local inner_col = 0
		local inner_width = math.max(width, 1)

		local specs = {
			{ name = "input", row = 0, col = inner_col, width = inner_width, height = 1, focusable = true, winhl = "Normal:NormalFloat" },
			{ name = "divider", row = 1, height = 1, focusable = false, winhl = "Normal:FloatBorder", divider = true },
			{ name = "list", row = 2, col = inner_col, width = inner_width, height = body_height, focusable = true, winhl = "Normal:NormalFloat,CursorLine:CursorLine" },
		}
		if show_preview then
			specs[#specs + 1] = { name = "body_divider", row = 2 + body_height, height = 1, focusable = false, winhl = "Normal:FloatBorder", divider = true }
			specs[#specs + 1] = { name = "preview", row = 3 + body_height, col = inner_col, width = inner_width, height = preview_height, focusable = true, winhl = "Normal:NormalFloat" }
		else
			box:close_section("body_divider")
			self.sections.body_divider = nil
			box:close_section("preview")
			self.sections.preview = nil
		end

		for _, s in ipairs(specs) do
			local section = upsert(s.name, {
				row = s.row, col = s.col or 0, width = s.width or width,
				height = s.height, focusable = s.focusable, enter = false, winhl = s.winhl,
			})
			if s.divider then draw_divider(section.buf, width) end
		end

		if refs.list then refs.list.win = self.sections.list.win end
		if refs.input then refs.input:set_win(self.sections.input.win) end
		if refs.preview then
			local buf, win = show_preview and self.sections.preview.buf or nil, show_preview and self.sections.preview.win or nil
			refs.preview:set_target(buf, win)
		end

		self.state.body = body_height
		self.state.preview = preview_height
		self.state.width = width
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
	local command_selection_explicit = false
	local closed, input, refresh = false, nil, nil

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

	local lifecycle_group = vim.api.nvim_create_augroup("PulseUIPalette" .. tostring(box.buf), { clear = true })
	local list, preview
	local layout = new_layout(box)
	local function map(buf, modes, lhs, rhs)
		vim.keymap.set(modes, lhs, rhs, { buffer = buf, noremap = true, silent = true })
	end
	local function close_palette()
		if closed then return end
		closed = true
		for mode_name, state in pairs(states) do
			local mod = modules[mode_name]
			if mod and type(mod.dispose) == "function" then pcall(mod.dispose, state) end
		end
		box:unmount()
		if vim.api.nvim_win_is_valid(source_win) then vim.api.nvim_set_current_win(source_win) end
	end

	vim.api.nvim_create_autocmd("WinClosed", {
		group = lifecycle_group,
		pattern = tostring(box.win),
		once = true,
		callback = close_palette,
	})

	local function rerender()
		if closed then return end
		local max_total = resolve_max_height(picker_opts.height)
		local preview_item = mode.preview(active_mode) and find_preview_item(list:selected_item(), items) or nil
		local p, preview_height, body_height
		if preview_item then
			local lines, ft, highlights, line_numbers, focus_row = preview_data.for_item(preview_item)
			p = { lines = lines, ft = ft, highlights = highlights, line_numbers = line_numbers, focus_row = focus_row }
			local line_count = math.max(#(lines or {}), 1)
			local available = math.max(max_total - 3, 2)
			body_height = math.min(list.visible_count, available - 1)
			preview_height = math.min(line_count, available - body_height)
		else
			local available = math.max(max_total - 2, 1)
			body_height = math.min(list.visible_count, available)
			preview_height = 0
		end
		layout:apply(body_height, preview_height, { list = list, preview = preview, input = input })
		list:render(vim.api.nvim_win_get_width(list.win))
		if p and preview and preview.win and vim.api.nvim_win_is_valid(preview.win) then
			preview:set(p.lines, p.ft, p.highlights, p.line_numbers, p.focus_row)
		end
	end

	local function ensure_state(mode_name)
		if states[mode_name] then
			return states[mode_name]
		end
		if mode_name == "files" then
			states[mode_name] = modules.files.seed(cwd)
		elseif mode_name == "commands" then
			states[mode_name] = modules.commands.seed()
		else
			states[mode_name] = modules[mode_name].seed({
				on_update = function()
					if not closed and refresh then
						vim.schedule(refresh)
					end
				end,
				bufnr = source_bufnr,
				cwd = cwd,
			})
		end
		return states[mode_name]
	end

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
		if active_mode == "commands" then
			command_selection_explicit = true
		end
		rerender()
	end

	local function jump_in_source(item)
		local jumped
		local function do_jump() jumped = actions.jump_to(item) end
		if vim.api.nvim_win_is_valid(source_win) then
			pcall(vim.api.nvim_win_call, source_win, do_jump)
		else
			pcall(do_jump)
		end
		return jumped
	end

	function refresh()
		local prompt = input:get_value()
		local mode_name, query = mode.parse_prompt(prompt)
		local mod = modules[mode_name]
		local state = ensure_state(mode_name)
		local mode_switched = mode_name ~= active_mode
		active_mode = mode_name
		local next_items = mod.items(state, query)
		local found = count_non_headers(next_items)
		if found == 0 and #next_items > 0 then next_items = {} end

		items = next_items
		list:set_items(next_items)
		if mode_switched then
			command_selection_explicit = false
			local commands_mode = mode_name == "commands"
			list:set_allow_empty_selection(commands_mode)
			list:set_selected(commands_mode and 0 or 1)
		end
		update_counter(input, mode_name, query, found, total_for_mode(mod, state, found))

		if is_header(list:selected_item()) then
			list:move(1, is_header)
		end
		rerender()
	end

	local function submit(prompt)
		local mode_name, query = mode.parse_prompt(prompt)
		local selected = list:selected_item()
		if mode_name == "commands" then
			close_palette()
			if command_selection_explicit and selected and selected.kind == "command" then
				actions.execute_command(selected.command)
			elseif query ~= "" then
				actions.execute_command(query)
			end
			return
		end
		if selected and not is_header(selected) and jump_in_source(selected) then
			close_palette()
		end
	end

	local function apply_tab_action(selected)
		selected = selected or list:selected_item()
		if not selected or is_header(selected) or active_mode == "git_status" then return end
		if active_mode ~= "commands" then return jump_in_source(selected) end
		local cmd = tostring(selected.command or ""):gsub("^:", "")
		input:set_value(mode.start("commands") .. cmd)
		input:focus(true)
		command_selection_explicit = true
	end
	local function click_tab_action()
		local mouse = vim.fn.getmousepos()
		if type(mouse) ~= "table" or mouse.winid ~= list.win then return end
		list:set_selected(tonumber(mouse.line) or 1)
		rerender()
		apply_tab_action()
	end

	input = ui.input.new({
		buf = layout.sections.input.buf,
		win = layout.sections.input.win,
		prompt = " " .. mode.icon("files") .. " ",
		on_change = refresh,
		on_submit = submit,
		on_escape = close_palette,
		on_down = function() move_selection(1) end,
		on_up = function() move_selection(-1) end,
		on_tab = apply_tab_action,
	})

	local list_buf = layout.sections.list.buf
	local keymaps = {
		{ buf = list_buf, mode = "n", keys = { "<Down>", "<Right>" }, fn = function() move_selection(1) end },
		{ buf = list_buf, mode = "n", keys = { "<Up>", "<Left>" }, fn = function() move_selection(-1) end },
		{ buf = list_buf, mode = "n", keys = { "<LeftMouse>" }, fn = click_tab_action },
		{ buf = input.buf, mode = { "n", "i" }, keys = { "<LeftMouse>" }, fn = click_tab_action },
		{ buf = list_buf, mode = "n", keys = { "<CR>" }, fn = function() submit(input:get_value()) end },
		{ buf = list_buf, mode = "n", keys = { "<Tab>" }, fn = apply_tab_action },
		{ buf = list_buf, mode = "n", keys = { "<Esc>" }, fn = close_palette },
	}
	for _, km in ipairs(keymaps) do
		for _, key in ipairs(km.keys) do
			map(km.buf, km.mode, key, km.fn)
		end
	end
	vim.api.nvim_create_autocmd("VimResized", {
		group = lifecycle_group,
		callback = function() box:update(); rerender() end,
	})

	if picker_opts.initial_prompt and picker_opts.initial_prompt ~= "" then
		input:set_value(picker_opts.initial_prompt)
	end

	refresh()
	input:focus(picker_opts.initial_mode ~= "normal")
end

return M
