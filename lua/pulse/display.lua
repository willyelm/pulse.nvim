local M = {}

local ITEM_KIND = {
	Command = { icon = "" },
	Module = { icon = "󰆧" },
	Namespace = { icon = "󰌗" },
	Package = { icon = "󰏗" },
	Class = { icon = "󰠱", lsp = "class", hl = "Type" },
	Method = { icon = "󰆧", lsp = "method", hl = "Function" },
	Property = { icon = "󰆼", lsp = "property", hl = "Identifier" },
	Field = { icon = "󰆼", lsp = "property", hl = "Identifier" },
	Constructor = { icon = "󰆧", lsp = "function", hl = "Function" },
	Enum = { icon = "󰕘", lsp = "type", hl = "Type" },
	Interface = { icon = "󰕘", lsp = "type", hl = "Type" },
	Function = { icon = "󰊕", lsp = "function", hl = "Function" },
	Variable = { icon = "󰀫", lsp = "variable", hl = "Identifier" },
	Constant = { icon = "󰏿", lsp = "variable", hl = "Identifier" },
	String = { icon = "󰀬", hl = "String" },
	Number = { icon = "󰎠", hl = "Number" },
	Boolean = { icon = "󰨙", hl = "Boolean" },
	Array = { icon = "󰅪", hl = "Type" },
	Object = { icon = "󰅩", hl = "Type" },
	Key = { icon = "󰌋", hl = "Identifier" },
	Null = { icon = "󰟢", hl = "Identifier" },
	EnumMember = { icon = "󰕘", hl = "Type" },
	Struct = { icon = "󰙅", lsp = "type", hl = "Type" },
	Event = { icon = "󱐋", hl = "Identifier" },
	Operator = { icon = "󰆕", hl = "Operator" },
	TypeParameter = { icon = "󰬛", lsp = "type", hl = "Type" },
	Symbol = { icon = "󰘧", hl = "Identifier" },
	DiagnosticError = { icon = "", hl = "DiagnosticError" },
	DiagnosticWarn = { icon = "", hl = "DiagnosticWarn" },
	DiagnosticHint = { icon = "󰌵", hl = "DiagnosticHint" },
	DiagnosticInfo = { icon = "", hl = "DiagnosticInfo" },
}

local ok_devicons, devicons = pcall(require, "nvim-web-devicons")
local FILE_ICON_FALLBACK = ""

local function row(left, right, left_group, left_matches)
	return {
		left = left or "",
		left_group = left_group,
		right = right or "",
		right_group = "LineNr",
		left_matches = left_matches,
	}
