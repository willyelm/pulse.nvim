local M = {}

function M.title()
	return "Live Grep"
end

function M.seed()
	return { pending = false, last_query = "" }
end

function M.items(state, query, on_update)
	local q = vim.trim(query or "")
	if q == "" then
		return {}
	end

	if state.pending then
		return {}
	end

	state.pending = true
	state.last_query = q

	vim.system({ "rg", "--vimgrep", "--hidden", "-g", "!.git", q }, { text = true }, function(result)
		vim.schedule(function()
			state.pending = false
			if not on_update then
				return
			end
			if vim.trim(query or "") ~= state.last_query then
				return
			end

			local out = {}
			if result.code == 0 or (result.code ~= 0 and result.stdout and result.stdout ~= "") then
				local lines = vim.split(result.stdout or "", "\n", { trimempty = true })
				for _, line in ipairs(lines) do
					local path, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
					if path and lnum and col then
						out[#out + 1] = {
							kind = "live_grep",
							path = path,
							filename = path,
							lnum = tonumber(lnum),
							col = tonumber(col),
							text = text or "",
							query = q,
						}
					end
				end
			end

			state._cached_items = out
			pcall(on_update)
		end)
	end)

	return state._cached_items or {}
end

return M
