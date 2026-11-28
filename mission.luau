-- Mission control: a Tern tab over the VinhLam Board. The Board's lead splits each goal posted to
-- <project>/build into worker and reviewer tasks; this tab posts goals, shows tasks as a Kanban board
-- (one project or all) and answers what waits for you. Everything goes through the Board CLI (`vb`)
-- in the Board folder.
local Badge = require("./badge")
local ui = tern.ui
local Mission = {}

Mission.TITLE = "Mission control"
local ABOUT = "Goals, tasks and decisions on the VinhLam Board. New goal posts to a project's build channel, "
	.. "where the lead plans it; Answer replies in a decision's thread; Open shows a thread as a note."
local REFRESH_MS = 30000

-- tasks: open tasks everywhere; recent: each project's latest build threads (for Done); names: projects.
local data = { tasks = nil, recent = {}, names = nil, error = nil, loading = false, at = 0, updated = nil }
local hooks = {} -- set by window.luau: report(cx, text, title), chooseFolder(cx, prompt, done)

function Mission.setup(fns)
	hooks = fns
end

local function trim(text)
	return (string.match(text or "", "^%s*(.-)%s*$"))
end

local function firstLine(text)
	return trim(string.match(text or "", "^%s*([^\n]*)"))
end

local function boardDir()
	local saved = tern.kv.get("board-dir")
	if type(saved) == "string" and saved ~= "" then return saved end
	return (tern.getenv("HOME") or "") .. "/Developer/vinhlam-board"
end

local function nodePath()
	for _, path in { "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node" } do
		if tern.fs.exists(path) then return path end
	end
	return nil
end

-- Runs `vb args…` in the Board folder (its Vercel link picks the board); `done(stdout, err, cx)`.
local function vb(args, stdin, done)
	local dir = boardDir()
	local entry = dir .. "/node_modules/.bin/vb"
	local node = nodePath()
	if not node then done(nil, "Node.js not found in /opt/homebrew/bin or /usr/local/bin.") return end
	if not tern.fs.exists(entry) then done(nil, "Board CLI not found in " .. dir .. ". Run npm install there, or choose the Board folder.") return end
	local argv = { node, entry }
	for _, arg in args do table.insert(argv, arg) end
	tern.process.run(argv, { cwd = dir, stdin = stdin, timeout_ms = 60000 }, function(result, cx)
		if result.status ~= 0 then
			local why = trim(if result.stderr ~= "" then result.stderr else result.stdout)
			done(nil, if why ~= "" then why else "vb exited " .. result.status, cx)
		else
			done(result.stdout, nil, cx)
		end
	end)
end

-- Decision options the lead writes as "A — what happens" lines.
function Mission.options(text)
	local found = {}
	for line in string.gmatch(text or "", "[^\n]+") do
		local key, rest = string.match(line, "^%s*(%S+)%s+—%s+(.+)$")
		if key and #found < 4 and #key <= 4 then table.insert(found, { key = key, label = trim(rest) }) end
	end
	return found
end

-- Kanban columns, left to right; a task's Board state picks its column, canceled ones show nowhere.
local COLUMNS = {
	{ id = "you", title = "Needs you", tone = "bad" },
	{ id = "todo", title = "Todo", tone = "warn" },
	{ id = "working", title = "Working", tone = "warn" },
	{ id = "waiting", title = "Waiting", tone = "warn" },
	{ id = "done", title = "Done", tone = "ok" },
}
local COLUMN_OF = { blocked = "you", failed = "you", ready = "todo", claimed = "working", waiting = "waiting", completed = "done" }
local DONE_SHOWN = 12

local function rowOf(item)
	local message = item.message or {}
	local labels = message.labels or {}
	local task = message.task or {}
	local channel = message.channel or "?"
	local blocked = if type(task.blocked) == "table" then task.blocked else nil
	local decision = string.sub(channel, -10) == "/decisions" or labels.role == "decision"
	return {
		id = message.id, title = firstLine(message.text), state = task.state or labels["board.task"] or "?",
		project = string.match(channel, "^([^/]+)/") or channel, role = labels.role, lane = labels.lane,
		decision = decision, at = (item.last and item.last.createdAt) or message.createdAt or "",
		last = item.last and string.gsub(firstLine(item.last.text), "^%[[^%]]*%]%s*", "") or nil,
		reason = blocked and (blocked.reason or blocked.kind) or task.reason,
		options = if decision then Mission.options(message.text) else {},
	}
