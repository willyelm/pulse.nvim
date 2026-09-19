-- The one place git gets invoked: every call runs against the repo root, so the root-relative paths git
-- reports (status, numstat, log) and expects (pathspecs, `rev:path`) stay valid wherever nvim's cwd is.
-- Functions that resolve a repo take an optional `dir`; without one they use the panel's project directory
-- (see set_dir), falling back to nvim's cwd.
local M = {}
local uv = vim.uv or vim.loop

local project_dir

local REPOS = {}

-- Points every call that doesn't name a `dir` at the directory the panel was opened for (which differs from
-- nvim's cwd when opening e.g. `nvim ../other-project`). Nil goes back to nvim's cwd.
function M.set_dir(dir)
	project_dir = (dir and dir ~= "") and (vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")) or nil
end

-- Blocking calls give up after this long instead of freezing the editor on a stuck git.
local ROOT_TIMEOUT_MS, SYNC_TIMEOUT_MS = 5000, 15000

-- Runs argv to completion. stdout and stderr stay apart: git prints notices on stderr (cold caches,
-- fsmonitor, wrappers) that must never be mistaken for data. Returns stdout, ok, stderr.
local function run(argv, opts)
	local started, proc = pcall(vim.system, argv, vim.tbl_extend("force", { text = true }, opts or {}))
	if not started then
		return "", false, tostring(proc)
	end
	local res = proc:wait()
	local stderr = res.stderr or ""
	if res.code == 124 then
		stderr = "timed out"
	end
	return res.stdout or "", res.code == 0, stderr
end

-- Repo layout for `dir` (default the project directory) as { root, git_dir }, or nil outside a repo. Cached per dir
-- once found; once warmed from the main thread it is also safe to call from fast (libuv) callbacks, which
-- can't run the lookup themselves.
local function repo(dir)
	dir = dir or project_dir or uv.cwd()
	local found = REPOS[dir]
	if found == nil and not vim.in_fast_event() then
		local out, ok = run(
			{ "git", "--no-optional-locks", "-C", dir, "rev-parse", "--show-toplevel", "--absolute-git-dir" },
			{ timeout = ROOT_TIMEOUT_MS }
		)
		local root, git_dir = out:match("^([^\n]+)\n([^\n]+)")
		-- Only a real directory is cached: a wrong root would break every later call for this dir.
		local stat = ok and root and uv.fs_stat(root)
		if stat and stat.type == "directory" then
			found = { root = root, git_dir = git_dir }
			REPOS[dir] = found
		end
	end
	return found
end

function M.root(dir)
	local found = repo(dir)
	return found and found.root
end

-- The real git dir (not `root/.git`, which is a file in worktrees and submodules).
function M.git_dir(dir)
	local found = repo(dir)
	return found and found.git_dir
end

-- Path relative to the repo root (the form git pathspecs use), or nil when it lies outside the repo.
function M.relative(path, dir)
	local root = M.root(dir)
	local abs = path and path ~= "" and (uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")) or nil
	if root and abs and abs:sub(1, #root + 1) == root .. "/" then
		return abs:sub(#root + 2)
	end
	return nil
end

-- Read-only flags for every call: no fsmonitor daemon, and no optional index.lock so the panel never
-- blocks a `git add`/`git commit` running in the user's terminal.
function M.argv(args, dir)
	local argv = { "git", "--no-optional-locks", "-c", "core.fsmonitor=false" }
	dir = dir or project_dir or uv.cwd()
	-- Never fall back to the process cwd: outside a repo, git must fail here (and say so), not answer
	-- for whatever repo nvim happened to be started in.
	vim.list_extend(argv, { "-C", M.root(dir) or dir })
	for i = 2, #args do
		argv[#argv + 1] = args[i]
	end
	return argv
end

-- Blocking; returns the output and whether git exited 0. On success the output is stdout alone; on
-- failure it is git's error text, ready to show.
function M.system(args, input)
	local out, ok, err = run(M.argv(args), { stdin = input, timeout = SYNC_TIMEOUT_MS })
	if ok then
		return out, true
	end
	return vim.trim(err) ~= "" and vim.trim(err) or out, false
end

-- Blocking; returns stdout lines, or nil when git failed.
function M.lines(args)
	local out, ok = run(M.argv(args), { timeout = SYNC_TIMEOUT_MS })
	if not ok then
		return nil
	end
	local lines = vim.split(out, "\n", { plain = true })
	if lines[#lines] == "" then
		lines[#lines] = nil
	end
	return lines
end

-- Non-blocking; a missing `git` binary is reported like a failed exit instead of throwing.
function M.spawn(args, on_exit, dir)
	if not pcall(vim.system, M.argv(args, dir), { text = true }, on_exit) then
		on_exit({ code = 127, stdout = "" })
	end
end

return M
