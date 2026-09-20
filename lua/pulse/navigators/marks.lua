local M = {}
local nav = require("pulse.navigators.util")
local view = require("pulse.panel_view")

M.name = "marks"
M.icon = "\239\128\174"
M.panels = {
	{ start = "'", name = "marks", label = "Marks", contexts = { "workspace" } },
}
M.view = true

-- Enter jumps to the exact spot (like `A), Tab previews it, and <C-x> clears the mark.
M.actions = nav.jump_actions()
M.actions[#M.actions + 1] = {
	key = "<C-x>",
	name = "delete",
	when = function(ctx)
		return ctx and ctx.item ~= nil
	end,
	run = function(ctx)
		local item = ctx.item
		if item.slot:match("^%u$") then
			vim.api.nvim_del_mark(item.slot)
		else
			vim.api.nvim_buf_del_mark(item.bufnr, item.slot)
		end
		ctx.refresh()
		return true
	end,
}

function M.init(ctx)
	return { bufnr = ctx and ctx.bufnr or vim.api.nvim_get_current_buf() }
end

local function line_text(bufnr, path, lnum)
	local line
	if vim.api.nvim_buf_is_loaded(bufnr) then
		line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
	else
		local ok, lines = pcall(vim.fn.readfile, path, "", lnum)
		line = ok and lines[lnum] or nil
	end
	return vim.trim(line or "")
end

local function mark_item(slot, bufnr, path, lnum, col)
	return {
		kind = "mark",
		slot = slot,
		bufnr = bufnr,
		filename = path,
		lnum = lnum,
		col = col,
		text = line_text(bufnr, path, lnum),
		label = slot,
	}
end

-- The marks you set yourself: global A-Z, plus a-z in the buffer the panel was opened from. Neovim's own
-- (', ", ., ^, [, ], <, > and 0-9) are left out on purpose.
function M.items(state, query)
	local out = {}
	for _, m in ipairs(vim.fn.getmarklist()) do
		local slot = m.mark:sub(2)
		if slot:match("^%u$") then
			out[#out + 1] = mark_item(slot, m.pos[1], vim.fn.fnamemodify(m.file, ":p"), m.pos[2], m.pos[3])
		end
	end
	local path = vim.api.nvim_buf_get_name(state.bufnr)
	if path ~= "" then
		for _, m in ipairs(vim.fn.getmarklist(state.bufnr)) do
			local slot = m.mark:sub(2)
			if slot:match("^%l$") then
				out[#out + 1] = mark_item(slot, state.bufnr, path, m.pos[2], m.pos[3])
			end
		end
	end
	table.sort(out, function(a, b)
		return a.slot < b.slot
	end)
	local q = vim.trim(query or "")
	if q == "" then
		return out
	end
	local match = require("pulse").make_matcher(q, { ignore_case = true, plain = true })
	return vim.tbl_filter(function(item)
		return match(item.slot .. " " .. item.filename .. " " .. item.text)
	end, out)
end

function M.view_item(item)
	return view.file_snippet(item.filename, item.lnum)
end

return M
