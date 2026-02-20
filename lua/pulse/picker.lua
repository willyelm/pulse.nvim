local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local sorters = require("telescope.sorters")

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
	["#"] = { mode = "workspace_symbol", strip = 2 },
	["@"] = { mode = "symbol", strip = 2 },
	["$"] = { mode = "live_grep", strip = 2 },
	["~"] = { mode = "git_status", strip = 2 },
	["!"] = { mode = "diagnostics", strip = 2 },
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

local KIND_HL = {
	File = "Directory",
	Module = "Include",
	Namespace = "Include",
	Package = "Include",
	Class = "Type",
	Method = "Function",
	Property = "Identifier",
	Field = "Identifier",
	Constructor = "Function",
	Enum = "Type",
	Interface = "Type",
	Function = "Function",
	Variable = "Identifier",
	Constant = "Constant",
	String = "String",
	Number = "Number",
	Boolean = "Boolean",
	Array = "Type",
	Object = "Type",
	Key = "Identifier",
	Null = "Constant",
	EnumMember = "Constant",
	Struct = "Type",
	Event = "PreProc",
	Operator = "Operator",
	TypeParameter = "Type",
	Symbol = "Identifier",
}
local DIAG_ICON = {
	ERROR = "",
	WARN = "",
	INFO = "",
	HINT = "󰌵",
}

local preview_ns = vim.api.nvim_create_namespace("pulse_preview")
local preview_state = { win = nil, buf = nil }

local function filetype_for(path)
	local ft = vim.filetype.match({ filename = path })
	ft = (ft and ft ~= "") and ft or vim.fn.fnamemodify(path, ":e")
	return (ft and ft ~= "") and ft or "file"
end

local function devicon_for(path)
	local ok, devicons = pcall(require, "nvim-web-devicons")
	if not ok then
		return "", "TelescopeResultsComment"
	end
	local name, ext = vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e")
	local icon, hl = devicons.get_icon(name, ext, { default = true })
	return icon or "", hl or "TelescopeResultsComment"
end

local function symbol_hl(kind)
	local pulse = "Pulse" .. tostring(kind or "Symbol")
	return (vim.fn.hlexists(pulse) == 1) and pulse or (KIND_HL[kind] or "Identifier")
end

local function parse_prompt(prompt)
	prompt = prompt or ""
	local cfg = MODE_PREFIX[prompt:sub(1, 1)]
	if cfg then
		return cfg.mode, prompt:sub(cfg.strip)
	end
	return "files", prompt
end

local function build_items(ensure_state, prompt)
	local mode, query = parse_prompt(prompt)
	return modules[mode].items(ensure_state(mode), query), mode
end

local function jump_to(selection)
	if selection.kind == "file" then
		vim.cmd.edit(vim.fn.fnameescape(selection.path))
		return
	end
	if selection.kind == "command" then
		local keys = vim.api.nvim_replace_termcodes(":" .. selection.value.command, true, false, true)
		vim.api.nvim_feedkeys(keys, "n", false)
		return
	end
	if selection.filename and selection.filename ~= "" then
		vim.cmd.edit(vim.fn.fnameescape(selection.filename))
	end
	if selection.lnum then
		vim.api.nvim_win_set_cursor(0, { selection.lnum, math.max((selection.col or 1) - 1, 0) })
	end
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

local function close_external_preview()
	if preview_state.win and vim.api.nvim_win_is_valid(preview_state.win) then
		pcall(vim.api.nvim_win_close, preview_state.win, true)
	end
	preview_state.win = nil
	preview_state.buf = nil
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

local function ensure_external_preview(prompt_bufnr)
	local p = action_state.get_current_picker(prompt_bufnr)
	if not p or not p.results_win or not vim.api.nvim_win_is_valid(p.results_win) then
		return nil
	end
	local results_cfg = vim.api.nvim_win_get_config(p.results_win)
	if not results_cfg or results_cfg.relative == "" then
		return nil
	end

	local row = math.floor(tonumber(results_cfg.row) or 0) + (tonumber(results_cfg.height) or 0) + 1
	local col = math.floor(tonumber(results_cfg.col) or 0)
	local width = math.max((tonumber(results_cfg.width) or 50), 20)
	local height = math.max(math.min(math.floor(vim.o.lines * 0.22), 14), 8)

	if preview_state.win and vim.api.nvim_win_is_valid(preview_state.win) then
		vim.api.nvim_win_set_config(preview_state.win, {
			relative = "editor",
			row = row,
			col = col,
			width = width,
			height = height,
		})
		return preview_state.buf
	end

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "single",
		noautocmd = true,
	})
	vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder", { win = win })
	preview_state.win = win
	preview_state.buf = buf
	return buf
