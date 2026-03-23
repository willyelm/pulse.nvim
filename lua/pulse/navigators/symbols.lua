local M = {}
local scope = require("pulse.scope")
local CACHE = {}

M.name = "symbol"
M.icon = "󰘧"
M.actions = {
	{
		key = "<CR>",
		name = "jump",
		when = function(ctx)
			return ctx and ctx.item ~= nil
		end,
		run = function(ctx)
			if ctx and ctx.item then
				ctx.jump(ctx.item)
				ctx.close()
				return false
			end
		end,
	},
	{
		key = "<Tab>",
		name = "preview",
		when = function(ctx)
			return ctx and ctx.item ~= nil
		end,
		run = function(ctx)
			if ctx and ctx.item then
				ctx.preview(ctx.item)
			end
		end,
	},
}
M.panels = {
	{ start = "@", name = "symbol", label = "Symbols", scopes = { "buffer" } },
}

M.context = false

local SymbolKind = vim.lsp.protocol.SymbolKind or {}
local NODE_KINDS = {
	["function"] = true,
	method = true,
	class = true,
	interface = true,
	enum = true,
	struct = true,
	type = true,
	declaration = true,
}

local function kind_name(kind)
	return (type(kind) == "number" and SymbolKind[kind])
		or ((type(kind) == "string" and kind ~= "") and kind)
		or "Symbol"
end

local function sort_by_line(items)
	table.sort(items, function(a, b)
		if (a.lnum or 0) == (b.lnum or 0) then
			return (a.col or 0) < (b.col or 0)
		end
		return (a.lnum or 0) < (b.lnum or 0)
	end)
end

local function make_symbol(name, kind, depth, line, col, filename)
	return {
		kind = "symbol",
		symbol = tostring(name or ""):gsub("\n.*$", ""),
		symbol_kind = kind or 0,
		symbol_kind_name = kind_name(kind or 0),
		depth = depth or 0,
		lnum = (line or 0) + 1,
		col = (col or 0) + 1,
		filename = filename or "",
	}
end

local function is_symbol_node(node_type)
	for kind in pairs(NODE_KINDS) do
		if node_type:find(kind) then
			return true
		end
	end
	return false
end

local function flatten_document_symbols(result, bufnr)
	local out, filename = {}, vim.api.nvim_buf_get_name(bufnr)
	local function walk(nodes, depth)
		for _, s in ipairs(nodes or {}) do
			local r = s.selectionRange or s.range
			if r and r.start and s.name and s.name ~= "" then
				out[#out + 1] = make_symbol(s.name, s.kind, depth, r.start.line, r.start.character, filename)
				walk(s.children, depth + 1)
			else
				walk(s.children, depth)
			end
		end
	end

	walk(result, 0)
	sort_by_line(out)
	return out
end

local function flatten_symbol_information(result)
	local out = {}
	for _, s in ipairs(result or {}) do
		local loc = s.location
		local start = loc and loc.range and loc.range.start
		if start and s.name and s.name ~= "" then
			out[#out + 1] =
				make_symbol(s.name, s.kind, 0, start.line, start.character, loc.uri and vim.uri_to_fname(loc.uri) or "")
		end
	end
	sort_by_line(out)
	return out
end

local function lsp_symbols(bufnr, result)
	if type(result) ~= "table" or #result == 0 then
		return {}
	end
	if result[1] and result[1].location then
		return flatten_symbol_information(result)
	end
	return flatten_document_symbols(result, bufnr)
end

local function sync_lsp_symbols(bufnr, timeout_ms)
	local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
	local responses = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, timeout_ms or 40) or {}
	local merged = {}
	for _, resp in pairs(responses) do
		local mapped = lsp_symbols(bufnr, resp and resp.result)
		for _, item in ipairs(mapped) do
			merged[#merged + 1] = item
		end
	end
	if #merged > 0 then
		sort_by_line(merged)
	end
	return merged
end

local function treesitter_fallback(bufnr)
	local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
	if not ok or not parser then
		return {}
	end
	local ok2, trees = pcall(function()
		return parser:parse()
	end)
	if not ok2 or not (trees and trees[1]) then
		return {}
	end
	local root = trees[1]:root()
	if not root then
		return {}
	end

	local out, filename = {}, vim.api.nvim_buf_get_name(bufnr)

	local function walk(node)
		local t = node:type() or ""
		if is_symbol_node(t) then
			local sr, sc = node:range()
			local text = vim.treesitter.get_node_text(node, bufnr)
			if type(text) == "table" then
				text = table.concat(text, "")
			end
			local name = vim.trim(tostring(text or ""):gsub("\n.*$", ""))
			if name ~= "" then
				out[#out + 1] = make_symbol(name, 0, 0, sr, sc, filename)
			end
		end

		for child in node:iter_children() do
			walk(child)
		end
	end

	walk(root)
	sort_by_line(out)
	return out
end

local function has_document_symbol_client(bufnr)
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
		if client:supports_method("textDocument/documentSymbol") then
			return true
		end
	end
	return false
end

local function cached_symbols(bufnr)
	if not scope.valid_bufnr(bufnr) then
		return nil
	end
	local tick = vim.api.nvim_buf_get_changedtick(bufnr)
	local cached = CACHE[bufnr]
	if cached and cached.tick == tick then
		return cached.symbols
	end
	return nil
end

local function store_symbols(bufnr, symbols)
	if not scope.valid_bufnr(bufnr) then
		return symbols
	end
	CACHE[bufnr] = {
		tick = vim.api.nvim_buf_get_changedtick(bufnr),
		symbols = symbols,
	}
	return symbols
end

function M.init(ctx)
	local bufnr = scope.resolve_bufnr(ctx)
	if not bufnr then
		return { symbols = {}, input_scope = nil }
	end
	pcall(vim.fn.bufload, bufnr)
	local use_lsp = has_document_symbol_client(bufnr)
	local cached = cached_symbols(bufnr)
	local symbols = cached or {}
	if not cached then
		if use_lsp then
			symbols = sync_lsp_symbols(bufnr, 40)
		end
		if #symbols == 0 and not use_lsp then
			symbols = treesitter_fallback(bufnr)
		end
		store_symbols(bufnr, symbols)
	end
	local state = {
		symbols = symbols,
		input_scope = scope.input_scope(ctx, bufnr),
	}
	if not use_lsp then
		return state
	end

	local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
	vim.lsp.buf_request(bufnr, "textDocument/documentSymbol", params, function(_, result)
		local mapped = lsp_symbols(bufnr, result)
		if #mapped == 0 then
			return
		end
		state.symbols = store_symbols(bufnr, mapped)
		if ctx and type(ctx.on_update) == "function" then
			vim.schedule(ctx.on_update)
		end
	end)

	return state
end

function M.input_scope(state)
	return state and state.input_scope or nil
end

function M.items(state, query)
	local pulse = require("pulse")
	local symbols = state.symbols or {}
	query = query or ""
	if query == "" then
		return symbols
	end

	local match = pulse.make_matcher(query, { ignore_case = true, plain = true })
	local out = {}
	for _, s in ipairs(symbols) do
		local hay = table.concat({ s.symbol or "", s.symbol_kind_name or "", s.filename or "" }, " ")
		if match(hay) then
			out[#out + 1] = s
		end
	end
	return out
end

function M.total_count(state)
	return #(state.symbols or {})
end

return M
