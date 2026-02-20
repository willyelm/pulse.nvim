local display = require("pulse.ui.display")
local preview = require("pulse.ui.preview")
local window = require("pulse.ui.window")

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

local debounce_timer = nil
local function debounce(fn, delay)
	delay = delay or 100
	if debounce_timer then
		debounce_timer:close()
		debounce_timer = nil
	end
	debounce_timer = vim.uv.new_timer()
	debounce_timer:start(delay, 0, vim.schedule_wrap(function()
		if debounce_timer then
			debounce_timer:close()
			debounce_timer = nil
		end
		fn()
	end))
end

local MODE_PREFIX = {
	[":"] = { mode = "commands", strip = 2 },
	["#"] = { mode = "workspace_symbol", strip = 2 },
	["@"] = { mode = "symbol", strip = 2 },
	["$"] = { mode = "live_grep", strip = 2 },
	["~"] = { mode = "git_status", strip = 2 },
	["!"] = { mode = "diagnostics", strip = 2 },
}

local KIND_ICON = {
	Command = "",
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
	ERROR = "",
	WARN = "",
	INFO = "",
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
		return "", "Comment"
	end
	local name, ext = vim.fn.fnamemodify(path, ":t"), vim.fn.fnamemodify(path, ":e")
	local icon, hl = devicons.get_icon(name, ext, { default = true })
	return icon or "", hl or "Comment"
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

local function build_items(ensure_state, prompt, on_update)
	local mode, query = parse_prompt(prompt)
	return modules[mode].items(ensure_state(mode), query, on_update), mode
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

local function make_entry_maker()
	local displayer = display.create({ separator = " " })

	local function right_pad(text)
		return ((text and text ~= "") and text or "") .. " "
	end

	return function(item)
		if item.kind == "header" then
			return {
				value = item,
				ordinal = item.label,
				kind = "header",
				display = function(width)
					return displayer({ { item.label, "Comment" }, { "", "Comment" } }, width)
				end,
			}
		end

		if item.kind == "file" then
			local icon, icon_hl = devicon_for(item.path)
			local rel = vim.fn.fnamemodify(item.path, ":.")
			return {
				value = item,
				ordinal = rel,
				kind = "file",
				path = item.path,
				display = function(width)
					return displayer({
						{ icon .. " " .. rel, icon_hl },
						{ right_pad(filetype_for(item.path)), "Comment" },
					}, width)
				end,
			}
		end

		if item.kind == "command" then
			return {
				value = item,
				ordinal = ":" .. item.command,
				kind = "command",
				display = function(width)
					return displayer({
						{ KIND_ICON.Command .. " :" .. item.command, "Normal" },
						{ right_pad(item.source), "Comment" },
					}, width)
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
				display = function(width)
					return displayer({
						{ "󰱼 " .. rel .. " " .. (item.text or ""), "Normal" },
						{ right_pad(pos), "Comment" },
					}, width)
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
				display = function(width)
					return displayer({
						{ "󰊢 " .. rel, "Normal" },
						{ right_pad(item.code or ""), "Comment" },
					}, width)
				end,
			}
		end

		if item.kind == "diagnostic" then
			local rel = vim.fn.fnamemodify(item.filename or "", ":.")
			local pos = string.format("%d:%d", item.lnum or 1, item.col or 1)
			local icon = DIAG_ICON[item.severity_name or "INFO"] or ""
			local msg = (item.message or ""):gsub("\n.*$", "")
			return {
				value = item,
				ordinal = string.format("%s %s %s", rel, item.severity_name or "", msg),
				kind = "diagnostic",
				filename = item.filename,
				lnum = item.lnum,
				col = item.col,
				display = function(width)
					return displayer({
						{ icon .. " " .. rel .. " " .. msg, "Normal" },
						{ right_pad((item.severity_name or "INFO") .. " " .. pos), "Comment" },
					}, width)
				end,
			}
		end

		local kind = item.symbol_kind_name or "Symbol"
		local icon = KIND_ICON[kind] or KIND_ICON.Symbol
		local depth = math.max(item.depth or 0, 0)
		local indent = string.rep(" ", depth * 2)
		local filename = item.filename or ""
		local rel = filename ~= "" and vim.fn.fnamemodify(filename, ":.") or ""
		local right = (item.kind == "workspace_symbol" and item.container and item.container ~= "")
			and (kind .. "  " .. item.container)
			or kind

		return {
			value = item,
			ordinal = ((item.kind == "workspace_symbol") and "#" or "@")
				.. " "
				.. string.format("%s %s %s", item.symbol or "", rel, item.container or ""),
			filename = filename,
			lnum = item.lnum,
			col = item.col,
			kind = item.kind,
			display = function(width)
				return displayer({
					{ indent .. icon .. " " .. (item.symbol or ""), symbol_hl(kind) },
					{ right_pad(right), "Comment" },
				}, width)
			end,
		}
	end
end

function M.open(opts)
	opts = opts or {}

	local ui_opts = {
		width = opts.width or 0.70,
		height = opts.height or 0.50,
		border = opts.border or "rounded",
		initial_prompt = opts.initial_prompt or "",
		title = modules.files.title(),
	}

	local source_win = vim.api.nvim_get_current_win()
	local source_bufnr = vim.api.nvim_get_current_buf()
	local states = {}
	local controller -- assigned after window.open(); callbacks capture it by reference

	local entry_maker = make_entry_maker()

	local function make_entries(items)
		local result = {}
		for _, item in ipairs(items) do
			result[#result + 1] = entry_maker(item)
		end
		return result
	end

	-- Forward declaration: ensure_state is referenced by refresh_no_prompt_reset
	-- and defined immediately after.
	local ensure_state

	local function refresh_no_prompt_reset()
		if not controller then
			return
		end
		local prompt = controller.get_prompt()
		local on_update = function()
			if not controller then return end
			local p = controller.get_prompt()
			local items, mode = build_items(ensure_state, p)
			controller.update(make_entries(items), modules[mode].title())
		end
		local items, mode = build_items(ensure_state, prompt, on_update)
		controller.update(make_entries(items), modules[mode].title())
	end

	ensure_state = function(mode)
		if states[mode] then
			return states[mode]
		end
		if mode == "files" then
			states[mode] = modules.files.seed(vim.fn.getcwd())
		elseif mode == "commands" then
			states[mode] = modules.commands.seed()
		else
			states[mode] = modules[mode].seed({
				on_update = refresh_no_prompt_reset,
				bufnr = source_bufnr,
			})
		end
		return states[mode]
	end

	local callbacks = {
		on_prompt_change = function(prompt)
			if not controller then
				return
			end
			debounce(function()
				if not controller then return end
				local on_update = function()
					if not controller then return end
					local p = controller.get_prompt()
					local items, mode = build_items(ensure_state, p)
					controller.update(make_entries(items), modules[mode].title())
				end
				local items, mode = build_items(ensure_state, prompt, on_update)
				controller.update(make_entries(items), modules[mode].title())
			end, 200)
		end,

		on_select = function(entry, prompt)
			local mode, query = parse_prompt(prompt)

			if mode == "commands" then
				if query ~= "" then
					execute_command(query)
					return
				end
				if entry and entry.kind == "command" then
					execute_command(entry.value.command)
				end
				return
			end

			if not entry or entry.kind == "header" then
				return
			end
			jump_to(entry)
		end,

		on_preview = function(entry, prompt, _results_win)
			-- Tab: peek at symbol/file/grep result in the source window
			local k = entry.kind
			if k == "symbol" or k == "workspace_symbol" or k == "file" or k == "live_grep" then
				if source_win and vim.api.nvim_win_is_valid(source_win) then
					vim.api.nvim_win_call(source_win, function()
						jump_to(entry)
					end)
				end
			end
		end,

		on_cursor_move = function(entry, prompt, ctrl)
			if not entry or entry.kind == "header" then
				ctrl.hide_preview()
				return
			end
			local item = entry.value or entry
			local _, query = parse_prompt(prompt)
			local content = preview.content_for(item, query)
			if content then
				ctrl.show_preview(content)
			else
				ctrl.hide_preview()
			end
		end,

		on_close = function()
			if source_win and vim.api.nvim_win_is_valid(source_win) then
				vim.api.nvim_set_current_win(source_win)
			end
		end,
	}

	controller = window.open(ui_opts, callbacks)
end

return M
