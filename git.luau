--!nonstrict
-- Read-only repository inspection plus worktree add/remove, via argv subprocesses.
-- Every function reports through its callback and never raises into the caller.
local Git = {}
-- Subprocesses started so far; lets tests prove caching and coalescing.
Git._spawns = 0

local TTL_MS = 15000
local TIMEOUT_MS = 15000

-- root -> { at, info }; path -> { at, root }. Cleared by any mutation.
local cache = {}
local roots = {}
-- root -> callbacks waiting on the inspection already running for it.
local pending = {}

local function later(fn, ...)
	local args = table.pack(...)
	tern.timer(0, function(cx)
		args[args.n + 1] = cx
		fn(table.unpack(args, 1, args.n + 1))
	end)
end

-- Calls `cb` without letting a consumer error cut off the other waiters.
local function call(cb, ...)
	local ok, err = pcall(cb, ...)
	if not ok then tern.log.warn("git.luau: callback failed: " .. tostring(err)) end
end

-- done(result|nil, err|nil, cx). Spawn failures and timeouts become `err`.
local function run(argv, cwd, done, env)
	Git._spawns += 1
	local ok, err = pcall(function()
		tern.process.run(argv, { timeout_ms = TIMEOUT_MS, cwd = cwd, env = env }, function(result, cx)
			if result.timed_out then
				done(nil, argv[1] .. " timed out", cx)
			else
				done(result, nil, cx)
			end
		end)
	end)
	if not ok then
		tern.timer(0, function(cx) done(nil, "could not start " .. argv[1] .. ": " .. tostring(err), cx) end)
	end
end

local function git(path, args, done)
	local argv = { "git", "--no-optional-locks", "-C", path }
	for _, arg in ipairs(args) do table.insert(argv, arg) end
	run(argv, nil, done)
end

local function failure(result, err)
	if err then return err end
	local detail = string.gsub(result.stderr, "%s+$", "")
	if detail == "" then detail = "exit status " .. tostring(result.status) end
	return detail
end

local function chomp(text) return (string.gsub(text, "\n$", "")) end

-- Name lookup without the user's shell; Tern's PATH may lack Homebrew.
local ghPath
local function findGh()
	if ghPath then return ghPath end
	local home = tern.getenv("HOME") or ""
	local dirs = {}
	for dir in string.gmatch((tern.getenv("PATH") or "") .. ":", "(.-):") do
		if string.sub(dir, 1, 1) == "/" then table.insert(dirs, dir) end
	end
	for _, dir in ipairs({ "/opt/homebrew/bin", "/usr/local/bin", home .. "/.local/bin" }) do
		table.insert(dirs, dir)
	end
	for _, dir in ipairs(dirs) do
		if tern.fs.exists(dir .. "/gh") then
			ghPath = dir .. "/gh"
			return ghPath
		end
	end
	return nil
end

-- `status --porcelain=v2 --branch` -> branch (nil when detached), dirty, ahead, behind.
function Git._parseStatus(text)
	local branch, dirty, ahead, behind = nil, false, 0, 0
	for line in string.gmatch(text, "[^\n]+") do
		if string.sub(line, 1, 1) ~= "#" then
			dirty = true
		else
			local head = string.match(line, "^# branch%.head (.+)$")
			if head and head ~= "(detached)" then branch = head end
			local a, b = string.match(line, "^# branch%.ab %+(%d+) %-(%d+)$")
			if a then ahead, behind = tonumber(a), tonumber(b) end
		end
	end
	return branch, dirty, ahead, behind
end