end

local function write_preview(buf, lines, ft)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_clear_namespace(buf, preview_ns, 0, -1)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = ft or "text"
	if preview_state.win and vim.api.nvim_win_is_valid(preview_state.win) then
		pcall(vim.api.nvim_win_set_cursor, preview_state.win, { 1, 0 })
	end
end

local function refresh_external_preview(prompt_bufnr)
	local line = action_state.get_current_line() or ""
	local mode = parse_prompt(line)
	if mode ~= "live_grep" and mode ~= "git_status" then
		close_external_preview()
		return
	end

	local sel = action_state.get_selected_entry()
	if not sel or sel.kind == "header" then
		close_external_preview()
		return
	end

	local item = sel.value or sel
	local buf = ensure_external_preview(prompt_bufnr)
	if not buf then
		return
	end

	if item.kind == "git_status" then
		local path = item.path or item.filename
		local diff = vim.fn.systemlist({ "git", "--no-pager", "diff", "--", path })
		if vim.v.shell_error ~= 0 or #diff == 0 then
			diff = { "No git diff for " .. tostring(path) }
		end
		write_preview(buf, diff, "diff")
		return
	end

	local path = resolve_path(item.path or item.filename)
	if not path then
		write_preview(buf, { "File not found: " .. tostring(item.path or item.filename) }, "text")
		return
	end

	local lines = vim.fn.readfile(path)
	local lnum = math.max(item.lnum or 1, 1)
	local start_l = lnum
	local end_l = math.min(#lines, lnum + 9)
	local out = {}
	for i = start_l, end_l do
		local marker = (i == lnum) and ">" or " "
		out[#out + 1] = string.format("%s %5d  %s", marker, i, lines[i] or "")
	end
	write_preview(buf, out, filetype_for(path))

	local q = item.query or ""
	if q ~= "" then
		local text = lines[lnum] or ""
		local from = text:lower():find(q:lower(), 1, true)
		if from then
			local line_idx = lnum - start_l
			local prefix_len = 9
			vim.api.nvim_buf_add_highlight(buf, preview_ns, "Search", line_idx, prefix_len + from - 1, prefix_len + from - 1 + #q)
		end
	end
end

local function make_entry_maker()
	local displayer = entry_display.create({
		separator = " ",
		items = {
			{
				width = function(_, cols, _)
					return math.max(1, cols - 22 - 1)
				end,
			},
			{ width = 22, right_justify = true },
		},
	})

	local function right_pad(text)
		return ((text and text ~= "") and text or "") .. " "
	end

	return function(item)
		if item.kind == "header" then
			return {
				value = item,
				ordinal = item.label,
				kind = "header",
				display = function()
					return displayer({ { item.label, "Comment" }, { "", "Comment" } })
				end,
			}
		end

		if item.kind == "file" then
			local icon = devicon_for(item.path)
			local rel = vim.fn.fnamemodify(item.path, ":.")
			return {
				value = item,
				ordinal = rel,
				kind = "file",
				path = item.path,
				display = function()
					return displayer({
						{ icon .. " " .. rel, "Normal" },
						{ right_pad(filetype_for(item.path)), "Comment" },
					})
				end,
			}
		end

		if item.kind == "command" then
			return {
				value = item,
				ordinal = ":" .. item.command,
				kind = "command",
				display = function()
					return displayer({
						{ KIND_ICON.Command .. " :" .. item.command, "Normal" },
						{ right_pad(item.source), "Comment" },
					})
				end,
			}
		end

		if item.kind == "live_grep" then
			local rel = vim.fn.fnamemodify(item.path, ":.")
			local pos = string.format("%d:%d", item.lnum or 1, item.col or 1)
			return {
				value = item,
				ordinal = string.format("%s %s %s", rel, pos, item.text or ""),
				kind = "live_grep",
				filename = item.path,
				lnum = item.lnum,
				col = item.col,
				display = function()
					return displayer({
						{ "󰱼 " .. rel .. " " .. (item.text or ""), "Normal" },
						{ right_pad(pos), "Comment" },
					})
				end,
			}
		end

		if item.kind == "git_status" then
			local rel = vim.fn.fnamemodify(item.path, ":.")
			return {
				value = item,
				ordinal = string.format("%s %s", item.code or "", rel),
				kind = "git_status",
				filename = item.path,
				display = function()
					return displayer({
						{ "󰊢 " .. rel, "Normal" },
						{ right_pad(item.code or ""), "Comment" },
					})
				end,
			}
		end

		if item.kind == "diagnostic" then
			local rel = vim.fn.fnamemodify(item.filename or "", ":.")
			local pos = string.format("%d:%d", item.lnum or 1, item.col or 1)
			local icon = DIAG_ICON[item.severity_name or "INFO"] or ""
			local msg = (item.message or ""):gsub("\n.*$", "")
			return {
				value = item,
				ordinal = string.format("%s %s %s", rel, item.severity_name or "", msg),
				kind = "diagnostic",
				filename = item.filename,
				lnum = item.lnum,
				col = item.col,
				display = function()
					return displayer({
						{ icon .. " " .. rel .. " " .. msg, "Normal" },
						{ right_pad((item.severity_name or "INFO") .. " " .. pos), "Comment" },
					})
				end,
			}
		end

		local kind = item.symbol_kind_name or "Symbol"
		local icon = KIND_ICON[kind] or KIND_ICON.Symbol
		local depth = math.max(item.depth or 0, 0)
		local indent = string.rep(" ", depth * 2)
		local filename = item.filename or ""
		local rel = filename ~= "" and vim.fn.fnamemodify(filename, ":.") or ""
		local right = (item.kind == "workspace_symbol" and item.container and item.container ~= "") and (kind .. "  " .. item.container)
			or kind

		return {
			value = item,
			ordinal = ((item.kind == "workspace_symbol") and "#" or "@") .. " " .. string.format("%s %s %s", item.symbol or "", rel, item.container or ""),
			filename = filename,
			lnum = item.lnum,
			col = item.col,
			kind = item.kind,
			display = function()
				return displayer({
					{ indent .. icon .. " " .. (item.symbol or ""), "Normal" },
					{ right_pad(right), "Comment" },
				})
			end,
		}
	end
end

local function set_results_winhl(prompt_bufnr)
	vim.schedule(function()
		local p = action_state.get_current_picker(prompt_bufnr)
		if p and p.results_win and vim.api.nvim_win_is_valid(p.results_win) then
			vim.api.nvim_set_option_value("winhl", "Normal:Normal,CursorLine:CursorLine", { win = p.results_win })
		end
	end)
end

local function ensure_first_selectable(prompt_bufnr)
	vim.schedule(function()
		local sel = action_state.get_selected_entry()
		if sel and sel.kind == "header" then
			actions.move_selection_next(prompt_bufnr)
			local sel2 = action_state.get_selected_entry()
			local guard = 0
			while sel2 and sel2.kind == "header" and guard < 200 do
				actions.move_selection_next(prompt_bufnr)
				sel2 = action_state.get_selected_entry()
				guard = guard + 1
			end
		end
	end)
end

local function skip_headers(prompt_bufnr, move)
	local i = 0
	repeat
		move(prompt_bufnr)
		i = i + 1
		local s = action_state.get_selected_entry()
		if not s or s.kind ~= "header" then
			return
		end
	until i > 200
end

function M.open(opts)
	local picker_opts = vim.tbl_deep_extend("force", {
		layout_config = { width = 0.70, height = 0.70, prompt_position = "top", anchor = "N" },
		border = true,
	}, opts or {})

	local ok, themes = pcall(require, "telescope.themes")
	if ok and type(themes.get_dropdown) == "function" then
		picker_opts = themes.get_dropdown(picker_opts)
	end

	picker_opts.layout_config = vim.tbl_deep_extend("force", picker_opts.layout_config or {}, {
		anchor = "N",
		prompt_position = "top",
	})

	local source_bufnr = vim.api.nvim_get_current_buf()
	local picker
	local function refresh_no_prompt_reset()
		if picker then
			pcall(picker.refresh, picker, picker.finder, { reset_prompt = false })
		end
	end

	local states = {}

	local function ensure_state(mode)
		if states[mode] then
			return states[mode]
		end

		if mode == "files" then
			states[mode] = modules.files.seed(vim.fn.getcwd())
		elseif mode == "commands" then
			states[mode] = modules.commands.seed()
		else
			states[mode] = modules[mode].seed({ on_update = refresh_no_prompt_reset, bufnr = source_bufnr })
		end

		return states[mode]
	end

	picker = pickers.new(picker_opts, {
		prompt_title = modules.files.title(),
		results_title = false,
		finder = finders.new_dynamic({
			fn = function(prompt)
				local items, mode = build_items(ensure_state, prompt)
				local title = modules[mode].title()
				if picker and picker.prompt_title ~= title then
					picker.prompt_title = title
					if picker.prompt_border and picker.prompt_border.change_title then
						pcall(picker.prompt_border.change_title, picker.prompt_border, title)
					end
				end
				return items
			end,
			entry_maker = make_entry_maker(),
		}),
		sorter = sorters.empty(),
		previewer = false,
		initial_mode = picker_opts.initial_mode,
		prompt_prefix = picker_opts.prompt_prefix,
		selection_caret = picker_opts.selection_caret,
		entry_prefix = picker_opts.entry_prefix,
		layout_strategy = picker_opts.layout_strategy,
		layout_config = picker_opts.layout_config,
		sorting_strategy = picker_opts.sorting_strategy,
		border = picker_opts.border,
		attach_mappings = function(prompt_bufnr, map)
			set_results_winhl(prompt_bufnr)
			ensure_first_selectable(prompt_bufnr)

			local function move_next()
				skip_headers(prompt_bufnr, actions.move_selection_next)
				vim.schedule(function()
					refresh_external_preview(prompt_bufnr)
				end)
			end
			local function move_prev()
				skip_headers(prompt_bufnr, actions.move_selection_previous)
				vim.schedule(function()
					refresh_external_preview(prompt_bufnr)
				end)
			end

			local function preview_selection()
				local s = action_state.get_selected_entry()
				if not s then
					return
				end
				if s.kind == "header" then
					move_next()
					return
				end
				if s.kind == "symbol" or s.kind == "workspace_symbol" or s.kind == "file" or s.kind == "live_grep" then
					local p = action_state.get_current_picker(prompt_bufnr)
					local target_win = p and p.original_win_id or nil
					if target_win and vim.api.nvim_win_is_valid(target_win) then
						vim.api.nvim_win_call(target_win, function()
							jump_to(s)
						end)
					end
				end
			end

			local next_keys = { { "i", "<Down>" }, { "i", "<C-n>" }, { "n", "j" }, { "n", "<Down>" } }
			local prev_keys = { { "i", "<Up>" }, { "i", "<C-p>" }, { "n", "k" }, { "n", "<Up>" } }
			for _, k in ipairs(next_keys) do
				map(k[1], k[2], move_next)
			end
			for _, k in ipairs(prev_keys) do
				map(k[1], k[2], move_prev)
			end
			map("i", "<Tab>", preview_selection)
			map("n", "<Tab>", preview_selection)

			vim.api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI", "CursorMoved" }, {
				buffer = prompt_bufnr,
				callback = function()
					vim.schedule(function()
						refresh_external_preview(prompt_bufnr)
					end)
				end,
			})
			vim.api.nvim_create_autocmd("BufWipeout", {
				buffer = prompt_bufnr,
				once = true,
				callback = close_external_preview,
			})

			actions.select_default:replace(function()
				local line = action_state.get_current_line() or ""
				local mode, query = parse_prompt(line)
				local s = action_state.get_selected_entry()

				if mode == "commands" then
					close_external_preview()
					actions.close(prompt_bufnr)
					if query ~= "" then
						execute_command(query)
						return
					end
					if s and s.kind == "command" then
						execute_command(s.value.command)
					end
					return
				end

				if not s or s.kind == "header" then
					return
				end
				close_external_preview()
				actions.close(prompt_bufnr)
				jump_to(s)
			end)

			return true
		end,
	})

	if picker_opts.initial_prompt and picker_opts.initial_prompt ~= "" then
		picker:find({ default_text = picker_opts.initial_prompt })
		vim.schedule(function()
			pcall(function()
				picker:set_prompt(picker_opts.initial_prompt)
			end)
		end)
	else
		picker:find()
	end
end

return M