end
local function format_icon_item(icon, text, right_text, hl)
	return row(string.format("%s %s", icon, text), right_text, false, (hl and { { 0, #icon, hl } } or nil))
end
local function kind_icon_hl(kind)
	local spec = ITEM_KIND[kind] or ITEM_KIND.Symbol
	local lsp = spec.lsp and ("@lsp.type." .. spec.lsp) or nil
	return (lsp and vim.fn.hlexists(lsp) == 1) and lsp or (spec.hl or "Identifier")
end

local function icon_for_item(item_type, name)
	if item_type == "file" then
		if not ok_devicons then
			return FILE_ICON_FALLBACK, nil
		end
		local p = name or ""
		local icon, color = devicons.get_icon_color(vim.fn.fnamemodify(p, ":t"), vim.fn.fnamemodify(p, ":e"), { default = true })
		return icon or FILE_ICON_FALLBACK, (type(color) == "string" and color ~= "") and { fg = color } or nil
	end
	if item_type == "kind" then
		local kind = name or "Symbol"
		return (ITEM_KIND[kind] or ITEM_KIND.Symbol).icon, kind_icon_hl(kind)
	end
	if item_type == "diagnostic" then
		local sev = string.upper(name or "INFO")
		local spec = ITEM_KIND["Diagnostic" .. ((sev == "ERROR" and "Error") or (sev == "WARN" and "Warn") or (sev == "HINT" and "Hint") or "Info")]
			or ITEM_KIND.DiagnosticInfo
		return spec.icon, spec.hl
	end
	return ITEM_KIND.Symbol.icon, ITEM_KIND.Symbol.hl
end

local function display_header(item)
	if item.path then
		local icon, style = icon_for_item("file", item.path)
		local left = string.format("%s %s", icon, item.label or "")
		local matches = (style and { { 0, #icon, style } } or nil) or {}
		return row(left, "", false, (#matches > 0) and matches or nil)
	end
	return row(item.label or "", "", "Label")
end

local function display_command(item)
	return row(string.format("%s :%s", ITEM_KIND.Command.icon, item.command))
end

local function display_code_action(item)
	local icon, hl = icon_for_item("kind", "Function")
	local ak = (item.action and item.action.kind) or ""
	ak = ak ~= "" and (ak:match("^([^.]+)") or ak) or ""
	return row(string.format("%s %s", icon, item.title or ""), ak, false, (hl and { { 0, #icon, hl } } or nil))
end

local function display_file(item)
	local icon, style = icon_for_item("file", item.path)
	local name = vim.fn.fnamemodify(item.path, ":t")
	local ft = vim.filetype.match({ filename = item.path or "" })
	local right = (ft and ft ~= "") and ft or (vim.fn.fnamemodify(item.path or "", ":e") ~= "" and vim.fn.fnamemodify(item.path or "", ":e") or "file")
	local left, matches = string.format("%s %s", icon, name), (style and { { 0, #icon, style } } or nil) or {}
	if vim.fn.hlexists(right) == 1 then
		matches[#matches + 1] = { #icon + 1, #left, right }
	end
	return row(left, right, false, (#matches > 0) and matches or nil)
end

local function display_grep(item)
	local line = vim.trim(item.text or "")
	if line == "" then
		line = vim.fn.fnamemodify(item.path or item.filename, ":t")
	end
	local pos = string.format("%d:%d", item.lnum or 1, item.col or 1)
	local out = row(line, string.format("%s:%s", vim.fn.fnamemodify(item.path or item.filename, ":t"), pos))

	local q = vim.trim(item.query or "")
	if q ~= "" then
		local idx = line:lower():find(q:lower(), 1, true)
		if idx then
			out.left_matches = { { idx - 1, idx - 1 + #q } }
		end
	end

	if type(item.match_cols) == "table" and #item.match_cols > 0 then
		out.left_matches = out.left_matches or {}
		for _, col in ipairs(item.match_cols) do
			if type(col) == "number" and col > 0 then
				out.left_matches[#out.left_matches + 1] = { col - 1, col }
			end
		end
	end
	return out
end

local function display_git_status(item)
	local icon, style = icon_for_item("file", item.path)
	local display = format_icon_item(icon, vim.fn.fnamemodify(item.path, ":t"), item.display_right or "", style)

	-- Add highlighting for additions and deletions in right column
	local right_str = item.display_right or ""
	if right_str ~= "" then
		display.right_matches = {}
		-- Highlight additions (+N)
		local p1, p2 = right_str:find("%+%d+")
		if p1 then
			display.right_matches[#display.right_matches + 1] = { p1 - 1, p2, "PulseAdd" }
		end
		-- Highlight deletions (-N)
		p1, p2 = right_str:find("%-%d+")
		if p1 then
			display.right_matches[#display.right_matches + 1] = { p1 - 1, p2, "PulseDelete" }
		end
	end

	return display
end

local function display_diagnostic(item)
	local icon, hl = icon_for_item("diagnostic", item.severity_name)
	local pos = string.format("%s:%d:%d", vim.fn.fnamemodify(item.filename, ":t"), item.lnum or 1, item.col or 1)
	return format_icon_item(icon, (item.message or ""):gsub("\n.*$", ""), pos, hl)
end

local function display_symbol(item)
	local kind = item.symbol_kind_name or "Symbol"
	local icon, hl = icon_for_item("kind", kind)
	local d = tonumber(item and item.depth) or 0
	if d == 0 then
		local container = item and item.container or ""
		if container ~= "" then
			d = #vim.split(container:gsub("::", "."), ".", { plain = true, trimempty = true })
		end
	end
	local indent = string.rep("  ", d)
	return row(string.format("%s%s %s", indent, icon, item.symbol or ""), kind, false, (hl and { { #indent, #indent + #icon, hl } } or nil))
end

local RENDERERS = {
	header = display_header,
	command = display_command,
	code_action = display_code_action,
	file = display_file,
	live_grep = display_grep,
	fuzzy_search = display_grep,
	git_status = display_git_status,
	diagnostic = display_diagnostic,
	symbol = display_symbol,
	workspace_symbol = display_symbol,
}

function M.to_display(item)
	local renderer = RENDERERS[item.kind] or display_symbol
	return renderer(item)
end

return M
