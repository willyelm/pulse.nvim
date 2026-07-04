local M = {}

function M.notify(message, level)
	vim.notify("Pulse: " .. message, level or vim.log.levels.WARN)
end

return M
