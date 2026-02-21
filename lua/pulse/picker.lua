local ui = require("pulse.ui")
local actions = require("pulse.actions")
local display = require("pulse.display")
local mode_parser = require("pulse.mode")
local preview_data = require("pulse.preview")

local modules = {
	files = require("pulse.pickers.files"),
	commands = require("pulse.pickers.commands"),
	symbol = require("pulse.pickers.symbols"),
	workspace_symbol = require("pulse.pickers.workspace_symbols"),
	live_grep = require("pulse.pickers.live_grep"),
	git_status = require("pulse.pickers.git_status"),
	diagnostics = require("pulse.pickers.diagnostics"),
}

local M = {}
local H_PADDING = 1
local MOVE_MAPS = {
	{ "j", 1 },
	{ "<ScrollWheelDown>", 1 },
	{ "k", -1 },
	{ "<ScrollWheelUp>", -1 },
}

local function is_header(item)
	return item and item.kind == "header"
end

local function first_non_header(items)
	for _, item in ipairs(items or {}) do
		if not is_header(item) then
			return item
		end
	end
	return nil
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

local function total_for_mode(mod, state, found)
	if mod and type(mod.total_count) == "function" then
		local ok, total = pcall(mod.total_count, state)
		if ok and type(total) == "number" then
			return math.max(total, found)
		end
	end
	return found
end

local function update_counter(input, found, total)
	input:set_addons({ right = { text = string.format("%d/%d", found, total), hl = "Comment" } })
end

local function compute_preview_height()
	return math.max(math.min(math.floor((vim.o.lines - vim.o.cmdheight) * 0.22), 12), 6)
end