end

-- Rows by column for `filter` (a project name, nil = all) and every project's counts, most urgent first.
function Mission.model(tasks, recent, names, filter)
	local seen, rows = {}, {}
	local function add(item)
		local row = rowOf(item)
		if row.id and not seen[row.id] then
			seen[row.id] = true
			table.insert(rows, row)
		end
	end
	for _, item in tasks or {} do add(item) end
	for _, threads in recent or {} do for _, item in threads do add(item) end end
	local columns, counts = {}, {}
	for _, column in COLUMNS do columns[column.id] = {} end
	for _, name in names or {} do counts[name] = { open = 0, you = 0 } end
	for _, row in rows do
		local column = if row.decision and row.state ~= "completed" and row.state ~= "canceled" then "you" else COLUMN_OF[row.state]
		if column then
			local count = counts[row.project]
			if not count then
				count = { open = 0, you = 0 }
				counts[row.project] = count
			end
			if column ~= "done" then count.open += 1 end
			if column == "you" then count.you += 1 end
			if filter == nil or filter == row.project then table.insert(columns[column], row) end
		end
	end
	table.sort(columns.done, function(a, b) return a.at > b.at end)
	local projects = {}
	for name, count in counts do table.insert(projects, { name = name, open = count.open, you = count.you }) end
	table.sort(projects, function(a, b)
		if a.you ~= b.you then return a.you > b.you end
		if a.open ~= b.open then return a.open > b.open end
		return a.name < b.name
	end)
	return { columns = columns, projects = projects }
end

local function text(key, value, role, props)
	props = props or {}
	props.key, props.text, props.role = key, value, role
	return ui.node("text", props)
end

local function button(key, label, action, title, variant)
	return ui.button(label, { key = key, size = "sm", variant = variant or "quiet", title = title or label, actions = { click = action } })
end

-- Board task states as coloured pills, after pi-emphasis: red = wrong, yellow = look here, green = settled.
local STATES = {
	failed = { "✗ Failed", "bad" }, blocked = { "■ Blocked", "bad" },
	waiting = { "◷ Waiting", "warn" }, claimed = { "◐ In progress", "warn" }, open = { "○ Todo", "warn" },
	ready = { "● Ready", "ok" }, completed = { "✓ Done", "ok" }, canceled = { "– Canceled", "dim" },
}

local function card(row, showProject)
	local state = STATES[row.state] or { row.state, "dim" }
	local kind = (if row.role == "epic" then "goal" else row.role or "task") .. (if row.lane then " · " .. row.lane else "")
	local pills = { text("state", state[1], "roost.missionPill", { mark = state[2], title = "Board state: " .. row.state }) }
	if showProject then table.insert(pills, text("project", row.project, Badge.role(row.project), { title = "Project " .. row.project })) end
	table.insert(pills, text("kind", kind, "roost.missionPill", { mark = if row.decision then "warn" else "kind" }))
	local children = {
		ui.node("row", { key = "pills", role = "roost.missionHead" }, pills),
		text("title", row.title, "roost.missionTitle"),
	}
	if row.reason and (row.state == "blocked" or row.state == "failed") then table.insert(children, text("reason", row.reason, "roost.hint")) end
	if row.role == "epic" and row.last then table.insert(children, text("last", "Lead: " .. row.last, "roost.hint")) end
	local selected = data.selected == row.id
	return ui.node("col", {
		key = "t" .. string.gsub(row.id, "%W", ""), role = "roost.missionRow", mark = if selected then "pick" else state[2],
		title = "Show this thread and its actions", actions = { click = "mission-select=" .. row.id },
	}, children)
end

local function needsYou(row)
	return row.state == "blocked" or row.state == "failed" or (row.decision and row.state ~= "completed" and row.state ~= "canceled")
end

local function stamp(iso)
	local month, day, hour, minute = string.match(iso or "", "^%d+%-(%d+)%-(%d+)T(%d+):(%d+)")
	return if month then day .. "/" .. month .. " " .. hour .. ":" .. minute .. " UTC" else ""
end

