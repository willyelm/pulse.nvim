-- The one place git gets invoked: every call runs against the repo root, so the root-relative paths git
-- reports (status, numstat, log) and expects (pathspecs, `rev:path`) stay valid wherever nvim's cwd is.
local M = {}
local uv = vim.uv or vim.loop

local REPOS = {}

-- Repo layout for nvim's cwd ({ root, git_dir }), or nil outside a repo. Cached per cwd once found; once
-- warmed from the main thread it is also safe to call from fast (libuv) callbacks, which can't run the
-- lookup themselves.
local function repo()
	local cwd = uv.cwd()
	local found = REPOS[cwd]
	if found == nil and not vim.in_fast_event() then
		local out = vim.fn.systemlist({ "git", "--no-optional-locks", "rev-parse", "--show-toplevel", "--absolute-git-dir" })
		if vim.v.shell_error == 0 and out[1] and out[2] then
			found = { root = out[1], git_dir = out[2] }
			REPOS[cwd] = found
		end
	end
	return found
end

function M.root()
	local found = repo()
	return found and found.root
end

-- The real git dir (not `root/.git`, which is a file in worktrees and submodules).
function M.git_dir()
	local found = repo()
	return found and found.git_dir
end

-- Path relative to the repo root (the form git pathspecs use), or nil when it lies outside the repo.
function M.relative(path)
	local root = M.root()
	local abs = path and path ~= "" and (uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")) or nil
	if root and abs and abs:sub(1, #root + 1) == root .. "/" then
		return abs:sub(#root + 2)
	end
	return nil
end

-- Read-only flags for every call: no fsmonitor daemon, and no optional index.lock so the panel never
-- blocks a `git add`/`git commit` running in the user's terminal.
function M.argv(args)
	local argv = { "git", "--no-optional-locks", "-c", "core.fsmonitor=false" }
	local root = M.root()
	if root then
		vim.list_extend(argv, { "-C", root })
	end
	for i = 2, #args do
		argv[#argv + 1] = args[i]
	end
	return argv
end

-- Blocking; returns stdout (stderr merged in) and whether git exited 0.
function M.system(args, input)
	local out = vim.fn.system(M.argv(args), input)
	return out, vim.v.shell_error == 0
end

-- Blocking; returns stdout lines, or nil when git failed.
function M.lines(args)
	local lines = vim.fn.systemlist(M.argv(args))
	return (vim.v.shell_error == 0) and lines or nil
end

-- Non-blocking; a missing `git` binary is reported like a failed exit instead of throwing.
function M.spawn(args, on_exit)
	if not pcall(vim.system, M.argv(args), { text = true }, on_exit) then
		on_exit({ code = 127, stdout = "" })
	end
end

return M
