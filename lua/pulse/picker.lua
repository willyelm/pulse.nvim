local ui = require("pulse.ui")

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

local MODE_PREFIX = {
	[":"] = { mode = "commands", strip = 2 },
	["~"] = { mode = "git_status", strip = 2 },
	["!"] = { mode = "diagnostics", strip = 2 },
	["@"] = { mode = "symbol", strip = 2 },
	["#"] = { mode = "workspace_symbol", strip = 2 },
	["$"] = { mode = "live_grep", strip = 2 },
}

local KIND_ICON = {
	Command = "",
	File = "󰈔",
	Module = "󰆧",
	Namespace = "󰌗",
	Package = "󰏗",
	Class = "󰠱",
	Method = "󰆧",
	Property = "󰆼",
	Field = "󰆼",
	Constructor = "󰆧",
	Enum = "󰕘",
	Interface = "󰕘",
	Function = "󰊕",
	Variable = "󰀫",
	Constant = "󰏿",
	String = "󰀬",
	Number = "󰎠",
	Boolean = "󰨙",
	Array = "󰅪",
	Object = "󰅩",
	Key = "󰌋",
	Null = "󰟢",
	EnumMember = "󰕘",
	Struct = "󰙅",
	Event = "󱐋",
	Operator = "󰆕",
	TypeParameter = "󰬛",
	Symbol = "󰘧",
}

local DIAG_ICON = {
	ERROR = "",
	WARN = "",
	INFO = "",
	HINT = "󰌵",
}

local function filetype_for(path)
	local ft = vim.filetype.match({ filename = path })
	ft = (ft and ft ~= "") and ft or vim.fn.fnamemodify(path, ":e")
	return (ft and ft ~= "") and ft or "file"
end

local function devicon_for(path)
	local ok, devicons = pcall(require, "nvim-web-devicons")
	if not ok then
		return ""
	end
	local name, ext = vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e")
	local icon = devicons.get_icon(name, ext, { default = true })
	return icon or ""
end

local function parse_prompt(prompt)
	prompt = prompt or ""
	local cfg = MODE_PREFIX[prompt:sub(1, 1)]
	if cfg then
		return cfg.mode, prompt:sub(cfg.strip)
	end
	return "files", prompt
end

local function jump_to(selection)
	local function edit_target(path)
		local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
		if not ok then
			vim.notify(tostring(err), vim.log.levels.WARN)
			return false
		end
		return true
	end

	if selection.kind == "file" then
		return edit_target(selection.path)
	end
	if selection.kind == "command" then
		local keys = vim.api.nvim_replace_termcodes(":" .. selection.command, true, false, true)
		vim.api.nvim_feedkeys(keys, "n", false)
		return true
	end
	if selection.filename and selection.filename ~= "" then
		if not edit_target(selection.filename) then
			return false
		end
	end
	if selection.lnum then
		vim.api.nvim_win_set_cursor(0, { selection.lnum, math.max((selection.col or 1) - 1, 0) })
	end
	return true
end

local function execute_command(cmd)
	local ex = vim.trim(cmd or "")
	if ex == "" then
		return
	end
	local ok, err = pcall(vim.cmd, ex)
	if not ok then
		vim.notify(tostring(err), vim.log.levels.ERROR)
	end
end

local function resolve_path(path)
	if not path or path == "" then
		return nil
	end
	if vim.fn.filereadable(path) == 1 then
		return path
	end
	local abs = vim.fn.fnamemodify(path, ":p")
	if vim.fn.filereadable(abs) == 1 then
		return abs
	end
	return nil
end

local function to_display(item)
	if item.kind == "header" then
		return item.label, "Comment"
	end

	if item.kind == "file" then
		local rel = vim.fn.fnamemodify(item.path, ":.")
		return string.format("%s %s", devicon_for(item.path), rel), "Normal"
	end

	if item.kind == "command" then
		return string.format("%s :%s", KIND_ICON.Command, item.command), "Normal"
	end

	if item.kind == "live_grep" then
		local rel = vim.fn.fnamemodify(item.path, ":.")
		local pos = string.format("%d:%d", item.lnum or 1, item.col or 1)
		return string.format("󰱼 %s %s  %s", rel, pos, item.text or ""), "Normal"
	end

	if item.kind == "git_status" then
		local rel = vim.fn.fnamemodify(item.path, ":.")
		return string.format("󰊢 %s  [%s]", rel, item.code or ""), "Normal"
	end

	if item.kind == "diagnostic" then
		local rel = vim.fn.fnamemodify(item.filename or "", ":.")
		local pos = string.format("%d:%d", item.lnum or 1, item.col or 1)
		local icon = DIAG_ICON[item.severity_name or "INFO"] or ""
		local msg = (item.message or ""):gsub("\n.*$", "")
		return string.format("%s %s %s  [%s %s]", icon, rel, msg, item.severity_name or "INFO", pos), "Normal"
	end

	local kind = item.symbol_kind_name or "Symbol"
	local icon = KIND_ICON[kind] or KIND_ICON.Symbol
	local depth = math.max(item.depth or 0, 0)
	local indent = string.rep("  ", depth)
	local container = item.container and item.container ~= "" and ("  [" .. item.container .. "]") or ""
	return string.format("%s%s %s%s", indent, icon, item.symbol or "", container), "Normal"
