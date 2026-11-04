--!nonstrict
local Folders = require("./folders")
local Git = require("./git")
local Harness = require("./harness")
local Badge = require("./badge")
local view = require("./view")

local rendered = {}
local problem
-- Whether ↻ is spinning for an explicit refresh.
local spinning = false
local picking = false
local redraw_later
-- The pane showing the panel; its own activity says nothing about a session.
local slotPane = nil

local function records(key)
	local value = tern.kv.get(key)
	if value == nil then return {} end
	assert(type(value) == "table", "Roost storage is invalid: " .. key)
	return value
end

local function localHost(cx)
	return cx.hosts:current().kind == "local"
end

local function requireLocal(cx)
	if localHost(cx) then return true end
	cx:toast("error", "Local host required", "Switch to the local host.")
	return false
end

-- Keep variable labels short without cutting a UTF-8 character.
local function notificationLabel(label)
	if utf8.len(label) <= 32 then return label end
	return label:sub(1, utf8.offset(label, 32) - 1) .. "…"
end

local function report(cx, text, title)
	problem = tostring(text)
	tern.log.warn(problem)
	local description = if #problem <= 40 and not problem:find("[\r\n]")
		then problem else "See Tern’s log for details."
	cx:toast("error", title or "Action failed", description)
end

local function sessionsById(cx)
	local result = {}
	for _, session in cx.sessions:list() do result[tostring(session.id)] = session end
	return result
end

-- ── Activity ────────────────────────────────────────────────────────────
-- Tern gives no timestamps, so the time of each session's last activity is
-- tracked here: events stamp it in memory, and the tick saves it to kv.
local lastActive = {}
do
	for key, at in records("activity") do
		if type(at) == "number" then lastActive[key] = at end
	end
end
local activityDirty, activitySavedAt = false, 0
local seedDone, seeding = false, false

local function touchSession(sessionId)
	lastActive[tostring(sessionId)] = os.time()
	activityDirty = true
end

local function touchPane(cx, pane)
	local tab = pane and pane ~= slotPane and cx.session:tab_of(pane)
	if not tab then return end
	for _, info in cx.session:tabs() do
		if info.id == tab then touchSession(info.session); return end
	end
end

local function ternBinary()
	for _, path in { "/Applications/Tern.app/Contents/MacOS/tern", (tern.getenv("HOME") or "") .. "/Applications/Tern.app/Contents/MacOS/tern" } do
		if tern.fs.exists(path) then return path end
	end
	return nil
end

-- Sessions older than this plugin have no stamp. `tern inspect` knows how long
-- each pane has been quiet, so start from that rather than from "now".
local function seedActivity(cx)
	if seeding or seedDone then return end
	local bin = ternBinary()
	if not bin then seedDone = true; return end
	seeding = true
	tern.process.run({ bin, "inspect", "--json" }, { timeout_ms = 15000 }, function(result, nextCx)
		seeding, seedDone = false, true
		if not nextCx or result.status ~= 0 then return end
		local ok, err = pcall(function()
			local data = tern.json.decode(result.stdout)
			local quiet = {}
			for _, pane in data.panes or {} do quiet[pane.pane] = pane.quiet_ms end
			local live, byName = sessionsById(nextCx), {}
			for _, session in live do byName[session.name] = session end
			local now = os.time()
			for _, inspected in data.sessions or {} do
				local best
				for _, tab in inspected.tabs or {} do
					for _, block in tab.blocks or {} do
						local ms = quiet[block.id]
						if type(ms) == "number" and (best == nil or ms < best) then best = ms end
					end
				end
				local session = live[tostring(inspected.id)] or byName[inspected.name]
				if session and best then
					local key = tostring(session.id)
					if lastActive[key] == nil then lastActive[key] = now - math.floor(best / 1000) end
					activityDirty = true
				end
			end
		end)
		if not ok then tern.log.warn("Roost activity seed failed: " .. tostring(err)) end
		redraw_later()
	end)
end

local function saveActivity(cx, liveIds)
	if not activityDirty or tern.now() - activitySavedAt < 20000 then return end
	activitySavedAt, activityDirty = tern.now(), false
	for key in lastActive do
		if not liveIds[key] then lastActive[key] = nil end
	end
	tern.kv.set("activity", lastActive)
end

-- ── Settled ─────────────────────────────────────────────────────────────
local SETTLED_CAP = 200
-- The last known facts of each live session, so closing it from anywhere can
-- still shelve it. Session id (string) → record.
local known = {}
-- Sessions Settle is closing itself, so their session_ended doesn't shelve them twice.
local closing = {}
local settledSeq = 0

local function settledList()
	return records("settled")
end

local function shelve(info)
	local list = settledList()
	settledSeq += 1
	local record = table.clone(info)
	record.sid = tostring(os.time()) .. string.format("%03d", settledSeq % 1000)
	table.insert(list, 1, record)
	while #list > SETTLED_CAP do table.remove(list) end
	tern.kv.set("settled", list)
end

-- ── Git ─────────────────────────────────────────────────────────────────
-- Optional: a folder that is a repository shows its branch and worktrees; any
-- other folder is untouched. path → info table, or false for "not a repository".
local gitCache, gitAt, gitInflight = {}, {}, {}
local GIT_TTL_MS = 20000
local GIT_NOT_TTL_MS = 60000

local function gitInfoOf(path)
	return gitCache[path] or nil
end