local function new_layout(box)
	local layout = { sections = {}, state = { body = nil, preview = nil, width = nil } }

	local function upsert(name, opts)
		local current = layout.sections[name]
		if current and current.buf and vim.api.nvim_buf_is_valid(current.buf) then
			opts.buf = current.buf
		end
		layout.sections[name] = box:create_section(name, opts)
		return layout.sections[name]
	end

	local function draw_divider(buf, width)
		local line = string.rep("─", width)
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
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
		local inner_col = H_PADDING
		local inner_width = math.max(width - (H_PADDING * 2), 1)

		local specs = {
			{ name = "input", row = 0, col = inner_col, width = inner_width, height = 1, focusable = true, winhl = "Normal:NormalFloat" },
			{ name = "divider", row = 1, height = 1, focusable = false, winhl = "Normal:FloatBorder", divider = true },
			{ name = "list", row = 2, col = inner_col, width = inner_width, height = body_height, focusable = true, winhl = "Normal:NormalFloat,CursorLine:CursorLine" },
		}
		if show_preview then
			specs[#specs + 1] = {
				name = "body_divider",
				row = 2 + body_height,
				height = 1,
				focusable = false,
				winhl = "Normal:FloatBorder",
				divider = true,
			}
			specs[#specs + 1] = {
				name = "preview",
				row = 3 + body_height,
				col = inner_col,
				width = inner_width,
				height = preview_height,
				focusable = true,
				winhl = "Normal:NormalFloat",
			}
		else
			if self.sections.body_divider then
				box:close_section("body_divider")
				self.sections.body_divider = nil
			end
			if self.sections.preview then
				box:close_section("preview")
				self.sections.preview = nil
			end
		end

		for _, s in ipairs(specs) do
			local section = upsert(s.name, {
				row = s.row,
				col = s.col or 0,
				width = s.width or width,
				height = s.height,
				focusable = s.focusable,
				enter = false,
				winhl = s.winhl,
			})
			if s.divider then
				draw_divider(section.buf, width)
			end
		end

		if refs.list then refs.list.win = self.sections.list.win end
		if refs.input then refs.input:set_win(self.sections.input.win) end
		if refs.preview then
			if show_preview then
				refs.preview:set_target(self.sections.preview.buf, self.sections.preview.win)
			else
				refs.preview:set_target(nil, nil)
			end
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
	local closed, input, refresh = false, nil, nil

	local box = ui.box.new({
		width = picker_opts.width or 0.70,
		height = picker_opts.height or 0.50,
		row = (picker_opts.position == "top") and 1 or nil,
		col = 0.5,
		border = (picker_opts.border == true) and "single" or picker_opts.border,
		title = modules.files.title(),
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

	local function close_palette()
		if closed then
			return
		end
		closed = true
		for mode, state in pairs(states) do
			local mod = modules[mode]
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

	local function selected_preview_item()
		local selected = list:selected_item()
		if selected and not is_header(selected) then
			return selected
		end
		return first_non_header(items)
	end

	local function render_views(preview_item)
		list:render(vim.api.nvim_win_get_width(list.win))
		if preview_item and preview and preview.win and vim.api.nvim_win_is_valid(preview.win) then
			local lines, ft, highlights, line_numbers, focus_row = preview_data.for_item(preview_item)
			preview:set(lines, ft, highlights, line_numbers, focus_row)
		end
	end

	local function rerender()
		if closed then
			return
		end
		local preview_item = selected_preview_item()
		layout:apply(
			list.visible_count,
			preview_item and compute_preview_height() or 0,
			{ list = list, preview = preview, input = input }
		)
		render_views(preview_item)
	end

	local function ensure_state(mode)
		if states[mode] then
			return states[mode]
		end
		if mode == "files" then
			states[mode] = modules.files.seed(cwd)
		elseif mode == "commands" then
			states[mode] = modules.commands.seed()
		else
			states[mode] = modules[mode].seed({
				on_update = function()
					if not closed and refresh then
						vim.schedule(refresh)
					end
				end,
				bufnr = source_bufnr,
				cwd = cwd,
			})
		end
		return states[mode]
	end

	layout:apply(10, 8, {})
	list = ui.list.new({
		buf = layout.sections.list.buf,
		win = layout.sections.list.win,
		max_visible = 15,
		min_visible = 3,
		render_item = display.to_display,
	})
	preview = preview_data.new({ buf = layout.sections.preview.buf, win = layout.sections.preview.win })

	local function move_selection(delta)
		list:move(delta, is_header)
		rerender()
	end

	local function jump_in_source(item)
		local jumped = false
		local runner = function()
			jumped = actions.jump_to(item)
		end
		if vim.api.nvim_win_is_valid(source_win) then
			pcall(vim.api.nvim_win_call, source_win, runner)
		else
			pcall(runner)
		end
		return jumped
	end

	function refresh()
		local prompt = input:get_value()
		local mode_name, query = mode_parser.parse_prompt(prompt)
		local mod = modules[mode_name]
		local state = ensure_state(mode_name)
		local mode_switched = mode_name ~= active_mode
		active_mode = mode_name
		local next_items = mod.items(state, query)
		local found = count_non_headers(next_items)
		if #next_items > 0 and found == 0 then
			next_items = {}
		end

		items = next_items
		list:set_items(next_items)
		if mode_switched then
			list:set_selected(1)
		end
		update_counter(input, found, total_for_mode(mod, state, found))
		box:set_title(mod.title())

		if is_header(list:selected_item()) then
			list:move(1, is_header)
		end
		rerender()
	end

	local function submit(prompt)
		local mode_name, query = mode_parser.parse_prompt(prompt)
		local selected = list:selected_item()
		if mode_name == "commands" then
			close_palette()
			if query ~= "" then
				actions.execute_command(query)
			elseif selected and selected.kind == "command" then
				actions.execute_command(selected.command)
			end
			return
		end
		if selected and not is_header(selected) and jump_in_source(selected) then
			close_palette()
		end
	end

	input = ui.input.new({
		buf = layout.sections.input.buf,
		win = layout.sections.input.win,
		prompt = "",
		on_change = refresh,
		on_submit = submit,
		on_escape = close_palette,
		on_down = function()
			move_selection(1)
		end,
		on_up = function()
			move_selection(-1)
		end,
		on_tab = function()
			local item = list:selected_item()
			if actions.is_jumpable(item) then
				jump_in_source(item)
			end
		end,
	})

	local list_map_opts = { buffer = layout.sections.list.buf, noremap = true, silent = true }
	for _, map in ipairs(MOVE_MAPS) do
		vim.keymap.set("n", map[1], function()
			move_selection(map[2])
		end, list_map_opts)
	end
	vim.keymap.set("n", "<CR>", function()
		submit(input:get_value())
	end, list_map_opts)
	vim.keymap.set("n", "<Esc>", close_palette, list_map_opts)

	vim.api.nvim_create_autocmd("VimResized", {
		group = lifecycle_group,
		callback = function()
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
