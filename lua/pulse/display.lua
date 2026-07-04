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

local function file_name(path)
	return vim.fn.fnamemodify(path or "", ":t")
end

local function file_type(path)
	local ft = vim.filetype.match({ filename = path or "" })
	if ft and ft ~= "" then
		return ft
	end
	ft = vim.fn.fnamemodify(path or "", ":e")
	return ft ~= "" and ft or "file"
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
	if item.folder then
		local indent = string.rep("  ", tonumber(item.depth) or 0)
		local suffix = item.scope_parent and "" or "/"
		if item.no_icon then
			local out = row(indent .. (item.label or file_name(item.path)) .. suffix, item.display_right or "", false)
			out.right_group = "LineNr"
			out.right_matches = item.right_matches
			return out
		end
		local icon = item.expanded and "󰷏" or "󰉋"
		local out = row(string.format("%s%s %s%s", indent, icon, item.label or file_name(item.path), suffix), item.display_right or "", false, { { #indent, #indent + #icon, item.icon_color and "Directory" or nil } })
		out.right_group = "LineNr"
		out.right_matches = item.right_matches
		return out
	end
	if item.path then
		local icon, style = icon_for_item("file", item.path)
		local left = string.format("%s %s", icon, item.label or "")
		local matches = (style and { { 0, #icon, style } } or nil) or {}
		return row(left, "", false, (#matches > 0) and matches or nil)
	end
	if item.panel_highlights then
		return row(item.label or "", "", false, item.panel_highlights)
	end
	return row(item.label or "", "", "Comment")
end

local function display_command(item)
	return row(string.format("%s :%s", ITEM_KIND.Command.icon, item.command), "", false)
end

local function display_code_action(item)
	local icon, hl = icon_for_item("kind", "Function")
	local ak = (item.action and item.action.kind) or ""
	ak = ak ~= "" and (ak:match("^([^.]+)") or ak) or ""
	return row(string.format("%s %s", icon, item.title or ""), ak, false, (hl and { { 0, #icon, hl } } or nil))
end

local function display_file(item)
	local name = item.label or file_name(item.path)
	local right = item.display_right or file_type(item.path)
	local indent = string.rep("  ", tonumber(item.depth) or 0)
	local icon = nil
	local left, matches
	if item.no_icon then
		left = indent .. name
		matches = {}
	else
		local style
		icon, style = icon_for_item("file", item.path)
		left = string.format("%s%s %s", indent, icon, name)
		matches = (item.icon_color and style and { { #indent, #indent + #icon, style } } or nil) or {}
	end
	local left_group = item.ignored and "Comment" or false
	local right_group = item.ignored and "Comment" or "LineNr"
	if item.ignored then
		if item.no_icon then
			matches = {}
		else
			matches = { { #indent, #indent + #(icon or ""), "Comment" } }
		end
	end
	local name_start = item.no_icon and #indent or (#indent + #(icon or "") + 1)
	if item.display_right == nil and not item.ignored and vim.fn.hlexists(right) == 1 and name ~= "" then
		matches[#matches + 1] = { name_start, #left, right }
	end
	local out = row(left, right, left_group, (#matches > 0) and matches or nil)
	out.right_group = right_group
	out.right_matches = item.right_matches
	return out
end

local function display_folder(item)
	local indent = string.rep("  ", tonumber(item.depth) or 0)
	local group = item.ignored and "Comment" or false
	local suffix = item.scope_parent and "" or "/"
	if item.no_icon then
		local out = row(indent .. (item.label or file_name(item.path)) .. suffix, item.display_right or "", group)
		out.right_group = item.ignored and "Comment" or "LineNr"
		out.right_matches = item.right_matches
		return out
	end
	local icon = item.expanded and "󰷏" or "󰉋"
	local icon_hl = item.ignored and "Comment" or nil
	local out = row(string.format("%s%s %s%s", indent, icon, item.label or file_name(item.path), suffix), item.display_right or "", group, icon_hl and { { #indent, #indent + #icon, icon_hl } } or nil)
	out.right_group = item.ignored and "Comment" or "LineNr"
	out.right_matches = item.right_matches
	return out
end

local function display_grep(item)
	local line = vim.trim(item.text or "")
	if line == "" then
		line = file_name(item.path or item.filename)
	end
	local pos = string.format("%d:%d", item.lnum or 1, item.col or 1)
	local right = item.kind == "fuzzy_search" and pos or string.format("%s:%s", file_name(item.path or item.filename), pos)
	local out = row(line, right)
	out.left_group = false
	out.right_group = false

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
	local display = format_icon_item(icon, item.label or item.path or file_name(item.path), item.display_right or "", style)

	-- Add highlighting for additions and deletions in right column
	local right_str = item.display_right or ""
	if right_str ~= "" then
		display.right_matches = {}
		-- Highlight additions (+N)
		local p1, p2 = right_str:find("%+%d+")
		if p1 then
			display.right_matches[#display.right_matches + 1] = { p1 - 1, p2, "Added" }
		end
		-- Highlight deletions (-N)
		p1, p2 = right_str:find("%-%d+")
		if p1 then
			display.right_matches[#display.right_matches + 1] = { p1 - 1, p2, "Removed" }
		end
		-- Trailing raw_code: index column (staged, green) vs worktree column (unstaged, red)
		local raw = item.raw_code
		if raw and #raw == 2 and right_str:sub(-2) == raw then
			local start = #right_str - 2
			if raw == "??" then
				display.right_matches[#display.right_matches + 1] = { start, start + 2, "Added" }
			else
				if raw:sub(1, 1) ~= " " then
					display.right_matches[#display.right_matches + 1] = { start, start + 1, "Added" }
				end
				if raw:sub(2, 2) ~= " " then
					display.right_matches[#display.right_matches + 1] = { start + 1, start + 2, "Removed" }
				end
			end
		end
	end

	return display
end

local function display_git_commit(item)
	local icon = "󰜘"
	local text = item.subject or item.label or (item.commit or "")
	local right = item.display_right or item.date or ""
	return row(string.format("%s %s", icon, text), right, false)
end

local function display_git_commit_file(item)
	local out = display_file(vim.tbl_extend("force", {
		kind = "file",
		no_icon = false,
		icon_color = false,
		ignored = false,
		is_open = false,
	}, item))
	if item.display_right ~= "" then
		out.right_matches = out.right_matches or {}
		local p1, p2 = item.display_right:find("%+%d+")
		if p1 then
			out.right_matches[#out.right_matches + 1] = { p1 - 1, p2, "Added" }
		end
		p1, p2 = item.display_right:find("%-%d+")
		if p1 then
			out.right_matches[#out.right_matches + 1] = { p1 - 1, p2, "Removed" }
		end
	end
	return out
end

local function display_diagnostic(item)
	local icon, hl = icon_for_item("diagnostic", item.severity_name)
	local pos = string.format("%s:%d:%d", file_name(item.filename), item.lnum or 1, item.col or 1)
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

local function display_loading(item)
	return row(item.label or "Loading...", "", "Comment")
end

local RENDERERS = {
	header = display_header,
	command = display_command,
	code_action = display_code_action,
	file = display_file,
	folder = display_folder,
	live_grep = display_grep,
	fuzzy_search = display_grep,
	git_status = display_git_status,
	git_commit = display_git_commit,
	git_commit_file = display_git_commit_file,
	diagnostic = display_diagnostic,
	symbol = display_symbol,
	workspace_symbol = display_symbol,
	loading = display_loading,
}

function M.to_display(item)
	local renderer = RENDERERS[item.kind] or display_symbol
	return renderer(item)
end

return M
