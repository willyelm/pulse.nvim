local M = {}

local ITEM_KIND = {
	Command = { icon = "" },
	File = { icon = "󰈔" },
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

local function basename(path)
	return vim.fn.fnamemodify(path or "", ":t")
end

local function file_right(path)
	local ft = vim.filetype.match({ filename = path or "" })
	if ft and ft ~= "" then
		return ft
	end
	local ext = vim.fn.fnamemodify(path or "", ":e")
	return (ext ~= "" and ext) or "file"
end

local function icon_matches(icon, hl, start_col)
	return hl and { { start_col or 0, (start_col or 0) + #icon, hl } } or nil
end

local function kind_icon_hl(kind)
	local spec = ITEM_KIND[kind] or ITEM_KIND.Symbol
	local suffix = spec.lsp
	local lsp = suffix and ("@lsp.type." .. suffix) or nil
	if lsp and vim.fn.hlexists(lsp) == 1 then
		return lsp
	end
	return spec.hl or "Identifier"
end

local function icon_for_item(item_type, name)
	if item_type == "file" then
		if not ok_devicons then
			return FILE_ICON_FALLBACK, nil
		end
		local p = name or ""
		local icon, color = devicons.get_icon_color(basename(p), vim.fn.fnamemodify(p, ":e"), { default = true })
		return icon or FILE_ICON_FALLBACK, (type(color) == "string" and color ~= "") and { fg = color } or nil
	end
	if item_type == "kind" then
		local kind = name or "Symbol"
		local spec = ITEM_KIND[kind] or ITEM_KIND.Symbol
		return spec.icon, kind_icon_hl(kind)
	end
	if item_type == "diagnostic" then
		local sev = string.upper(name or "INFO")
		local key = "Diagnostic" .. ((sev == "ERROR" and "Error") or (sev == "WARN" and "Warn") or (sev == "HINT" and "Hint") or "Info")
		local spec = ITEM_KIND[key] or ITEM_KIND.DiagnosticInfo
		return spec.icon, spec.hl
	end
	return ITEM_KIND.Symbol.icon, ITEM_KIND.Symbol.hl
end

function M.to_display(item)
	if item.kind == "header" then
		return row(item.label or "", "", "Title")
	end
	if item.kind == "file" then
		local icon, icon_style = icon_for_item("file", item.path)
		local name, right = basename(item.path), file_right(item.path)
		local left, left_matches = string.format("%s %s", icon, name), icon_matches(icon, icon_style) or {}
		if vim.fn.hlexists(right) == 1 then
			left_matches[#left_matches + 1] = { #icon + 1, #left, right }
		end
		return row(left, right, false, (#left_matches > 0) and left_matches or nil)
	end
	if item.kind == "command" then
		return row(string.format("%s :%s", ITEM_KIND.Command.icon, item.command))
	end
	if item.kind == "live_grep" then
		local line = vim.trim(item.text or "")
		if line == "" then
			line = basename(item.path)
		end
		local pos = string.format("%d:%d", item.lnum or 1, item.col or 1)
		local out = row(line, string.format("%s:%s", basename(item.path), pos))
		local q = vim.trim(item.query or "")
		if q ~= "" then
			local idx = line:lower():find(q:lower(), 1, true)
			if idx then
				out.left_matches = { { idx - 1, idx - 1 + #q } }
			end
		end
		return out
	end
	if item.kind == "fuzzy_search" then
		local line = vim.trim(item.text or "")
		if line == "" then
			line = basename(item.filename)
		end
		local out = row(line, string.format("%d:%d", item.lnum or 1, item.col or 1))
		if type(item.match_cols) == "table" and #item.match_cols > 0 then
			out.left_matches = {}
			for _, col in ipairs(item.match_cols) do
				if type(col) == "number" and col > 0 then
					out.left_matches[#out.left_matches + 1] = { col - 1, col }
				end
			end
		end
		return out
	end
	if item.kind == "git_status" then
		local icon, icon_style = icon_for_item("file", item.path)
		return row(
			string.format("%s %s", icon, basename(item.path)),
			item.display_right or "",
			false,
			icon_matches(icon, icon_style)
		)
	end
	if item.kind == "diagnostic" then
		local icon, icon_hl = icon_for_item("diagnostic", item.severity_name)
		local pos = string.format("%s:%d:%d", basename(item.filename), item.lnum or 1, item.col or 1)
		local left = string.format("%s %s", icon, (item.message or ""):gsub("\n.*$", ""))
		return row(left, pos, false, icon_matches(icon, icon_hl))
	end

	local kind = item.symbol_kind_name or "Symbol"
	local icon, icon_hl = icon_for_item("kind", kind)
	local indent = string.rep("  ", math.max(item.depth or 0, 0))
	return row(
		string.format("%s%s %s", indent, icon, item.symbol or ""),
		kind,
		false,
		icon_matches(icon, icon_hl, #indent)
	)
end

return M