-- `worktree list --porcelain` -> {{path, branch, is_main}}; bare and prunable entries are dropped.
function Git._parseWorktrees(text)
	local list, current, count = {}, nil, 0
	local function flush()
		if current and not current.bare and not current.prunable then
			table.insert(list, { path = current.path, branch = current.branch, is_main = current.is_main })
		end
	end
	for line in string.gmatch(text .. "\n", "(.-)\n") do
		local path = string.match(line, "^worktree (.+)$")
		if path then
			flush()
			count += 1
			-- The first record is the main worktree.
			current = { path = path, is_main = count == 1 }
		elseif current then
			local ref = string.match(line, "^branch (.+)$")
			if ref then current.branch = string.gsub(ref, "^refs/heads/", "") end
			if line == "bare" then current.bare = true end
			if line == "prunable" or string.sub(line, 1, 9) == "prunable " then current.prunable = true end
		end
	end
	flush()
	return list
end

function Git._parsePr(text)
	local ok, rows = pcall(tern.json.decode, text)
	local row = ok and type(rows) == "table" and rows[1]
	if type(row) ~= "table" or type(row.number) ~= "number" then return nil end
	local state = string.lower(tostring(row.state))
	if state == "open" and row.isDraft then state = "draft" end
	if state ~= "draft" and state ~= "open" and state ~= "merged" and state ~= "closed" then return nil end
	return { number = row.number, state = state, url = row.url }
end

-- finish(info|nil, cx). `root` is a worktree top level.
local function inspectRoot(root, finish)
	git(root, { "status", "--porcelain=v2", "--branch" }, function(status, err, cx)
		if not status or status.status ~= 0 then return finish(nil, cx) end
		local branch, dirty, ahead, behind = Git._parseStatus(status.stdout)
		local info = {
			root = root, branch = branch, dirty = dirty, ahead = ahead, behind = behind,
			worktrees = {}, pr = nil,
		}
		git(root, { "worktree", "list", "--porcelain" }, function(listing, _, cx2)
			local trees = listing and listing.status == 0 and Git._parseWorktrees(listing.stdout) or {}
			info.worktrees = trees
			-- Dirtiness of the other worktrees, the PR lookup, then done.
			local gh = branch and findGh()
			local left = 1 + (gh and 1 or 0)
			for _, tree in ipairs(trees) do
				if tree.path ~= root then left += 1 end
			end
			local lastCx = cx2
			local function step(c)
				lastCx = c or lastCx
				left -= 1
				if left == 0 then finish(info, lastCx) end
			end
			for _, tree in ipairs(trees) do
				tree.dirty = false
				if tree.path == root then
					tree.dirty = dirty
				else
					git(tree.path, { "status", "--porcelain" }, function(r, _, c)
						tree.dirty = r ~= nil and r.status == 0 and r.stdout ~= ""
						step(c)
					end)
				end
			end
			if gh then
				run({
					gh, "pr", "list", "--head", branch, "--state", "all",
					"--json", "number,state,isDraft,url", "--limit", "1",
				}, root, function(r, _, c)
					if r and r.status == 0 then info.pr = Git._parsePr(r.stdout) end
					step(c)
				end, { GH_PROMPT_DISABLED = "1", NO_COLOR = "1" })
			end
			step(cx2)
		end)
	end)
end

--- cb(info) for a path inside a git work tree, cb(nil) otherwise (second arg: a fresh cx).
--- info = {root, branch?, dirty, ahead, behind, worktrees={{path, branch?, dirty, is_main}}, pr?}.
--- Results are cached for 15 s per root; treat `info` as read-only.
function Git.inspect(cx, path, cb)
	local ok, err = pcall(function()
		local now = tern.now()
		local function deliver(info) later(call, cb, info) end
		local function withRoot(root)
			local hit = cache[root]
			if hit and now < hit.at + TTL_MS then return deliver(hit.info) end
			local waiters = pending[root]
			if waiters then return table.insert(waiters, cb) end
			pending[root] = { cb }
			inspectRoot(root, function(info, c)
				local list = pending[root]
				pending[root] = nil
				if info then cache[root] = { at = tern.now(), info = info } end
				for _, waiter in ipairs(list or {}) do call(waiter, info, c) end
			end)
		end
		local known = roots[path]
		if known and now < known.at + TTL_MS then return withRoot(known.root) end
		git(path, { "rev-parse", "--show-toplevel" }, function(r, _, c)
			if not r or r.status ~= 0 or r.stdout == "" then return call(cb, nil, c) end
			local root = chomp(r.stdout)
			roots[path] = { at = tern.now(), root = root }
			withRoot(root)
		end)
	end)
	if not ok then
		tern.log.warn("git.luau: inspect failed: " .. tostring(err))
		later(call, cb, nil)
	end
