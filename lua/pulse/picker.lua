local ui = require("pulse.ui")
local actions = require("pulse.actions")
local display = require("pulse.display")
local mode_parser = require("pulse.mode")
local preview_data = require("pulse.preview")
local picker_layout = require("pulse.picker_layout")

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

local function normalise_border(border)
	if border == true or border == nil then
		return "rounded"
	end
	if border == false then
		return "none"
	end
	return border
end

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

local function list_has_only_headers(items)
	return #items > 0 and first_non_header(items) == nil
end

local function compute_preview_height()
	return math.max(math.min(math.floor((vim.o.lines - vim.o.cmdheight) * 0.22), 12), 6)
end

function M.open(opts)
	local picker_opts = vim.tbl_deep_extend("force", {
		initial_mode = "insert",
		prompt_prefix = "",
		layout_config = {
			width = 0.70,
			height = 0.70,
			prompt_position = "top",
			anchor = "N",
		},
		border = true,
	}, opts or {})

	local source_bufnr = vim.api.nvim_get_current_buf()
	local source_win = vim.api.nvim_get_current_win()
	local cwd = vim.fn.getcwd()
	local states = {}
	local items = {}
	local closed = false
	local input
	local refresh

	local box = ui.box.new({
		width = picker_opts.layout_config.width or 0.70,
		height = picker_opts.layout_config.height or 0.50,
		row = (picker_opts.layout_config.anchor == "N") and 0.12 or nil,
		col = 0.5,
		border = normalise_border(picker_opts.border),
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

	local list
	local preview
	local layout = picker_layout.new(box)

	local function relayout(body_height, preview_height)
		if closed then
			return
		end
		layout:apply(body_height, preview_height, {
			list = list,
			preview = preview,
			input = input,
		})
	end

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

	local function refresh_no_prompt_reset()
		if closed then
			return
		end
		vim.schedule(function()
			if closed then
				return
			end
			if refresh then
				refresh()
			end
		end)
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
				on_update = refresh_no_prompt_reset,
				bufnr = source_bufnr,
				cwd = cwd,
			})
		end

		return states[mode]
	end

	relayout(10, 8)

	list = ui.list.new({
		buf = layout.sections.list.buf,
		win = layout.sections.list.win,
		max_visible = 15,
		min_visible = 3,
		render_item = display.to_display,
	})

	preview = preview_data.new({
		buf = layout.sections.preview.buf,
		win = layout.sections.preview.win,
	})

	local function selected_or_first_selectable()
		local selected = list:selected_item()
		if selected and not is_header(selected) then
			return selected
		end
		return first_non_header(items)
	end

	local function refresh_preview()
		local item = selected_or_first_selectable()
		local lines, ft, highlights, line_numbers, focus_row = preview_data.for_item(item)
		preview:set(lines, ft, highlights, line_numbers, focus_row)
	end

	local function render_views()
		list:render(vim.api.nvim_win_get_width(list.win))
		refresh_preview()
	end

	local function sync_layout_and_render()
		relayout(list.visible_count, compute_preview_height())
		render_views()
	end

	local function move_selection(delta)
		list:move(delta, is_header)
		render_views()
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
		local title = modules[mode_name].title()
		box:set_title(title)

		local next_items = modules[mode_name].items(ensure_state(mode_name), query)
		if list_has_only_headers(next_items) then
			next_items = {}
		end

		items = next_items
		list:set_items(next_items)

		local selected = list:selected_item()
		if is_header(selected) then
			list:move(1, is_header)
		end

		sync_layout_and_render()
	end

	local function preview_selection_in_source()
		local item = list:selected_item()
		if not actions.is_jumpable(item) then
			return
		end
		jump_in_source(item)
	end

	local function submit(prompt)
		local mode_name, query = mode_parser.parse_prompt(prompt)
		local selected = list:selected_item()

		if mode_name == "commands" then
			close_palette()
			if query ~= "" then
				actions.execute_command(query)
				return
			end
			if selected and selected.kind == "command" then
				actions.execute_command(selected.command)
			end
			return
		end

		if not selected or selected.kind == "header" then
			return
		end

		if jump_in_source(selected) then
			close_palette()
		end
	end

	input = ui.input.new({
		buf = layout.sections.input.buf,
		win = layout.sections.input.win,
		prompt = picker_opts.prompt_prefix or "",
		on_change = refresh,
		on_submit = submit,
		on_escape = close_palette,
		on_down = function()
			move_selection(1)
		end,
		on_up = function()
			move_selection(-1)
		end,
		on_tab = preview_selection_in_source,
	})

	local list_map_opts = { buffer = layout.sections.list.buf, noremap = true, silent = true }
	for _, map in ipairs({
		{ "j", 1 },
		{ "<ScrollWheelDown>", 1 },
		{ "k", -1 },
		{ "<ScrollWheelUp>", -1 },
	}) do
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
			if closed then
				return
			end
			sync_layout_and_render()
		end,
	})

	if picker_opts.initial_prompt and picker_opts.initial_prompt ~= "" then
		input:set_value(picker_opts.initial_prompt)
	end

	refresh()
	input:focus(picker_opts.initial_mode ~= "normal")
end

return M