-- Folders (and worktrees) whose repository state is out of date, a few per tick.
local function refreshGit(cx, paths)
	local started = 0
	local now = tern.now()
	for _, path in paths do
		if started >= 3 then break end
		local at = gitAt[path]
		local ttl = if gitCache[path] == false then GIT_NOT_TTL_MS else GIT_TTL_MS
		if not gitInflight[path] and (not at or now - at >= ttl) and tern.fs.exists(path) then
			gitInflight[path] = true
			started += 1
			local ok, err = pcall(Git.inspect, cx, path, function(info)
				gitInflight[path] = nil
				gitAt[path] = tern.now()
				local before = tern.json.encode(gitCache[path] or false)
				gitCache[path] = info or false
				if tern.json.encode(gitCache[path]) ~= before then redraw_later() end
			end)
			if not ok then
				gitInflight[path] = nil
				gitAt[path] = now
				gitCache[path] = false
				tern.log.warn("Roost git inspect failed: " .. tostring(err))
			end
		end
	end
end

-- ── Model ───────────────────────────────────────────────────────────────
-- The folder a tab works in: its focused pane's directory, else its first
-- terminal or agent's, else any block's. The focused pane is often a plugin
-- block, such as this panel, which has no directory.
local function tabCwd(tab, panes)
	local function known(pane)
		return type(pane.cwd) == "string" and pane.cwd ~= "" and pane.kind ~= "plugin" and pane.kind ~= "canvas"
	end
	for _, pane in panes do
		if pane.pane == tab.pane and known(pane) then return pane.cwd end
	end
	for _, pane in panes do
		if (pane.kind == "terminal" or pane.kind == "agent") and known(pane) then return pane.cwd end
	end
	for _, pane in panes do
		if known(pane) then return pane.cwd end
	end
	if type(tab.cwd) == "string" and tab.cwd ~= "" then return tab.cwd end
	return nil
end

-- Each session's folder, by session id (as a string): its first tab's
-- directory, falling through to the next tab when the first has none known.
local function sessionCwds(cx)
	local panesByTab = {}
	for _, pane in cx.session:panes() do
		if pane.tab then
			panesByTab[pane.tab] = panesByTab[pane.tab] or {}
			table.insert(panesByTab[pane.tab], pane)
		end
	end
	local tabsBySession = {}
	for _, tab in cx.session:tabs() do
		local key = tostring(tab.session)
		tabsBySession[key] = tabsBySession[key] or {}
		table.insert(tabsBySession[key], tab)
	end
	local result = {}
	for key, tabs in tabsBySession do
		table.sort(tabs, function(a, b) return a.position < b.position end)
		for _, tab in tabs do
			local cwd = Folders.norm(tabCwd(tab, panesByTab[tab.id] or {}))
			if cwd ~= "" then result[key] = cwd; break end
		end
	end
	return result
end

local function badgeOf(path)
	return Badge.initials(Folders.basename(path)), Badge.role(path)
end

