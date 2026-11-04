--!nonstrict
local Folders = require("./folders")
local view = require("./view")

local rendered = {}
local problem
-- Whether ↻ is spinning for an explicit refresh.
local spinning = false
local picking = false

local function records(key)
	local value = tern.kv.get(key)
	if value == nil then return {} end
	assert(type(value) == "table", "Sessions storage is invalid: " .. key)
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

-- Agent CLIs recognised in terminals, by program name.
local AGENTS = {
	omp = true, pi = true, claude = true, codex = true, opencode = true, gemini = true,
	aider = true, amp = true, ["cursor-agent"] = true, crush = true, goose = true,
}

-- Whether a shell command line runs an agent CLI, e.g. "omp", "cd x && claude",
-- "FOO=1 /usr/local/bin/codex --resume".
local function runsAgent(line)
	for segment in string.gmatch(line, "[^;&|]+") do
		for word in string.gmatch(segment, "%S+") do
			if not string.find(word, "=", 1, true) then
				if AGENTS[string.match(word, "([^/]+)$")] then return true end
				break
			end
		end
	end
	return false
end

-- Agent activity in this window: "waiting" (it asked you something) or
-- "working", per session id (as a string).
-- Native agent blocks such as omp report their state;
-- their `busy` stays set while they sit idle, so it isn't consulted for them.
-- Agent CLIs in plain terminals only report progress, which Tern exposes as
-- `busy` (a CLI that hasn't reported progress yet counts as busy while it runs).
local function agentActivity(cx)
	local tabSession = {}
	for _, tab in cx.session:tabs() do tabSession[tab.id] = tostring(tab.session) end
	local sessions = {}
	local function mark(tab, state)
		-- Waiting wins: it is the state that needs you.
		local session = tabSession[tab] or ""
		if sessions[session] ~= "waiting" then sessions[session] = state end
	end
	local seen = {}
	for _, agent in cx.agents:list() do
		local state = if agent.state == "waiting_input" then "waiting"
			elseif agent.state == "working" then "working"
			else nil
		local info = state and cx.session:pane(agent.pane)
		if info and info.tab then
			seen[agent.pane] = true
			mark(info.tab, state)
		end
	end
	for _, pane in cx.session:panes() do
		if pane.kind ~= "agent" and not seen[pane.pane] and pane.busy and pane.running
			and pane.tab and runsAgent(pane.running.line) then
			mark(pane.tab, "working")
		end
	end
	return sessions
end

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

-- Folders → sessions. Pinned folders come first, in the order pinned, and stay
-- even when empty; a session lives under the deepest pinned folder holding its
-- directory, else under its own directory. The rest follow by session count,
-- then name; sessions with no known directory close the list under "Other".
local function model(cx)
	local home = tern.getenv("HOME")
	local current = cx.sessions:current()
	local activity = agentActivity(cx)
	local cwds = sessionCwds(cx)
	local collapsed = records("collapsed")
	local pinned = {}
	for _, path in records("pinned") do
		local norm = Folders.norm(path)
		if norm ~= "" and not table.find(pinned, norm) then table.insert(pinned, norm) end
	end
	local groups, byPath = {}, {}
	local function group(path)
		local entry = byPath[path]
		if not entry then
			local other = path == Folders.OTHER
			local prefix, name = "", path
			if not other then prefix, name = Folders.parts(path, home) end
			entry = {
				path = path, prefix = prefix, name = name, other = other,
				pinned = table.find(pinned, path) ~= nil, order = table.find(pinned, path) or 0,
				collapsed = collapsed[path] == true, sessions = {},
			}
			byPath[path] = entry
			table.insert(groups, entry)
		end
		return entry
	end
	for _, path in pinned do group(path) end
	local total = 0
	for _, session in cx.sessions:list() do
		if session.host == current.host then
			total += 1
			local cwd = cwds[tostring(session.id)]
			local entry = group(if cwd then Folders.owner(cwd, pinned) else Folders.OTHER)
			local sub = if cwd and cwd ~= entry.path then Folders.relative(cwd, entry.path) else nil
			table.insert(entry.sessions, {
				id = session.id, name = session.name, tabs = session.tabs, locked = session.locked,
				current = session.current, agent = activity[tostring(session.id)],
				where = if cwd then Folders.short(cwd, home) else Folders.OTHER, sub = sub,
			})
		end
	end
	for _, entry in groups do
		table.sort(entry.sessions, function(a, b)
			local x, y = string.lower(a.name), string.lower(b.name)
			if x ~= y then return x < y end
			return a.id < b.id
		end)
	end
	table.sort(groups, function(a, b)
		if a.pinned ~= b.pinned then return a.pinned end
		if a.pinned then return a.order < b.order end
		if a.other ~= b.other then return b.other end
		if #a.sessions ~= #b.sessions then return #a.sessions > #b.sessions end
		local x, y = string.lower(a.name), string.lower(b.name)
		if x ~= y then return x < y end
		return a.path < b.path
	end)
	return { groups = groups, total = total, spinning = spinning }
end

local NAVIGATOR = {
	title = "Sessions",
	about = "Every Tern session, grouped by working folder. Click a session to switch to it; "
		.. "right-click one to rename it, open a tab in it, lock it or close it.",
}

local function isNavigator(canvas)
	return canvas.owner == tern.plugin.id and canvas.title == NAVIGATOR.title
end

-- Other plugins' panels that also hug a tab's left edge. Two panels each
-- insisting on being first would swap places forever, so Sessions sits behind
-- them. Canvas owner → title.
local RAILS = { overseer = "Projects" }

local function rails(cx)
	local set = {}
	for _, canvas in cx.canvas:list() do
		if RAILS[canvas.owner] == canvas.title then set[canvas.pane] = true end
	end
	return set
end

-- The window's one Sessions panel: its canvas. Adopts what a reload left open
-- and closes any extra, so a window never shows two.
local slotPane = nil
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

local function draw(cx)
	local pane = slot(cx)
	if not pane then return end
	-- A just-opened canvas only accepts updates once canvas:list() reports it.
	local ready = false
	for _, canvas in cx.canvas:list() do
		if canvas.pane == pane then ready = true end
	end
	if not ready then return end
	local data = model(cx)
	local signature = tern.json.encode(data)
	if rendered[pane] == signature then return end
	cx.canvas:set(pane, { view = view.render(data) })
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

-- Tern panes belong to one tab, so the window's one Sessions panel follows you:
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
	local data = model(cx)
	local pane, err = cx.canvas:open({
		title = NAVIGATOR.title, about = NAVIGATOR.about,
		view = view.render(data), how = "beside", focus = false,
	})
	if not pane then report(cx, err or "Could not open the Sessions panel"); return nil end
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

-- Shows the Sessions panel in the shown tab and focuses it, opening it if needed.
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
	redraw(cx)
	tern.timer(SPIN_MIN_MS, function(nextCx)
		spinning = false
		if nextCx then redraw(nextCx) end
	end)
end

local function switchTo(cx, id)
	if not sessionsById(cx)[tostring(id)] then
		report(cx, "Session is gone. Refresh Sessions.", "Session not found")
		redraw(cx)
		return
	end
	local ok, err = pcall(function() cx.sessions:switch(id) end)
	if not ok then report(cx, err, "Switch failed"); return end
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

-- A new session named after the folder, its first tab there. With `command`
-- the first tab runs it instead of a shell.
local function newSessionIn(cx, path, command)
	if not requireLocal(cx) then return end
	if not tern.fs.exists(path) then
		report(cx, "Folder is missing: " .. path, "Folder unavailable")
		redraw(cx)
		return
	end
	local ok, err = pcall(function()
		local session = cx.sessions:create({ name = Folders.basename(path), cwd = path })
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
end

local function newTabHere(cx, id)
	local session = sessionsById(cx)[tostring(id)]
	if not session then report(cx, "Session is gone. Refresh Sessions.", "Session not found"); redraw(cx); return end
	local cwd = sessionCwds(cx)[tostring(id)]
	local ok, err = pcall(function()
		if not session.current then cx.sessions:switch(id) end
		cx.layout:new_tab(tabLaunch(cx, cwd))
	end)
	if not ok then report(cx, err, "Tab not opened") end
	follow(cx)
	redraw(cx)
end

local function renameSession(cx, id)
	local session = sessionsById(cx)[tostring(id)]
	if not session then report(cx, "Session is gone. Refresh Sessions.", "Session not found"); redraw(cx); return end
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

local function setLocked(cx, id, locked)
	local ok, err = pcall(function()
		if locked then cx.sessions:lock(id) else cx.sessions:unlock(id) end
	end)
	if not ok then report(cx, err, "Lock failed") end
	redraw(cx)
end

-- Closing the shown session takes the panel with it, so land in another
-- session first and bring the panel along.
local function closeNow(cx, id)
	local sessions = cx.sessions:list()
	local target = sessionsById(cx)[tostring(id)]
	if not target then redraw(cx); return end
	if target.locked then report(cx, "Unlock the session first.", "Session is locked"); return end
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
	cx:toast("info", "Session closed", notificationLabel(target.name))
	redraw(cx)
end

local function closeSession(cx, id)
	local session = sessionsById(cx)[tostring(id)]
	if not session then report(cx, "Session is gone. Refresh Sessions.", "Session not found"); redraw(cx); return end
	if session.locked then report(cx, "Unlock the session first.", "Session is locked"); return end
	cx:pick({
		items = {
			{ label = "No, keep it", detail = session.name, answer = false },
			{ label = "Yes, close it", detail = session.name .. " · ends its programs", answer = true },
		},
		placeholder = "Close session “" .. session.name .. "”?",
		action = "choose",
	}):next(function(item, _err, nextCx)
		if not nextCx or not item or item.answer ~= true then return end
		local ok, err = pcall(closeNow, nextCx, id)
		if not ok then report(nextCx, err, "Session not closed") end
	end)
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

-- Switch to any session: the picker lists each as "name — folder".
local function findSession(cx)
	if not requireLocal(cx) then return end
	local items = {}
	for _, group in model(cx).groups do
		for _, session in group.sessions do
			table.insert(items, { label = session.name .. " — " .. session.where, current = session.current, id = session.id })
		end
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
	for _, group in model(cx).groups do
		if not group.other then
			table.insert(items, {
				label = Folders.short(group.path, home), icon = "folder",
				detail = if group.pinned then "pinned" else nil, group = if group.pinned then "Pinned" else "In use",
				path = group.path,
			})
		end
	end
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

tern.command({ id = "toggle", title = "Show or hide Sessions", icon = "folder", keys = { "cmd+alt+shift+l" }, run = togglePanel })
tern.command({ id = "find", title = "Find session", icon = "folder", run = findSession })
tern.command({ id = "new", title = "New session in folder", icon = "folder", run = newSession })
tern.command({ id = "rename", title = "Rename current session", icon = "rename", run = function(cx)
	renameSession(cx, cx.sessions:current().id)
end })

tern.on("canvas_action", function(ev, cx)
	if not requireLocal(cx) then return true end
	local act, value = ev.act, ev.value
	local path = Folders.unhex(value)
	if act == "find" then findSession(cx)
	elseif act == "new" then newSession(cx)
	elseif act == "add" then
		chooseFolder(cx, "Choose a folder to pin in Sessions", pinFolder)
	elseif act == "refresh" then refreshByHand(cx)
	elseif act == "switch" then switchTo(cx, tonumber(value))
	elseif act == "collapse" and path then toggleCollapse(cx, path)
	elseif act == "folder-new" and path then newSessionIn(cx, path)
	elseif act == "folder-omp" and path then newSessionIn(cx, path, "omp")
	elseif act == "reveal" and path then reveal(cx, path)
	elseif act == "pin" and path then togglePin(cx, path)
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
	elseif act == "Close session" then
		local id = view.sessionId(ev.node)
		if id then closeSession(cx, id) end
	elseif act == "New session here" or act == "New omp session here" or act == "Reveal in Finder"
		or act == "Pin folder" or act == "Unpin folder" then
		local folder = view.folderPath(ev.node)
		if not folder then return true end
		if act == "New session here" then newSessionIn(cx, folder)
		elseif act == "New omp session here" then newSessionIn(cx, folder, "omp")
		elseif act == "Reveal in Finder" then reveal(cx, folder)
		else togglePin(cx, folder) end
	else return false end
	return true
end)

tern.chrome.status(function()
	return { { text = "Sessions", icon = "folder", command = "plugin.session-folders.toggle" } }
end)

-- Every 750 ms: keep the panel in the shown tab and draw what changed since
-- (renames and new sessions raise no event). Errors are reported, not raised,
-- so the timer always restarts.
local function tick(cx)
	local ok, err = pcall(function()
		if not localHost(cx) then return end
		follow(cx)
		redraw(cx)
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
	if not ok then tern.log.warn("Sessions panel: " .. tostring(err)) end
end
tern.on("focus", function(ev, cx) followAndDraw(cx, ev.tab) end)
for _, name in { "tab_created", "tab_closed", "pane_created", "pane_closed" } do
	tern.on(name, function(_ev, cx) followAndDraw(cx) end)
end
-- A folder, an agent or a session changed: draw soon, off the hook's budget.
for _, name in { "cwd", "agent_state", "session_ended" } do
	tern.on(name, function(_ev, cx) redraw(cx) end)
end
-- Timers are restarted on reload; window_start intentionally is not.
tern.timer(750, tick)