end

local function preview_file_snippet(path, lnum, query)
	local resolved = resolve_path(path)
	if not resolved then
		return { "File not found: " .. tostring(path) }, "text", {}, nil, 1
	end

	local lines = vim.fn.readfile(resolved)
	local line_no = math.max(lnum or 1, 1)
	local start_l = math.max(line_no - 1, 1)
	local end_l = math.min(#lines, line_no + 9)
	local out = {}
	local highlights = {}
	local line_numbers = {}

	for i = start_l, end_l do
		out[#out + 1] = lines[i] or ""
		line_numbers[#line_numbers + 1] = i
	end

	if query and query ~= "" then
		local text = lines[line_no] or ""
		local from = text:lower():find(query:lower(), 1, true)
		if from then
			highlights[#highlights + 1] = {
				group = "Search",
				row = line_no - start_l,
				start_col = from - 1,
				end_col = from - 1 + #query,
			}
		end
	end

	return out, filetype_for(resolved), highlights, line_numbers, (line_no - start_l + 1)
end

local function preview_for_item(item)
	if not item then
		return { "No selection" }, "text", {}, nil, 1
	end

	if item.kind == "header" then
		return { item.label or "" }, "text", {}, nil, 1
	end

	if item.kind == "git_status" then
		local path = item.path or item.filename
		local diff = vim.fn.systemlist({ "git", "--no-pager", "diff", "--", path })
		if vim.v.shell_error ~= 0 or #diff == 0 then
			diff = { "No git diff for " .. tostring(path) }
		end
		return diff, "diff", {}, nil, 1
	end

	if item.kind == "live_grep" then
		return preview_file_snippet(item.path or item.filename, item.lnum, item.query)
	end

	if item.kind == "diagnostic" then
		local out = {
			string.format("[%s] %s", item.severity_name or "INFO", item.source or "diagnostic"),
			string.format("%s:%d:%d", item.filename or "", item.lnum or 1, item.col or 1),
			"",
			item.message or "",
			"",
		}
		local snippet, ft = preview_file_snippet(item.filename, item.lnum)
		vim.list_extend(out, snippet)
		return out, ft, {}, nil, 1
	end

	if item.kind == "file" or item.kind == "symbol" or item.kind == "workspace_symbol" then
		return preview_file_snippet(item.path or item.filename, item.lnum)
	end

	if item.kind == "command" then
		return {
			"Command",
			"",
			":" .. tostring(item.command),
			"",
			"Press <CR> to execute selected command.",
			"Typing after ':' and pressing <CR> executes typed command.",
		},
			"text",
			{},
			nil,
			1
	end

	return { vim.inspect(item) }, "lua", {}, nil, 1
end

local function normalise_border(border)
	if border == true or border == nil then
		return "rounded"
	end
	if border == false then
		return "none"
	end
	return border
end

local function list_has_only_headers(items)
	if #items == 0 then
		return false
	end
	for _, item in ipairs(items) do
		if item.kind ~= "header" then
			return false
		end
	end
	return true
end

local function is_header(item)
	return item and item.kind == "header"
end

local function is_jumpable(item)
	return item
		and (item.kind == "symbol" or item.kind == "workspace_symbol" or item.kind == "file" or item.kind == "live_grep")
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

	local palette = {
		current_mode = "files",
		items = {},
		closed = false,
	}

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

	box:mount()
	local lifecycle_group = vim.api.nvim_create_augroup("PulseUIPalette" .. tostring(box.buf), { clear = true })

	local list
	local preview
	local sections = {}
	local layout_state = { body = nil, preview = nil, width = nil }

	local function set_divider(buf, width)
		local line = string.rep("─", width)
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
		vim.bo[buf].modifiable = false
	end

	local function upsert_section(name, opts)
		if sections[name] and sections[name].buf and vim.api.nvim_buf_is_valid(sections[name].buf) then
			opts.buf = sections[name].buf
		end
		sections[name] = box:create_section(name, opts)
		return sections[name]
	end

	local function relayout(body_height, preview_height)
		if palette.closed then
			return
		end

		local current_width = vim.api.nvim_win_get_width(box.win)
		if
			sections.input
			and layout_state.body == body_height
			and layout_state.preview == preview_height
			and layout_state.width == current_width
		then
			return
		end

		box:update({ height = body_height + preview_height + 3 })
		local width = vim.api.nvim_win_get_width(box.win)
		local function place(name, row, height, focusable, winhl)
			upsert_section(name, {
				row = row,
				col = 0,
				width = width,
				height = height,
				focusable = focusable,
				enter = false,
				winhl = winhl,
			})
		end

		place("input", 0, 1, true, "Normal:NormalFloat")

		place("divider", 1, 1, false, "Normal:FloatBorder")
		set_divider(sections.divider.buf, width)

		place("list", 2, body_height, true, "Normal:NormalFloat,CursorLine:CursorLine")

		place("body_divider", 2 + body_height, 1, false, "Normal:FloatBorder")
		set_divider(sections.body_divider.buf, width)

		place("preview", 3 + body_height, preview_height, true, "Normal:NormalFloat")

		if list then
			list.win = sections.list.win
		end
		if preview then
			preview.win = sections.preview.win
		end
		if palette.input then
			palette.input.win = sections.input.win
		end

		layout_state.body = body_height
		layout_state.preview = preview_height
		layout_state.width = width
	end

	local function close_palette()
		if palette.closed then
			return
		end
		palette.closed = true
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
		if palette.closed then
			return
		end
		vim.schedule(function()
			if palette.closed then
				return
			end
			palette.refresh()
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
		buf = sections.list.buf,
		win = sections.list.win,
		max_visible = 15,
		min_visible = 3,
		render_item = to_display,
	})

	preview = ui.preview.new({
		buf = sections.preview.buf,
		win = sections.preview.win,
	})

	local function selected_or_first_selectable()
		local selected = list:selected_item()
		if selected and not is_header(selected) then
			return selected
		end

		for _, item in ipairs(palette.items) do
			if not is_header(item) then
				return item
			end
		end

		return nil
	end

	local function refresh_preview()
		local item = selected_or_first_selectable()
		local lines, ft, highlights, line_numbers, focus_row = preview_for_item(item)
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
			jumped = jump_to(item)
		end
		if vim.api.nvim_win_is_valid(source_win) then
			pcall(vim.api.nvim_win_call, source_win, runner)
		else
			pcall(runner)
		end
		return jumped
	end

	function palette.refresh()
		local prompt = palette.input:get_value()
		local mode, query = parse_prompt(prompt)
		palette.current_mode = mode
		local title = modules[mode].title()
		box:set_title(title)

		local items = modules[mode].items(ensure_state(mode), query)
		if list_has_only_headers(items) then
			items = {}
		end

		palette.items = items
		list:set_items(items)

		local selected = list:selected_item()
		if is_header(selected) then
			list:move(1, is_header)
		end

			sync_layout_and_render()
		end

	local function preview_selection_in_source()
		local item = list:selected_item()
		if not is_jumpable(item) then
			return
		end
		jump_in_source(item)
	end

	local function move_next()
		move_selection(1)
	end

	local function move_prev()
		move_selection(-1)
	end

	local function submit(prompt)
		local mode, query = parse_prompt(prompt)
		local selected = list:selected_item()

		if mode == "commands" then
			close_palette()
			if query ~= "" then
				execute_command(query)
				return
			end
			if selected and selected.kind == "command" then
				execute_command(selected.command)
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

	palette.input = ui.input.new({
		buf = sections.input.buf,
		win = sections.input.win,
		prompt = picker_opts.prompt_prefix or "",
		on_change = palette.refresh,
		on_submit = submit,
		on_escape = close_palette,
		on_down = move_next,
		on_up = move_prev,
		on_tab = preview_selection_in_source,
	})

	local list_map_opts = { buffer = sections.list.buf, noremap = true, silent = true }
	vim.keymap.set("n", "j", move_next, list_map_opts)
	vim.keymap.set("n", "k", move_prev, list_map_opts)
	vim.keymap.set("n", "<ScrollWheelDown>", move_next, list_map_opts)
	vim.keymap.set("n", "<ScrollWheelUp>", move_prev, list_map_opts)
	vim.keymap.set("n", "<CR>", function()
		submit(palette.input:get_value())
	end, list_map_opts)
	vim.keymap.set("n", "<Esc>", close_palette, list_map_opts)

	vim.api.nvim_create_autocmd("VimResized", {
		group = lifecycle_group,
		callback = function()
			if palette.closed then
				return
			end
				sync_layout_and_render()
			end,
		})

	if picker_opts.initial_prompt and picker_opts.initial_prompt ~= "" then
		palette.input:set_value(picker_opts.initial_prompt)
	end

	palette.refresh()
	palette.input:focus(picker_opts.initial_mode ~= "normal")
end

return M