-- The sub-panel beside the board: the selected task's actions, then its whole thread.
local function detail(row)
	local state = STATES[row.state] or { row.state, "dim" }
	local kind = (if row.role == "epic" then "goal" else row.role or "task") .. (if row.lane then " · " .. row.lane else "")
	local id = row.id
	local actions = { button("reply", "Reply…", "mission-answer=" .. id, "Write a reply in this thread", "default") }
	if needsYou(row) then
		for index, option in row.options do
			table.insert(actions, button("o" .. index, option.key .. " — " .. option.label, "mission-answer=" .. id .. "|" .. option.key, "Reply " .. option.key))
		end
	end
	if row.state == "blocked" then table.insert(actions, button("unblock", "Unblock", "mission-task=unblock|" .. id, "Lift the hold: ready again")) end
	if row.state == "failed" then table.insert(actions, button("reopen", "Reopen", "mission-task=reopen|" .. id, "Make it ready again")) end
	if row.state ~= "completed" and row.state ~= "canceled" then
		table.insert(actions, button("cancel", "Cancel…", "mission-task=cancel|" .. id, "Cancel the task, with a reason"))
	end
	table.insert(actions, button("note", "As note", "mission-open=" .. id, "Open the thread as a note"))
	local children = {
		ui.node("row", { key = "head", role = "roost.missionHead" }, {
			text("state", state[1], "roost.missionPill", { mark = state[2] }),
			text("project", row.project, Badge.role(row.project)),
			text("kind", kind, "roost.missionPill", { mark = if row.decision then "warn" else "kind", grow = 1 }),
			ui.button("", { key = "x", icon = "x", size = "sm", variant = "quiet", title = "Close details", aria = "Close details", actions = { click = "mission-select=" } }),
		}),
		text("title", row.title, "roost.detailTitle"),
	}
	if row.reason then table.insert(children, text("reason", row.reason, "roost.hint")) end
	table.insert(children, ui.node("row", { key = "actions", role = "roost.missionAnswers" }, actions))
	local thread = data.thread
	if thread and thread.id == id then
		local messages = {}
		if thread.message then table.insert(messages, thread.message) end
		for _, message in thread.replies or {} do table.insert(messages, message) end
		table.insert(children, text("count", #messages .. " messages, newest last", "roost.sub"))
		for index, message in messages do
			local author = message.author and (message.author.name or message.author.handle) or "?"
			table.insert(children, ui.node("col", { key = "m" .. index, role = "roost.missionMsg" }, {
				text("who", author .. " · " .. stamp(message.createdAt), "roost.sub"),
				text("body", trim(message.text), "roost.missionBody"),
			}))
		end
	else
		table.insert(children, text("loading", data.threadError or "Reading the thread…", "roost.hint"))
	end
	return ui.node("col", { key = "detail", role = "roost.missionDetail" }, children)
end

local function columnNode(column, rows, showProject)
	local children = {
		ui.node("row", { key = "head", role = "roost.kanbanHead" }, {
			text("title", column.title, "roost.kanbanTitle", { mark = column.tone, grow = 1 }),
			text("count", tostring(#rows), "roost.count"),
		}),
	}
	local shown = if column.id == "done" then math.min(#rows, DONE_SHOWN) else #rows
	for index = 1, shown do table.insert(children, card(rows[index], showProject)) end
	if #rows == 0 then table.insert(children, text("none", "Nothing here.", "roost.hint")) end
	if #rows > shown then table.insert(children, text("more", "+" .. (#rows - shown) .. " older", "roost.hint")) end
	return ui.node("col", { key = "c" .. column.id, role = "roost.kanbanCol" }, children)
end

local function currentFilter()
	local saved = tern.kv.get("mission-filter")
	return if type(saved) == "string" and saved ~= "" then saved else nil
end

-- One chip per project, the busiest first, so many projects stay one click away.
local function projectBar(projects, filter)
	local total = 0
	for _, project in projects do total += project.open end
	local chips = { button("fall", "All · " .. total, "mission-filter=*", "Every project", if filter == nil then "default" else nil) }
	for _, project in projects do
		local label = project.name .. " · " .. project.open .. (if project.you > 0 then " · " .. project.you .. " need you" else "")
		table.insert(chips, button("f" .. string.gsub(project.name, "%W", ""), label, "mission-filter=" .. project.name,
			"Only " .. project.name, if filter == project.name then "default" else nil))
	end
	return ui.node("row", { key = "filter", role = "roost.missionFilter" }, chips)
end

function Mission.render()
	local children = {
		ui.node("row", { key = "header", role = "roost.header" }, {
			ui.node("row", { key = "titleGroup", role = "roost.titleGroup", grow = 1 }, {
				text("title", Mission.TITLE, "roost.heading"),
				text("updated", if data.updated then "Updated " .. data.updated else "", "roost.sub", { title = "Refreshes every 30 s" }),
			}),
			button("goal", "New goal", "mission-goal", "Post a goal to a project; the lead plans it"),
			ui.button("", {
				key = "refresh", icon = "refresh", size = "sm", variant = "quiet", busy = data.loading,
				title = if data.loading then "Refreshing…" else "Refresh", aria = "Refresh", actions = { click = "mission-refresh" },
			}),
			ui.button("", {
				key = "close", icon = "x", size = "sm", variant = "quiet",
				title = "Close Mission control", aria = "Close Mission control", actions = { click = "mission-close" },
			}),
		}),
	}
	if data.error then
		table.insert(children, text("error", data.error, "roost.hint"))
		table.insert(children, button("dir", "Choose Board folder", "mission-dir", "The folder holding the vinhlam-board checkout"))
	end
	if data.tasks then
		local filter = currentFilter()
		local model = Mission.model(data.tasks, data.recent, data.names, filter)
		table.insert(children, projectBar(model.projects, filter))
		local columns, selected = {}, nil
		for _, column in COLUMNS do
			table.insert(columns, columnNode(column, model.columns[column.id], filter == nil))
			for _, row in model.columns[column.id] do if row.id == data.selected then selected = row end end
		end
		local board = { ui.node("row", { key = "kanban", role = "roost.kanban", grow = 1 }, columns) }
		if selected then table.insert(board, detail(selected)) end
		table.insert(children, ui.node("row", { key = "board", role = "roost.missionBoard" }, board))
	elseif not data.error then
		table.insert(children, text("loading", "Reading the Board…", "roost.hint"))
	end
	return ui.node("col", { key = "mission", role = "roost.panel" }, children)
end

local function pane(cx)
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == Mission.TITLE then return canvas.pane end
	end
	return nil
end

local function draw(cx)
	local found = pane(cx)
	if found then cx.canvas:set(found, { view = Mission.render() }) end
end

local function decode(out)
	local ok, decoded = pcall(tern.json.decode, out or "")
	return if ok and type(decoded) == "table" then decoded else nil
end

-- Reads the selected task's whole thread into the sub-panel.
local function loadThread(cx, id)
	vb({ "read", id, "--json" }, nil, function(out, err, nextCx)
		if data.selected ~= id then return end
		local decoded = decode(out)
		if decoded then
			decoded.id, data.thread, data.threadError = id, decoded, nil
		else
			data.threadError = err or "Could not read the thread."
		end
		pcall(draw, nextCx or cx)
	end)
end

-- Open tasks everywhere, the project list, then the latest build threads of the projects on show (for
-- Done: `vb tasks` lists only open tasks, oldest first). Draws once every call has answered.
function Mission.refresh(cx)
	if data.loading then return end
	data.loading = true
	draw(cx)
	local filter, pending, lastCx = currentFilter(), 2, cx
	if data.selected then loadThread(cx, data.selected) end
	local function finish(nextCx)
		lastCx = nextCx or lastCx
		pending -= 1
		if pending > 0 then return end
		data.loading, data.at = false, tern.now()
		if hooks.changed then hooks.changed() end
		local ok, stamp = pcall(os.date, "%H:%M")
		if ok then data.updated = stamp end
		pcall(draw, lastCx)
	end
	vb({ "tasks", "--json", "-n", "200" }, nil, function(out, err, nextCx)
		local decoded = decode(out)
		if decoded then
			data.tasks, data.error = decoded.tasks or {}, nil
		else
			data.error = err or "The Board CLI answered something unexpected."
		end
		finish(nextCx)
	end)
	vb({ "channels", "list", "--json" }, nil, function(out, _err, nextCx)
		local decoded = decode(out)
		if decoded then
			local names = {}
			for _, channel in decoded.channels or {} do
				local name = string.match(channel.path or "", "^(.+)/build$")
				if name then table.insert(names, name) end
			end
			data.names = names
		end
		for _, name in (if filter then { filter } else data.names or {}) do
			pending += 1
			vb({ "read", name .. "/build", "-n", "25", "--json" }, nil, function(readOut, _e, readCx)
				local threads = decode(readOut)
				if threads then data.recent[name] = threads.threads or {} end
				finish(readCx)
			end)
		end
		finish(nextCx)
	end)
end

function Mission.open(cx)
	local found = pane(cx)
	if found then
		pcall(function() cx.layout:focus(found) end)
	else
		local opened, err = cx.canvas:open({ title = Mission.TITLE, about = ABOUT, view = Mission.render(), how = "tab" })
		if not opened then hooks.report(cx, "Mission control did not open: " .. tostring(err), "Mission control") return end
	end
	Mission.refresh(cx)
end

function Mission.isOpen(cx)
	return pane(cx) ~= nil
end

-- Header button, close button and palette command: closes the tab when it is open, opens it otherwise.
function Mission.toggle(cx)
	local found = pane(cx)
	if found then cx.layout:close(found) else Mission.open(cx) end
end

-- Open and needing-you task counts per Board project from the last read, keyed by lower-case name
-- ({ name, open, you }); Roost's project headers show them.
local countsOf, countsCache = nil, {}
function Mission.counts()
	if data.tasks ~= countsOf then
		countsOf, countsCache = data.tasks, {}
		for _, project in Mission.model(data.tasks, nil, nil, nil).projects do
			countsCache[string.lower(project.name)] = project
		end
	end
	return countsCache
end

-- Called from Roost's tick: refreshes an open tab every REFRESH_MS. With the tab closed and
-- `wantCounts` (Roost has projects), reads open tasks alone, half as often, for those counts.
function Mission.tick(cx, wantCounts)
	if data.loading then return end
	if pane(cx) then
		if tern.now() - data.at > REFRESH_MS then Mission.refresh(cx) end
	elseif wantCounts and tern.now() - (data.polled or 0) > REFRESH_MS * 2 then
		data.polled = tern.now()
		vb({ "tasks", "--json", "-n", "200" }, nil, function(out)
			local decoded = decode(out)
			if decoded then
				data.tasks = decoded.tasks or {}
				if hooks.changed then hooks.changed() end
			end
		end)
	end
end

local function reply(cx, id, answer)
	vb({ "reply", id, "-" }, answer, function(_, err, nextCx)
		nextCx = nextCx or cx
		if err then hooks.report(nextCx, err, "Answer not sent") return end
		nextCx:toast("info", "Answer sent", "The lead picks it up on its next turn.")
		if data.selected == id then loadThread(nextCx, id) end
		Mission.refresh(nextCx)
	end)
end

-- Unblock, reopen or cancel (with a reason) a task you own: `vb tasks <verb> <id> [reason]`.
local function taskVerb(cx, verb, id, reason)
	local args = { "tasks", verb, id }
	if reason then table.insert(args, reason) end
	vb(args, nil, function(_, err, nextCx)
		nextCx = nextCx or cx
		if err then hooks.report(nextCx, err, "Task not changed") return end
		nextCx:toast("info", "Task " .. (if verb == "cancel" then "canceled" elseif verb == "unblock" then "unblocked" else "reopened"), "")
		data.at = 0
		if data.selected == id then loadThread(nextCx, id) end
		Mission.refresh(nextCx)
	end)
end

local function newGoal(cx)
	vb({ "channels", "list", "--json" }, nil, function(out, err, nextCx)
		nextCx = nextCx or cx
		local ok, decoded = pcall(tern.json.decode, out or "")
		if err or not ok then hooks.report(nextCx, err or "Could not read the Board's projects.", "New goal") return end
		local last, items = currentFilter() or tern.kv.get("mission-project"), {}
		for _, channel in decoded.channels or {} do
			local name = string.match(channel.path or "", "^(.+)/build$")
			if name then table.insert(items, { label = name, project = name, current = name == last }) end
		end
		if #items == 0 then hooks.report(nextCx, "The Board has no <project>/build channel.", "New goal") return end
		nextCx:pick({ items = items, placeholder = "Goal for which project?", icon = "folder", action = "choose" })
			:next(function(item, _err, pickCx)
				if not pickCx or not item then return end
				tern.kv.set("mission-project", item.project)
				pickCx:prompt({ placeholder = "Goal for " .. item.project .. " (the lead splits it into tasks)", action = "post" })
					:next(function(answer, _e, promptCx)
						local goal = trim(answer)
						if not promptCx or goal == "" then return end
						vb({ "post", item.project .. "/build", "-" }, goal, function(_, postErr, postCx)
							postCx = postCx or promptCx
							if postErr then hooks.report(postCx, postErr, "Goal not posted") return end
							postCx:toast("info", "Goal posted to " .. item.project, "The lead plans it on its next turn.")
							Mission.refresh(postCx)
						end)
					end)
			end)
	end)
end

local function openThread(cx, id)
	vb({ "read", id, "--json" }, nil, function(out, err, nextCx)
		nextCx = nextCx or cx
		local ok, decoded = pcall(tern.json.decode, out or "")
		if err or not ok or type(decoded) ~= "table" then hooks.report(nextCx, err or "Could not read the thread.", "Open failed") return end
		local parts = {}
		local function add(message)
			local author = message.author and (message.author.name or message.author.handle) or "?"
			table.insert(parts, "**" .. author .. "** · " .. tostring(message.createdAt or "") .. "\n\n" .. (message.text or ""))
		end
		if decoded.message then add(decoded.message) end
		for _, message in decoded.replies or {} do add(message) end
		local title = decoded.message and firstLine(decoded.message.text) or id
		nextCx.docs:new_note(string.sub(title, 1, 80), table.concat(parts, "\n\n---\n\n"))
	end)
end

-- Handles a click in the Mission control tab; returns true when it was one.
function Mission.action(ev, cx)
	local act, value = ev.act, ev.value
	if act == "mission-refresh" then
		Mission.refresh(cx)
	elseif act == "mission-filter" and value then
		tern.kv.set("mission-filter", if value == "*" then "" else value)
		data.at = 0 -- a refresh already running leaves this one to the next tick
		draw(cx)
		Mission.refresh(cx)
	elseif act == "mission-select" then
		-- Clicking the selected card again, or the sub-panel's ✕, closes the sub-panel.
		local id = if value and value ~= "" and value ~= data.selected then value else nil
		data.selected, data.thread, data.threadError = id, nil, nil
		draw(cx)
		if id then loadThread(cx, id) end
	elseif act == "mission-task" and value then
		local verb, id = string.match(value, "^(%a+)|(.+)$")
		if verb == "cancel" then
			cx:prompt({ placeholder = "Why cancel it? (sent with the cancel)", action = "cancel task" }):next(function(reason, _e, nextCx)
				if nextCx and trim(reason) ~= "" then taskVerb(nextCx, verb, id, trim(reason)) end
			end)
		elseif verb then
			taskVerb(cx, verb, id)
		end
	elseif act == "mission-close" then
		Mission.toggle(cx)
	elseif act == "mission-goal" then
		newGoal(cx)
	elseif act == "mission-open" and value then
		openThread(cx, value)
	elseif act == "mission-answer" and value then
		local id, key = string.match(value, "^([^|]+)|(.+)$")
		if id then
			reply(cx, id, key)
		else
			cx:prompt({ placeholder = "Your answer", action = "send" }):next(function(answer, _e, nextCx)
				if nextCx and trim(answer) ~= "" then reply(nextCx, value, trim(answer)) end
			end)
		end
	elseif act == "mission-dir" then
		hooks.chooseFolder(cx, "Choose the vinhlam-board folder", function(doneCx, path)
			tern.kv.set("board-dir", path)
			Mission.refresh(doneCx)
		end)
	else
		return false
	end
	return true
end

do -- columns, dedupe (open task wins over its older read), filter and project order
	local function item(id, channel, state, at) return { message = { id = id, channel = channel, task = { state = state }, createdAt = at } } end
	local open = { item("a", "p/build", "claimed", "1"), item("b", "q/decisions", "blocked", "2") }
	local recent = { p = { item("a", "p/build", "completed", "1"), item("c", "p/build", "completed", "3"), item("d", "p/build", "canceled", "4") } }
	local all = Mission.model(open, recent, { "p", "q", "r" }, nil)
	assert(#all.columns.working == 1 and #all.columns.you == 1 and #all.columns.done == 1 and all.columns.done[1].id == "c")
	assert(all.projects[1].name == "q" and all.projects[2].name == "p" and all.projects[3].open == 0)
	local only = Mission.model(open, recent, nil, "q")
	assert(#only.columns.you == 1 and #only.columns.working == 0 and #only.columns.done == 0)
end

return Mission