end

--- Drops every cached result; mutations below call it themselves.
function Git.invalidate()
	cache = {}
	roots = {}
end

-- Keeps the name readable as a directory suffix on any filesystem.
function Git._sanitize(branch)
	local s = string.gsub(branch, '[/\\:*?"<>|%s]', "-")
	s = string.gsub(s, "%-+", "-")
	s = string.gsub(s, "^[%-%.]+", "")
	s = string.gsub(s, "[%-%.]+$", "")
	return s ~= "" and s or "worktree"
end

--- cb(path) after `git worktree add` of a new sibling `<root>-<branch>`, or cb(nil, err).
--- Checks out `branch` when it exists, else creates it from HEAD.
function Git.addWorktree(cx, root, branch, cb)
	local function fail(message) later(call, cb, nil, message) end
	if type(root) ~= "string" or root == "" then return fail("No repository.") end
	if type(branch) ~= "string" or branch == "" or string.sub(branch, 1, 1) == "-" then
		return fail("Invalid branch name.")
	end
	local ok, err = pcall(function()
		git(root, { "check-ref-format", "--branch", branch }, function(check, e, c)
			if not check or check.status ~= 0 or chomp(check.stdout) ~= branch then
				return call(cb, nil, "Invalid branch name: " .. branch, c)
			end
			local path = string.gsub(root, "/+$", "") .. "-" .. Git._sanitize(branch)
			if tern.fs.exists(path) then return call(cb, nil, "Path already exists: " .. path, c) end
			git(root, { "show-ref", "--verify", "--quiet", "refs/heads/" .. branch }, function(ref, e2, c2)
				if not ref then return call(cb, nil, e2, c2) end
				local args = ref.status == 0 and { "worktree", "add", path, branch }
					or { "worktree", "add", "-b", branch, path }
				git(root, args, function(r, e3, c3)
					Git.invalidate()
					if not r or r.status ~= 0 then return call(cb, nil, failure(r, e3), c3) end
					call(cb, path, nil, c3)
				end)
			end)
		end)
	end)
	if not ok then fail(tostring(err)) end
end

--- cb(true) after `git worktree remove`; cb(false, err) for the main worktree, a dirty tree or a git
--- failure. Never forces and never touches branches.
function Git.removeWorktree(cx, path, cb)
	local function fail(message) later(call, cb, false, message) end
	if type(path) ~= "string" or path == "" then return fail("No worktree.") end
	local ok, err = pcall(function()
		git(path, { "rev-parse", "--show-toplevel" }, function(top, e, c)
			if not top or top.status ~= 0 then return call(cb, false, failure(top, e), c) end
			local tree = chomp(top.stdout)
			git(tree, { "worktree", "list", "--porcelain" }, function(listing, e2, c2)
				if not listing or listing.status ~= 0 then return call(cb, false, failure(listing, e2), c2) end
				local main = string.match(listing.stdout, "^worktree ([^\n]+)")
				if not main or main == tree then return call(cb, false, "Refusing to remove the main worktree.", c2) end
				git(tree, { "status", "--porcelain" }, function(status, e3, c3)
					if not status or status.status ~= 0 then return call(cb, false, failure(status, e3), c3) end
					if status.stdout ~= "" then
						return call(cb, false, "Worktree has uncommitted changes.", c3)
					end
					git(main, { "worktree", "remove", tree }, function(r, e4, c4)
						Git.invalidate()
						if not r or r.status ~= 0 then return call(cb, false, failure(r, e4), c4) end
						call(cb, true, nil, c4)
					end)
				end)
			end)
		end)
	end)
	if not ok then fail(tostring(err)) end
end

return Git