-- Folders → sessions. Pinned folders come first, in the order pinned, and stay
-- even when empty; a session lives under the deepest pinned folder (or known
-- repository root or worktree) holding its directory, else under its own
-- directory. The rest follow by session count, then name; sessions with no
-- known directory close the list under "Other". A repository's linked
-- worktrees nest under its main folder.
local function model(cx)
	local home = tern.getenv("HOME")
	local now = os.time()
	local current = cx.sessions:current()
	local cwds = sessionCwds(cx)
	local collapsed = records("collapsed")
	local pinned = {}
	for _, path in records("pinned") do
		local norm = Folders.norm(path)
		if norm ~= "" and not table.find(pinned, norm) then table.insert(pinned, norm) end
	end
	local owners = table.clone(pinned)
	for _, info in gitCache do
		if info then
			if info.root then table.insert(owners, Folders.norm(info.root)) end
			for _, tree in info.worktrees or {} do table.insert(owners, Folders.norm(tree.path)) end
		end
	end
	local groups, byPath = {}, {}
	local function group(path)
		local entry = byPath[path]
		if not entry then
			local other = path == Folders.OTHER
			local prefix, name = "", path
			if not other then prefix, name = Folders.parts(path, home) end
			local badge, role = badgeOf(path)
			entry = {
				path = path, prefix = prefix, name = name, other = other, badge = badge, role = role,
				pinned = table.find(pinned, path) ~= nil, order = table.find(pinned, path) or 0,
				collapsed = collapsed[path] == true, sessions = {}, children = {}, newest = 0,
			}
			byPath[path] = entry
			table.insert(groups, entry)
		end
		return entry
	end
	for _, path in pinned do group(path) end
	local total = 0
	local live = {}
	for _, session in cx.sessions:list() do
		if session.host == current.host then
			total += 1
			local key = tostring(session.id)
			live[key] = true
			local cwd = cwds[key]
			local entry = group(if cwd then Folders.owner(cwd, owners) else Folders.OTHER)
			local sub = if cwd and cwd ~= entry.path then Folders.relative(cwd, entry.path) else nil
			local ok, detected = pcall(Harness.detect, cx, session.id)
			local harness = if ok and detected then detected else { kind = "shell", label = "shell", icon = "terminal", state = "idle" }
			local agent = if harness.state == "working" or harness.state == "waiting" then harness.state else nil
			if agent == "working" then touchSession(session.id) end
			if lastActive[key] == nil and seedDone then lastActive[key] = now; activityDirty = true end
			local at = lastActive[key] or now
			local hostName = Harness.host(cx, session.host) or "local"
			local where = if cwd then Folders.short(cwd, home) else Folders.OTHER
			local badge, role = badgeOf(entry.path)
			table.insert(entry.sessions, {
				id = session.id, name = session.name, tabs = session.tabs, locked = session.locked,
				current = session.current, agent = agent, sub = sub, where = where, host = hostName,
				harness = { kind = harness.kind, label = harness.label, icon = harness.icon, model = harness.model },
				at = at, age = Folders.age(math.max(0, now - at)), badge = badge, role = role,
			})
			if at > entry.newest then entry.newest = at end
			known[key] = {
				name = session.name, cwd = cwd, folder = entry.path, kind = harness.kind, label = harness.label,
				model = harness.model, host = hostName, at = at,
			}
		end
	end
	for _, entry in groups do
		table.sort(entry.sessions, function(a, b)
			if a.at ~= b.at then return a.at > b.at end
			local x, y = string.lower(a.name), string.lower(b.name)
			if x ~= y then return x < y end
			return a.id < b.id
		end)
	end
	-- Linked worktrees nest under their repository's main folder (a pinned one stays top-level).
	local nested = {}
	local function describe(entry, info, tree)
		local source = info or tree
		if source and source.branch then
			entry.git = {
				branch = source.branch, dirty = source.dirty == true,
				ahead = source.ahead or 0, behind = source.behind or 0, pr = source.pr,
			}
		end
	end
	for _, entry in table.clone(groups) do
		local info = gitInfoOf(entry.path)
		if info and not entry.other then
			describe(entry, info, nil)
			-- Only a repository's main folder holds worktrees; a linked one lists itself and its siblings.
			local isMain = false
			for _, tree in info.worktrees or {} do
				if tree.is_main and Folders.norm(tree.path) == entry.path then isMain = true end
			end
			if isMain and not entry.worktree then
				for _, tree in info.worktrees or {} do
					if not tree.is_main then
						local path = Folders.norm(tree.path)
						local child = byPath[path]
						if child and child.pinned then child = nil
						else
							if not child then child = group(path) end
							child.worktree = true
							local own = gitInfoOf(path)
							local label = tree.branch or Folders.basename(path)
							child.prefix, child.name = "", label
							describe(child, own, tree)
							table.insert(entry.children, child)
							nested[child] = true
						end
					end
				end
				table.sort(entry.children, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
			end
		end
	end
	local top = {}
	for _, entry in groups do
		if not nested[entry] then table.insert(top, entry) end
	end
	local function newestOf(entry)
		local best = entry.newest
		for _, child in entry.children do best = math.max(best, newestOf(child)) end
		return best
	end
	local function finish(entry)
		local newest = newestOf(entry)
		entry.age = if newest > 0 then Folders.age(math.max(0, now - newest)) else ""
		entry.newest = nil
		for _, child in entry.children do finish(child) end
		for _, session in entry.sessions do session.at = nil end
	end
	for _, entry in top do finish(entry) end
	table.sort(top, function(a, b)
		if a.pinned ~= b.pinned then return a.pinned end
		if a.pinned then return a.order < b.order end
		if a.other ~= b.other then return b.other end
		if #a.sessions ~= #b.sessions then return #a.sessions > #b.sessions end
		local x, y = string.lower(a.name), string.lower(b.name)
		if x ~= y then return x < y end
		return a.path < b.path
	end)
	-- Settled: shelved sessions, newest first.
	local rows = {}
	local list = settledList()
	for _, record in list do
		local folder = record.folder or record.cwd or Folders.OTHER
		local badge, role = badgeOf(folder)
		table.insert(rows, {
			sid = record.sid, name = record.name, badge = badge, role = role,
			where = if record.cwd then Folders.short(record.cwd, home) else Folders.OTHER,
			host = record.host or "local", harness = record.label or "shell", model = record.model,
			age = Folders.age(math.max(0, now - (record.at or now))),
		})
	end
	local result = {
		groups = top, total = total, spinning = spinning,
		settled = { open = tern.kv.get("settled-open") == true, count = #list, rows = rows },
	}
	result.live = live
	return result
end

-- The folders and worktrees on show, for the git refresh.
local function shownPaths(data)
	local paths = {}
	local function walk(entry)
		if not entry.other then table.insert(paths, entry.path) end
		for _, child in entry.children do walk(child) end
	end
	for _, entry in data.groups do walk(entry) end
	return paths
end

local NAVIGATOR = {
	title = "Roost",
	about = "Every Tern session roosts here, grouped by working folder. Click a session to switch to it; "
		.. "right-click one to rename it, open a tab in it, lock it, settle it or close it.",
}

local function isNavigator(canvas)
	return canvas.owner == tern.plugin.id and canvas.title == NAVIGATOR.title
end

-- Other plugins' panels that also hug a tab's left edge. Two panels each
-- insisting on being first would swap places forever, so Roost sits behind
-- them. Canvas owner → title.
local RAILS = { overseer = "Projects" }

local function rails(cx)
	local set = {}
	for _, canvas in cx.canvas:list() do
		if RAILS[canvas.owner] == canvas.title then set[canvas.pane] = true end
	end
	return set
end

-- The window's one Roost panel: its canvas. Adopts what a reload left open
-- and closes any extra, so a window never shows two.
local function slot(cx)
	if slotPane and not cx.session:pane(slotPane) then slotPane = nil end
	local found = {}
	for _, canvas in cx.canvas:list() do
		if isNavigator(canvas) and cx.session:pane(canvas.pane) then table.insert(found, canvas.pane) end
	end
	slotPane = slotPane or found[1]
	for _, pane in found do
		if pane ~= slotPane then
			cx.layout:close(pane)
			rendered[pane] = nil
		end
	end
	return slotPane
end

-- Model data without the bookkeeping the view doesn't draw.
local function viewData(cx)
	local data = model(cx)
	local live = data.live
	data.live = nil
	return data, live
end

local function draw(cx)
	local pane = slot(cx)
	if not pane then return end
	-- A just-opened canvas only accepts updates once canvas:list() reports it.
	local ready = false
	for _, canvas in cx.canvas:list() do
		if canvas.pane == pane then ready = true end
	end
	if not ready then return end
	local data = viewData(cx)
	local signature = tern.json.encode(data)
	if rendered[pane] == signature then return end
	cx.canvas:set(pane, { view = view.render(data), dock = view.dock(data) })
	rendered[pane] = signature
end

-- Asks for a draw soon, in a timer callback of its own. Tern gives each hook
-- callback 50 ms and disables the hook for the rest of the session after one
-- overrun, so clicks and process results never draw inline; requests made
-- before the draw runs share it.
local drawQueued = false
local function redraw(_cx)
	if drawQueued then return end
	drawQueued = true
	tern.timer(0, function(cx)
		drawQueued = false
		if not cx then return end
		local ok, err = pcall(draw, cx)
		if not ok and problem ~= tostring(err) then report(cx, err) end
	end)
end
redraw_later = function() redraw(nil) end

-- Tern panes belong to one tab, so the window's one Roost panel follows you:
-- whenever another tab is shown, it moves there, full height on the left.
local DEFAULT_SHARE = 0.3
-- The width you leave it at travels with it (a share of the tab).
local share = tonumber(tern.kv.get("panel-share")) or DEFAULT_SHARE
-- Whether you want the panel shown; it reopens after vanishing with its tab.
local wantPanel = tern.kv.get("panel-open") == true
-- The tab the panel was last placed in, to tell a closed panel from a closed tab.
local panelTab = nil

-- The first pane of a split tree that is not in `skip` (a set of pane ids).
local function firstLeaf(tree, skip)
	if not tree then return nil end
	if tree.pane then return if skip and skip[tree.pane] then nil else tree.pane end
	return firstLeaf(tree[1], skip) or firstLeaf(tree[2], skip)
end

-- The split whose left side is `pane`: the tab's root, or the one behind another panel.
local function splitOf(tree, pane)
	if not tree or tree.pane then return nil end
	if tree.split == "right" and tree[1] and tree[1].pane == pane then return tree end
	return splitOf(tree[1], pane) or splitOf(tree[2], pane)
end

-- The panel's share of the area it splits when it is that area's whole left side.
local function leftShare(cx, tab, pane)
	local layout = cx.session:layout(tab)
	local node = layout and splitOf(layout.root, pane)
	return node and node.ratio or nil
end

-- Tern resizes in cells, and a hidden tab's cells differ from the shown one's,
-- so steer by the ratio: step, see how far it moved, correct.
local function sizeTo(cx, tab, pane, want)
	local r = leftShare(cx, tab, pane)
	local step = if r then math.floor((want - r) * 180 + 0.5) else 0
	for _ = 1, 8 do
		if not r or math.abs(r - want) < 0.005 or step == 0 then return end
		cx.layout:resize(pane, "right", step)
		local after = leftShare(cx, tab, pane)
		if not after or after == r then return end
		step = math.floor((want - after) * step / (after - r) + 0.5)
		r = after
	end
end

-- Moves the slot into `tab`, left of everything (and any other plugin's
-- left-edge panel), unless it is already there.
local function pin(cx, tab)
	local pane = slot(cx)
	if not pane then return end
	local layout = cx.session:layout(tab)
	if not layout then return end
	local others = rails(cx)
	local from = cx.session:tab_of(pane)
	if from == tab and firstLeaf(layout.root, others) == pane then
		panelTab = tab
		return
	end
	local skip = table.clone(others)
	skip[pane] = true
	local target = firstLeaf(layout.root, skip)
	if not target then return end
	if from then
		local current = leftShare(cx, from, pane)
		if current and math.abs(current - share) > 0.01 then
			share = math.clamp(current, 0.15, 0.6)
			tern.kv.set("panel-share", share)
		end
	end
	if from ~= tab then
		if from then
			cx.layout:move_to_tab(pane, tab, { focus = false })
		else
			cx.layout:unpark(pane, { focus = false })
		end
	end
	cx.layout:move(pane, target, "left", { focus = false })
	sizeTo(cx, tab, pane, share)
	panelTab = tab
end

local function shownTab(cx)
	local focused = cx.session:focused()
	return focused and cx.session:tab_of(focused)
end

local function setWantPanel(want)
	wantPanel = want
	tern.kv.set("panel-open", want)
end

-- Opens a fresh panel in `tab`.
local function openPanel(cx, tab)
	local data = viewData(cx)
	local pane, err = cx.canvas:open({
		title = NAVIGATOR.title, about = NAVIGATOR.about,
		view = view.render(data), dock = view.dock(data), how = "beside", focus = false,
	})
	if not pane then report(cx, err or "Could not open the Roost panel"); return nil end
	slotPane = pane
	rendered[pane] = tern.json.encode(data)
	if tab then pin(cx, tab) end
	return pane
end

-- Keeps the panel in the shown tab. Runs on every tab, pane and focus event and
-- each tick, so one disabled hook can't leave it behind.
local function follow(cx, tab)
	if not localHost(cx) then return end
	tab = tab or shownTab(cx)
	if not tab then return end
	local pane = slot(cx)
	if not pane then
		if not wantPanel then return end
		-- Gone while its tab remains: you closed it. Gone with its tab (a closed
		-- session or tab): bring it back here.
		local tabStillOpen = false
		for _, info in cx.session:tabs() do
			if info.id == panelTab then tabStillOpen = true end
		end
		if tabStillOpen then
			setWantPanel(false)
			panelTab = nil
			return
		end
		openPanel(cx, tab)
		return
	end
	-- Alone in the shown tab: its last terminal just closed. Close the tab as
	-- Tern would have; the tab shown next takes the panel.
	local layout = cx.session:tab_of(pane) == tab and cx.session:layout(tab)
	if layout then
		local skip = rails(cx)
		skip[pane] = true
		if not firstLeaf(layout.root, skip) then
			cx.layout:park(pane)
			return
		end
	end
	-- A panel already open (for example, from before an update) is one you want.
	if not wantPanel then setWantPanel(true) end
	pin(cx, tab)
end

-- Shows the Roost panel in the shown tab and focuses it, opening it if needed.
local function navigator(cx)
	if not requireLocal(cx) then return nil end
	setWantPanel(true)
	local tab = shownTab(cx)
	local pane = slot(cx)
	if pane then
		if tab then pin(cx, tab) end
	else
		pane = openPanel(cx, tab)
		if not pane then return nil end
	end
	cx.layout:focus(pane)
	redraw(cx)
	return pane
end

-- The Sessions shortcut: hides the panel when it has focus, otherwise shows and focuses it.
local function togglePanel(cx)
	if not requireLocal(cx) then return end
	local pane = slot(cx)
	if pane and cx.session:focused() == pane then
		setWantPanel(false)
		cx.layout:close(pane)
		rendered[pane] = nil
		slotPane, panelTab = nil, nil
		return
	end
	navigator(cx)
end

-- ↻ spins for at least one turn so a refresh is visible.
local SPIN_MIN_MS = 800

-- Everything is read live at each draw, so refreshing is drawing again.
local function refreshByHand(cx)
	if spinning then return end
	spinning = true
	for pane in rendered do rendered[pane] = nil end
	gitAt = {}
	Git.invalidate()
	redraw(cx)
	tern.timer(SPIN_MIN_MS, function(nextCx)
		spinning = false
		if nextCx then redraw(nextCx) end
	end)
end

local function switchTo(cx, id)
	if not sessionsById(cx)[tostring(id)] then
		report(cx, "Session is gone. Refresh Roost.", "Session not found")
		redraw(cx)
		return
	end
	local ok, err = pcall(function() cx.sessions:switch(id) end)
	if not ok then report(cx, err, "Switch failed"); return end
	touchSession(id)
	-- The panel follows you into the session's shown tab (see follow).
	follow(cx)
	redraw(cx)
end

-- What a built-in new tab runs: the agent command when Settings › New tabs and
-- splits open is Agent, else the login shell.
local function tabLaunch(cx, cwd)
	local launch = { cwd = cwd }
	if string.lower(tostring(cx.settings:get("new_blocks"))) == "agent" then
		launch.command = cx.settings:get("agent_command")
	end
	return launch
end

-- A new session named after the folder (or `name`), its first tab there. With
-- `command` the first tab runs it instead of a shell. Returns whether it started.
local function newSessionIn(cx, path, command, name)
	if not requireLocal(cx) then return false end
	if not tern.fs.exists(path) then
		report(cx, "Folder is missing: " .. path, "Folder unavailable")
		redraw(cx)
		return false
	end
	local ok, err = pcall(function()
		local session = cx.sessions:create({ name = name or Folders.basename(path), cwd = path })
		touchSession(session.id)
		if command then
			local shell
			for _, tab in cx.session:tabs() do
				if tab.session == session.id and (not shell or tab.position < shell.position) then shell = tab end
			end
			local pane = cx.layout:new_tab({ cwd = path, command = command })
			if pane and shell then cx.layout:close(shell.pane) end
			if not pane then error("Could not start " .. command .. " in " .. path, 0) end
		end
	end)
	if not ok then report(cx, err, "Session not created") end
	follow(cx)
	redraw(cx)
	return ok
end

local function newTabHere(cx, id)
	local session = sessionsById(cx)[tostring(id)]
	if not session then report(cx, "Session is gone. Refresh Roost.", "Session not found"); redraw(cx); return end
	local cwd = sessionCwds(cx)[tostring(id)]
	local ok, err = pcall(function()
		if not session.current then cx.sessions:switch(id) end
		cx.layout:new_tab(tabLaunch(cx, cwd))
	end)
	if not ok then report(cx, err, "Tab not opened") end
	touchSession(id)
	follow(cx)
	redraw(cx)
end

local function renameSession(cx, id)
	local session = sessionsById(cx)[tostring(id)]
	if not session then report(cx, "Session is gone. Refresh Roost.", "Session not found"); redraw(cx); return end
	cx:prompt({ value = session.name, placeholder = "Session name", action = "rename" })
		:next(function(answer, _err, nextCx)
			if not nextCx or answer == nil then return end
			local name = answer:match("^%s*(.-)%s*$")
			if name == "" then nextCx:toast("error", "Name can’t be blank"); return end
			local ok, err = pcall(function() nextCx.sessions:rename(id, name) end)
			if not ok then report(nextCx, err, "Rename failed") end
			redraw(nextCx)
		end)
end

-- ── Auto-naming ─────────────────────────────────────────────────────────
-- A session still named after its folder (Tern's and Roost's default) takes its
-- agent's pane title, e.g. omp's "OMNI: Evaluate repos", and follows it as the
-- title changes. kv "titled": session id → the name Roost gave it, or false once
-- the user renamed it (then Roost leaves it alone).
local function autoName(cx)
	local titled = records("titled")
	local cwds = sessionCwds(cx)
	local current = cx.sessions:current()
	local changed, live = false, {}
	for _, session in cx.sessions:list() do
		local key = tostring(session.id)
		live[key] = true
		local mine = titled[key]
		if mine and mine ~= session.name then mine = false; titled[key] = false; changed = true end
		local cwd = cwds[key]
		if session.host == current.host and mine ~= false and (mine or (cwd and session.name == Folders.basename(cwd))) then
			local title = Harness.detect(cx, session.id).title
			if title and title ~= session.name then
				local ok, err = pcall(function() cx.sessions:rename(session.id, title) end)
				if ok then titled[key] = title; changed = true
				else tern.log.warn("Roost auto-name failed: " .. tostring(err)) end
			end
		end
	end
	for key in titled do
		if not live[key] then titled[key] = nil; changed = true end
	end
	if changed then tern.kv.set("titled", titled) end
end

local function setLocked(cx, id, locked)
	local ok, err = pcall(function()
		if locked then cx.sessions:lock(id) else cx.sessions:unlock(id) end
	end)
	if not ok then report(cx, err, "Lock failed") end
	redraw(cx)
end

-- Closing the shown session takes the panel with it, so land in another
-- session first and bring the panel along. `settle` shelves it in Settled too
-- (any other close is shelved by its session_ended).
local function closeNow(cx, id, settle)
	local sessions = cx.sessions:list()
	local target = sessionsById(cx)[tostring(id)]
	if not target then redraw(cx); return end
	if target.locked then report(cx, "Unlock the session first.", "Session is locked"); return end
	if settle then
		local record = known[tostring(id)]
		if record then shelve(record); closing[tostring(id)] = true end
	end
	if target.current then
		local replacement
		for index, other in sessions do
			if other.id == target.id then
				replacement = sessions[index + 1] or sessions[index - 1]
				break
			end
		end
		if replacement and replacement.host == target.host then
			cx.sessions:switch(replacement.id)
			follow(cx)
		end
	end
	cx.sessions:close(id)
	follow(cx)
	cx:toast("info", if settle then "Session settled" else "Session closed", notificationLabel(target.name))
	redraw(cx)
end

local function closeSession(cx, id, settle)
	local session = sessionsById(cx)[tostring(id)]
	if not session then report(cx, "Session is gone. Refresh Roost.", "Session not found"); redraw(cx); return end
	if session.locked then report(cx, "Unlock the session first.", "Session is locked"); return end
	cx:pick({
		items = {
			{ label = "No, keep it", detail = session.name, answer = false },
			{
				label = if settle then "Yes, settle it" else "Yes, close it",
				detail = session.name .. (if settle then " · ends its programs, keeps it in Settled" else " · ends its programs"),
				answer = true,
			},
		},
		placeholder = (if settle then "Settle session “" else "Close session “") .. session.name .. "”?",
		action = "choose",
	}):next(function(item, _err, nextCx)
		if not nextCx or not item or item.answer ~= true then return end
		local ok, err = pcall(closeNow, nextCx, id, settle)
		if not ok then report(nextCx, err, "Session not closed") end
	end)
end

-- A closed session, wherever it was closed from, goes to Settled.
local function sessionEnded(cx, ev)
	local key = tostring(ev.session)
	if closing[key] then closing[key] = nil; known[key] = nil; lastActive[key] = nil; return end
	local record = known[key]
	known[key] = nil
	lastActive[key] = nil
	activityDirty = true
	if record then
		shelve(record)
		redraw(cx)
	end
end

local function findSettled(sid)
	for index, record in settledList() do
		if record.sid == sid then return record, index end
	end
	return nil
end

local function forgetSettled(cx, sid)
	local list = settledList()
	for index, record in list do
		if record.sid == sid then table.remove(list, index); break end
	end
	tern.kv.set("settled", list)
	redraw(cx)
end

-- Reopens a settled session where it was, running its harness when known.
local function restoreSettled(cx, sid)
	local record = findSettled(sid)
	if not record then redraw(cx); return end
	if not record.cwd then report(cx, "This session had no known folder.", "Cannot restore"); return end
	local command = Harness.launchCommand(record.kind)
	if newSessionIn(cx, record.cwd, command, record.name) then
		forgetSettled(cx, sid)
		cx:toast("info", "Session restored", notificationLabel(record.name))
	end
end

local function pinFolder(cx, path)
	path = Folders.norm(path)
	if string.sub(path, 1, 1) ~= "/" then
		report(cx, "Pick an absolute folder path.", "Folder not pinned")
		return
	end
	local list = records("pinned")
	if table.find(list, path) then
		cx:toast("info", "Already pinned", notificationLabel(Folders.basename(path)))
	else
		table.insert(list, path)
		tern.kv.set("pinned", list)
		cx:toast("info", "Folder pinned", notificationLabel(Folders.basename(path)))
	end
	navigator(cx)
end

local function unpinFolder(cx, path)
	local list = {}
	for _, existing in records("pinned") do
		if Folders.norm(existing) ~= path then table.insert(list, existing) end
	end
	tern.kv.set("pinned", list)
	redraw(cx)
end

local function togglePin(cx, path)
	if table.find(records("pinned"), path) then unpinFolder(cx, path) else pinFolder(cx, path) end
end

local function toggleCollapse(cx, path)
	local collapsed = records("collapsed")
	collapsed[path] = if collapsed[path] then nil else true
	tern.kv.set("collapsed", collapsed)
	redraw(cx)
end

local function reveal(cx, path)
	tern.process.run({ "/usr/bin/open", path }, { timeout_ms = 15000 }, function(result, nextCx)
		if not nextCx or result.status == 0 then return end
		report(nextCx, "Couldn’t open " .. path .. ": " .. ((result.stderr or ""):match("^%s*(.-)%s*$")), "Reveal failed")
	end)
end

-- AppleScript for macOS's native folder picker; the start folder and prompt
-- arrive as arguments, so no path is ever spliced into the script text.
local CHOOSE_FOLDER = {
	"on run argv",
	'POSIX path of (choose folder with prompt (item 2 of argv) default location (POSIX file (item 1 of argv)))',
	"end run",
}

-- Where the picker starts: beside the last folder chosen, else ~/code, else ~.
local function pickerStart()
	local last = tern.kv.get("picker-start")
	if type(last) == "string" and tern.fs.exists(last) then return last end
	local home = tern.getenv("HOME") or "/"
	if tern.fs.exists(home .. "/code") then return home .. "/code" end
	return home
end

-- Opens macOS's folder picker and hands the chosen folder to `done(cx, path)`.
local function chooseFolder(cx, prompt, done)
	if not requireLocal(cx) then return end
	if picking then
		cx:toast("info", "Folder picker already open", "Choose a folder or cancel it.")
		return
	end
	picking = true
	local argv = { "/usr/bin/osascript" }
	for _, line in CHOOSE_FOLDER do
		table.insert(argv, "-e")
		table.insert(argv, line)
	end
	table.insert(argv, pickerStart())
	table.insert(argv, prompt)
	-- The picker waits for the user; give up after 30 minutes untouched.
	tern.process.run(argv, { timeout_ms = 30 * 60 * 1000 }, function(result, nextCx)
		picking = false
		if not nextCx then return end
		if result.status ~= 0 then
			-- Cancel (AppleScript error -128), timeouts, and pickers ended by a
			-- signal (status -1, e.g. a plugin reload) need no message.
			if result.status == -1 or string.find(result.stderr or "", "-128", 1, true) then return end
			report(nextCx, "Couldn't open the folder picker: " .. ((result.stderr or ""):match("^%s*(.-)%s*$")), "Folder picker failed")
			return
		end
		local path = Folders.norm((result.stdout or ""):match("^%s*(.-)%s*$"))
		if path == "" then return end
		tern.kv.set("picker-start", Folders.norm(string.match(path, "^(.*)/[^/]+$") or path))
		done(nextCx, path)
	end)
end

-- Every live session, in the order the panel shows them.
local function allSessions(cx)
	local rows = {}
	local data = viewData(cx)
	local function walk(group)
		for _, session in group.sessions do table.insert(rows, session) end
		for _, child in group.children do walk(child) end
	end
	for _, group in data.groups do walk(group) end
	return rows, data
end

-- Switch to any session: the picker lists each as "name — folder".
local function findSession(cx)
	if not requireLocal(cx) then return end
	local items = {}
	for _, session in allSessions(cx) do
		table.insert(items, { label = session.name .. " — " .. session.where, current = session.current, id = session.id })
	end
	if #items == 0 then return end
	cx:pick({ items = items, placeholder = "Switch to session…", icon = "folder", action = "switch" })
		:next(function(item, _err, nextCx)
			if nextCx and item then switchTo(nextCx, item.id) end
		end)
end

-- A new session in a pinned or in-use folder, or in one you browse to.
local function newSession(cx)
	if not requireLocal(cx) then return end
	local home = tern.getenv("HOME")
	local items = {}
	local _, data = allSessions(cx)
	local function walk(group)
		if not group.other then
			table.insert(items, {
				label = Folders.short(group.path, home), icon = "folder",
				detail = if group.pinned then "pinned" else nil, group = if group.pinned then "Pinned" else "In use",
				path = group.path,
			})
		end
		for _, child in group.children do walk(child) end
	end
	for _, group in data.groups do walk(group) end
	table.insert(items, { label = "Choose folder…", icon = "folder", group = "Browse", choose = true })
	cx:pick({ items = items, placeholder = "New session in…", icon = "folder", action = "open" })
		:next(function(item, _err, nextCx)
			if not nextCx or not item then return end
			if item.choose then
				chooseFolder(nextCx, "Choose a folder for the new session", function(doneCx, path) newSessionIn(doneCx, path) end)
			else
				newSessionIn(nextCx, item.path)
			end
		end)
end

-- ── Worktrees (plain git) ───────────────────────────────────────────────
local function mainRootOf(path)
	local info = gitInfoOf(path)
	if not info then return nil end
	for _, tree in info.worktrees or {} do
		if tree.is_main then return Folders.norm(tree.path) end
	end
	return Folders.norm(info.root or path)
end

local function newWorktreeSession(cx, path)
	local root = mainRootOf(path)
	if not root then report(cx, "This folder is not a repository.", "No worktree"); return end
	cx:prompt({ placeholder = "New branch name", action = "create" }):next(function(answer, _err, nextCx)
		if not nextCx or answer == nil then return end
		local branch = answer:match("^%s*(.-)%s*$")
		if branch == "" then return end
		Git.addWorktree(nextCx, root, branch, function(created, err)
			tern.timer(0, function(freshCx)
				if not freshCx then return end
				if not created then report(freshCx, err or "git worktree add failed", "Worktree not created"); return end
				gitAt = {}
				newSessionIn(freshCx, Folders.norm(created), nil, branch)
				freshCx:toast("info", "Worktree created", notificationLabel(branch))
			end)
		end)
	end)
end

local function removeWorktree(cx, path)
	for key, cwd in sessionCwds(cx) do
		if Folders.within(cwd, path) then
			local session = sessionsById(cx)[key]
			report(cx, "Close or settle “" .. (session and session.name or key) .. "” first.", "Worktree in use")
			return
		end
	end
	local info = gitInfoOf(path)
	if info and info.dirty then report(cx, "It has uncommitted changes.", "Worktree is dirty"); return end
	cx:pick({
		items = {
			{ label = "No, keep it", detail = path, answer = false },
			{ label = "Yes, remove the worktree", detail = "Keeps its branch · " .. path, answer = true },
		},
		placeholder = "Remove worktree " .. Folders.basename(path) .. "?",
		action = "choose",
	}):next(function(item, _err, nextCx)
		if not nextCx or not item or item.answer ~= true then return end
		Git.removeWorktree(nextCx, path, function(ok, err)
			tern.timer(0, function(freshCx)
				if not freshCx then return end
				gitAt = {}
				if ok then
					freshCx:toast("info", "Worktree removed", notificationLabel(Folders.basename(path)))
				else
					report(freshCx, err or "git worktree remove failed", "Worktree not removed")
				end
				redraw(freshCx)
			end)
		end)
	end)
end

tern.command({ id = "toggle", title = "Show or hide Roost", icon = "folder", keys = { "cmd+alt+shift+l" }, run = togglePanel })
tern.command({ id = "find", title = "Roost: Find session", icon = "search", run = findSession })
tern.command({ id = "new", title = "Roost: New session in folder", icon = "folder-plus", run = newSession })
tern.command({ id = "rename", title = "Roost: Rename current session", icon = "rename", run = function(cx)
	renameSession(cx, cx.sessions:current().id)
end })

tern.on("canvas_action", function(ev, cx)
	if not requireLocal(cx) then return true end
	local act, value = ev.act, ev.value
	local path = Folders.unhex(value)
	if act == "find" then findSession(cx)
	elseif act == "new" then newSession(cx)
	elseif act == "add" then
		chooseFolder(cx, "Choose a folder to pin in Roost", pinFolder)
	elseif act == "refresh" then refreshByHand(cx)
	elseif act == "switch" then switchTo(cx, tonumber(value))
	elseif act == "collapse" and path then toggleCollapse(cx, path)
	elseif act == "folder-new" and path then newSessionIn(cx, path)
	elseif act == "folder-omp" and path then newSessionIn(cx, path, "omp")
	elseif act == "reveal" and path then reveal(cx, path)
	elseif act == "pin" and path then togglePin(cx, path)
	elseif act == "pr" and path then cx:open(path)
	elseif act == "settled-toggle" then
		tern.kv.set("settled-open", tern.kv.get("settled-open") ~= true)
		redraw(cx)
	elseif act == "restore" and value then restoreSettled(cx, value)
	-- Menu entries show their action verbatim, so these read as titled.
	elseif act == "Rename" then
		local id = view.sessionId(ev.node)
		if id then renameSession(cx, id) end
	elseif act == "New tab here" then
		local id = view.sessionId(ev.node)
		if id then newTabHere(cx, id) end
	elseif act == "Lock session" or act == "Unlock session" then
		local id = view.sessionId(ev.node)
		if id then setLocked(cx, id, act == "Lock session") end
	elseif act == "Settle" then
		local id = view.sessionId(ev.node)
		if id then closeSession(cx, id, true) end
	elseif act == "Close session" then
		local id = view.sessionId(ev.node)
		if id then closeSession(cx, id, false) end
	elseif act == "Restore" or act == "Forget" then
		local sid = view.settledId(ev.node)
		if sid then
			if act == "Restore" then restoreSettled(cx, sid) else forgetSettled(cx, sid) end
		end
	elseif act == "New session here" or act == "New omp session here" or act == "Reveal in Finder"
		or act == "Pin folder" or act == "Unpin folder" or act == "New worktree session" or act == "Remove worktree" then
		local folder = view.folderPath(ev.node)
		if not folder then return true end
		if act == "New session here" then newSessionIn(cx, folder)
		elseif act == "New omp session here" then newSessionIn(cx, folder, "omp")
		elseif act == "Reveal in Finder" then reveal(cx, folder)
		elseif act == "New worktree session" then newWorktreeSession(cx, folder)
		elseif act == "Remove worktree" then removeWorktree(cx, folder)
		else togglePin(cx, folder) end
	else return false end
	return true
end)

tern.chrome.status(function()
	return { { text = "Roost", icon = "folder", command = "plugin.roost.toggle" } }
end)

-- Every 750 ms: keep the panel in the shown tab, refresh stale repository state
-- and draw what changed (renames and new sessions raise no event). Errors are
-- reported, not raised, so the timer always restarts.
local function tick(cx)
	local ok, err = pcall(function()
		if not localHost(cx) then return end
		follow(cx)
		seedActivity(cx)
		autoName(cx)
		if slot(cx) then
			local data, live = viewData(cx)
			refreshGit(cx, shownPaths(data))
			saveActivity(cx, live)
			redraw(cx)
		end
	end)
	if not ok then
		local text = tostring(err)
		if problem ~= text then report(cx, text) end
	end
	tern.timer(750, tick)
end

tern.on("window_start", function(cx)
	follow(cx)
end)
-- Every tab, pane and focus change moves the panel into the shown tab and
-- draws it; any one of these hooks keeps it following if another is disabled.
local function followAndDraw(cx, tab)
	local ok, err = pcall(function()
		follow(cx, tab)
		draw(cx)
	end)
	if not ok then tern.log.warn("Roost panel: " .. tostring(err)) end
end
tern.on("focus", function(ev, cx)
	pcall(touchPane, cx, ev.pane)
	followAndDraw(cx, ev.tab)
end)
for _, name in { "tab_created", "tab_closed", "pane_created", "pane_closed" } do
	tern.on(name, function(ev, cx)
		if ev and ev.pane then pcall(touchPane, cx, ev.pane) end
		followAndDraw(cx)
	end)
end
local paneCwd = {}
-- Work in a pane stamps its session; a folder or agent change draws soon, off the hook's budget.
for _, name in { "command_started", "command_finished", "title", "cwd", "agent_state" } do
	tern.on(name, function(ev, cx)
		if ev and ev.pane then pcall(touchPane, cx, ev.pane) end
		if name == "cwd" and ev and ev.pane and paneCwd[ev.pane] ~= ev.path then
			-- A real move, not a repeated report: its repository state is stale.
			paneCwd[ev.pane] = ev.path
			gitAt = {}
			redraw(cx)
		elseif name == "agent_state" then
			redraw(cx)
		end
	end)
end
tern.on("session_ended", function(ev, cx)
	local ok, err = pcall(sessionEnded, cx, ev)
	if not ok then tern.log.warn("Roost session_ended: " .. tostring(err)) end
end)
-- The computer's name (shown in tooltips) is read once, off-thread.
Harness.warm(redraw_later)
-- Timers are restarted on reload; window_start intentionally is not.
tern.timer(750, tick)
