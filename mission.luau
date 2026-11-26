-- Mission control: a Tern tab over the VinhLam Board. The Board's lead splits each goal posted to
-- <project>/build into worker and reviewer tasks; this tab posts goals, shows open tasks and answers
-- what waits for you. Everything goes through the Board CLI (`vb`) in the Board folder.
local ui = tern.ui
local Mission = {}

Mission.TITLE = "Mission control"
local ABOUT = "Goals, tasks and decisions on the VinhLam Board. New goal posts to a project's build channel, "
	.. "where the lead plans it; Answer replies in a decision's thread; Open shows a thread as a note."
local REFRESH_MS = 30000

local data = { tasks = nil, error = nil, loading = false, at = 0 }
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

-- Open tasks as the tab shows them: what waits for you, then each project's goals and tasks.
function Mission.model(tasks)
	local now, byName, projects = {}, {}, {}
	for _, item in tasks or {} do
		local message = item.message or {}
		local labels = message.labels or {}
		local task = message.task or {}
		local channel = message.channel or "?"
		local name = string.match(channel, "^([^/]+)/") or channel
		local blocked = if type(task.blocked) == "table" then task.blocked else nil
		local decision = string.sub(channel, -10) == "/decisions" or labels.role == "decision"
		local row = {
			id = message.id, title = firstLine(message.text), state = task.state or "?",
			role = labels.role, lane = labels.lane, replies = item.replies or 0, decision = decision,
			last = item.last and string.gsub(firstLine(item.last.text), "^%[[^%]]*%]%s*", "") or nil,
			reason = blocked and (blocked.reason or blocked.kind) or task.reason,
			options = if decision then Mission.options(message.text) else {},
		}
		if row.state == "blocked" then table.insert(now, row) end
		if not decision then
			local project = byName[name]
			if not project then
				project = { name = name, goals = {}, tasks = {} }
				byName[name] = project
				table.insert(projects, project)
			end
			table.insert(if row.role == "epic" then project.goals else project.tasks, row)
		end
	end
	table.sort(projects, function(a, b) return a.name < b.name end)
	return { now = now, projects = projects }
end

local function text(key, value, role, props)
	props = props or {}
	props.key, props.text, props.role = key, value, role
	return ui.node("text", props)
end

local function button(key, label, action, title)
	return ui.button(label, { key = key, size = "sm", variant = "quiet", title = title or label, actions = { click = action } })
end

-- Board task states as coloured pills, after pi-emphasis: red = wrong, yellow = look here, green = settled.
local STATES = {
	failed = { "✗ Failed", "bad" }, blocked = { "■ Blocked", "bad" },
	waiting = { "◷ Waiting", "warn" }, claimed = { "◐ In progress", "warn" }, open = { "○ Todo", "warn" },
	ready = { "● Ready", "ok" }, completed = { "✓ Done", "ok" }, canceled = { "– Canceled", "dim" },
}

local function taskRow(row)
	local state = STATES[row.state] or { row.state, "dim" }
	local kind = (if row.role == "epic" then "goal" else row.role or "task") .. (if row.lane then " · " .. row.lane else "")
	local children = {
		ui.node("row", { key = "head", role = "roost.missionHead" }, {
			text("state", state[1], "roost.missionPill", { mark = state[2], title = "Board state: " .. row.state }),
			text("kind", kind, "roost.missionPill", { mark = if row.decision then "warn" else "kind" }),
			text("title", row.title, "roost.missionTitle", { grow = 1 }),
			button("open", "Open", "mission-open=" .. row.id, "Show the whole thread as a note"),
		}),
	}
	if row.reason and row.state == "blocked" then table.insert(children, text("reason", row.reason, "roost.hint")) end
	if row.role == "epic" and row.last then table.insert(children, text("last", "Lead: " .. row.last, "roost.hint")) end
	if row.state == "blocked" then
		local answers = {}
		for index, option in row.options do
			table.insert(answers, button("o" .. index, option.key .. " — " .. option.label, "mission-answer=" .. row.id .. "|" .. option.key, "Reply " .. option.key))
		end
		table.insert(answers, button("answer", "Answer…", "mission-answer=" .. row.id, "Write a reply in this thread"))
		table.insert(children, ui.node("row", { key = "answers", role = "roost.missionAnswers" }, answers))
	end
	return ui.node("col", { key = "t" .. string.gsub(row.id, "%W", ""), role = "roost.missionRow", mark = state[2] }, children)
end

function Mission.render()
	local count = if data.tasks then #data.tasks else 0
	local children = {
		ui.node("row", { key = "header", role = "roost.header" }, {
			ui.node("row", { key = "titleGroup", role = "roost.titleGroup", grow = 1 }, {
				text("title", Mission.TITLE, "roost.heading"),
				text("total", tostring(count), "roost.count", { title = "Open tasks" }),
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
		local model = Mission.model(data.tasks)
		local now = { text("h", "Now", "roost.folderName") }
		for _, row in model.now do table.insert(now, taskRow(row)) end
		if #model.now == 0 then table.insert(now, text("none", "Nothing waits for you.", "roost.hint")) end
		table.insert(children, ui.node("col", { key = "now", role = "roost.missionSection" }, now))
		for _, project in model.projects do
			local rows = { text("h", project.name, "roost.folderName") }
			for _, row in project.goals do table.insert(rows, taskRow(row)) end
			for _, row in project.tasks do table.insert(rows, taskRow(row)) end
			table.insert(children, ui.node("col", { key = "p" .. string.gsub(project.name, "%W", ""), role = "roost.missionSection" }, rows))
		end
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

function Mission.refresh(cx)
	if data.loading then return end
	data.loading = true
	draw(cx)
	vb({ "tasks", "--json" }, nil, function(out, err, nextCx)
		data.loading, data.at = false, tern.now()
		if out then
			local ok, decoded = pcall(tern.json.decode, out)
			if ok and type(decoded) == "table" then
				data.tasks, data.error = decoded.tasks or {}, nil
			else
				data.error = "The Board CLI answered something unexpected."
			end
		else
			data.error = err
		end
		if nextCx then draw(nextCx) elseif cx then pcall(draw, cx) end
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

-- Called from Roost's tick: refreshes an open tab every REFRESH_MS.
function Mission.tick(cx)
	if not data.loading and tern.now() - data.at > REFRESH_MS and pane(cx) then Mission.refresh(cx) end
end

local function reply(cx, id, answer)
	vb({ "reply", id, "-" }, answer, function(_, err, nextCx)
		nextCx = nextCx or cx
		if err then hooks.report(nextCx, err, "Answer not sent") return end
		nextCx:toast("info", "Answer sent", "The lead picks it up on its next turn.")
		Mission.refresh(nextCx)
	end)
end

local function newGoal(cx)
	vb({ "channels", "list", "--json" }, nil, function(out, err, nextCx)
		nextCx = nextCx or cx
		local ok, decoded = pcall(tern.json.decode, out or "")
		if err or not ok then hooks.report(nextCx, err or "Could not read the Board's projects.", "New goal") return end
		local last, items = tern.kv.get("mission-project"), {}
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

return Mission
