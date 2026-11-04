local ui = tern.ui
local Folders = require("./folders")
local View = {}

-- Tern labels menu entries with the whole action string, including any =value.
-- Keep menu actions plain and recover their target from our keyed row node.
function View.sessionId(node)
	return tonumber(type(node) == "string" and node:match("%.s(%d+)%.row$") or nil)
end

function View.folderPath(node)
	return Folders.unhex(type(node) == "string" and node:match("%.f(%x+)%.header$") or nil)
end

function View.settledId(node)
	return type(node) == "string" and node:match("%.z(%d+)%.row$") or nil
end

local function text(key, value, role, props)
	props = props or {}
	props.key, props.text, props.role = key, value, role
	return ui.node("text", props)
end

-- An icon-only button: the tooltip doubles as its accessible name.
local function iconButton(key, icon, action, title, role, extra)
	local props = {
		key = key, icon = icon, size = "sm", variant = "quiet", role = role or "roost.iconButton",
		title = title, aria = title, actions = { click = action },
	}
	if extra then for name, value in extra do props[name] = value end end
	return ui.button("", props)
end

local function plural(n, word)
	return tostring(n) .. " " .. word .. (if n == 1 then "" else "s")
end

local function badge(key, initials, role)
	return text(key, initials, role, { aria = "Folder " .. initials })
end

local function tooltip(session)
	local lines = { session.name }
	table.insert(lines, "Folder: " .. session.where)
	table.insert(lines, "Host: " .. session.host)
	local harness = session.harness
	table.insert(lines, "Harness: " .. harness.label .. (if harness.model then " · " .. harness.model else ""))
	local state = if session.agent == "waiting" then " · agent waiting for you"
		elseif session.agent == "working" then " · agent working"
		else ""
	table.insert(lines, plural(session.tabs, "tab") .. state .. (if session.locked then " · locked" else ""))
	table.insert(lines, "Last active " .. (if session.age == "now" then "now" else session.age .. " ago"))
	return table.concat(lines, "\n")
end

local function sessionNode(session)
	local menu = {
		"Rename", "New tab here",
		if session.locked then "Unlock session" else "Lock session",
		"Settle", "Close session",
	}
	local role, dotTitle = "roost.dotIdle", "Idle"
	if session.agent == "waiting" then
		role, dotTitle = "roost.dotWaiting", "Agent waiting for you"
	elseif session.agent == "working" then
		role, dotTitle = "roost.dotAgent", "Agent working"
	end
	local tip = tooltip(session)
	local head = {
		ui.el("div", { key = "status", role = role, title = dotTitle }),
		badge("badge", session.badge, session.role),
		text("name", session.name, "roost.name"),
		ui.el("div", { key = "spacer", grow = 1 }),
	}
	if session.locked then
		table.insert(head, text("lock", "🔒", "roost.lockMark", { title = "Locked: unlock it to close" }))
	end
	table.insert(head, iconButton("harness", session.harness.icon, "switch=" .. tostring(session.id),
		session.harness.label .. (if session.harness.model then " · " .. session.harness.model else ""),
		"roost.harness"))
	table.insert(head, text("age", session.age, "roost.age"))
	local rowChildren = { ui.node("row", { key = "head", role = "roost.head" }, head) }
	if session.sub then
		table.insert(rowChildren, text("sub", session.sub, "roost.sub"))
	end
	local row = ui.node("col", {
		key = "row", role = "roost.row", title = tip,
		aria = session.name .. ", " .. plural(session.tabs, "tab") .. ", " .. session.harness.label
			.. (if session.agent == "waiting" then ", agent waiting for you"
				elseif session.agent == "working" then ", agent working" else "")
			.. (if session.current then ", current session" else ""),
		actions = { click = "switch=" .. tostring(session.id), menu = menu },
	}, rowChildren)
	return ui.node("col", {
		key = "s" .. tostring(session.id), role = "roost.session",
		mark = if session.current then "pick" else nil,
	}, { row })
end

-- A worktree's header already names its branch, so its line carries only the rest.
local function gitLine(git, hideBranch)
	local parts = {}
	if not hideBranch then
		table.insert(parts, ui.button("", {
			key = "icon", icon = "branch", size = "sm", variant = "quiet", role = "roost.gitIcon",
			title = "Branch " .. git.branch, aria = "Branch " .. git.branch,
		}))
		table.insert(parts, text("branch", git.branch, "roost.gitBranch"))
	end
	if git.dirty then
		table.insert(parts, text("dirty", "✱", "roost.dirty", { title = "Uncommitted changes" }))
	end
	if git.ahead > 0 or git.behind > 0 then
		local label = (if git.ahead > 0 then "↑" .. tostring(git.ahead) else "")
			.. (if git.ahead > 0 and git.behind > 0 then " " else "")
			.. (if git.behind > 0 then "↓" .. tostring(git.behind) else "")
		table.insert(parts, text("div", label, "roost.gitDiv",
			{ title = tostring(git.ahead) .. " ahead, " .. tostring(git.behind) .. " behind" }))
	end
	if git.pr then
		local summary = "#" .. tostring(git.pr.number) .. " · " .. git.pr.state
		table.insert(parts, ui.button("#" .. tostring(git.pr.number), {
			key = "pr", size = "sm", variant = "quiet", role = "roost.pr",
			title = "Pull request " .. summary .. " — open on GitHub", aria = "Pull request " .. summary,
			actions = { click = "pr=" .. Folders.hex(git.pr.url) },
		}))
	end
	if #parts == 0 then return nil end
	return ui.node("row", { key = "git", role = "roost.gitLine" }, parts)
end

local folderNode
function folderNode(group)
	local hex = Folders.hex(group.path)
	local toggleTitle = (if group.collapsed then "Expand " else "Collapse ") .. group.path
	local toggleChildren = {
		text("caret", if group.collapsed then "▸" else "▾", "roost.caret"),
	}
	if not group.other then
		table.insert(toggleChildren, badge("badge", group.badge, group.role))
	end
	if group.prefix ~= "" then table.insert(toggleChildren, text("prefix", group.prefix, "roost.folderParent")) end
	table.insert(toggleChildren, text("name", group.name, "roost.folderName"))
	local header = {
		ui.el("button", {
			key = "collapse", role = "roost.folderToggle", title = toggleTitle, aria = toggleTitle,
			actions = { click = "collapse=" .. hex },
		}, toggleChildren),
		ui.el("div", { key = "spacer", grow = 1 }),
	}
	local menu
	if not group.other then
		if group.pinned then
			table.insert(header, iconButton("pin", "pin", "pin=" .. hex, "Unpin folder (it hides when it has no sessions)", "roost.pinOn"))
		end
		table.insert(header, iconButton("new", "plus", "folder-new=" .. hex, "New session in " .. group.path, "roost.hoverAct"))
		table.insert(header, iconButton("omp", "sparkle", "folder-omp=" .. hex, "New session running omp in " .. group.path, "roost.hoverAct"))
		table.insert(header, iconButton("reveal", "folder-open", "reveal=" .. hex, "Reveal in Finder", "roost.hoverAct"))
		if not group.pinned and not group.worktree then
			table.insert(header, iconButton("pin", "pin", "pin=" .. hex, "Pin folder (always shown)", "roost.hoverAct"))
		end
		menu = { "New session here", "New omp session here", "Reveal in Finder" }
		if group.worktree then
			table.insert(menu, "Remove worktree")
		else
			table.insert(menu, if group.pinned then "Unpin folder" else "Pin folder")
			if group.git then table.insert(menu, "New worktree session") end
		end
	end
	table.insert(header, text("age", group.age, "roost.age"))
	local children = {
		ui.node("row", {
			key = "header", role = "roost.folderHeader", actions = if menu then { menu = menu } else nil,
			title = group.path,
		}, header),
	}
	local line = group.git and gitLine(group.git, group.worktree)
	if line then table.insert(children, line) end
	if not group.collapsed then
		for _, session in ipairs(group.sessions) do
			table.insert(children, sessionNode(session))
		end
		for _, child in ipairs(group.children or {}) do
			table.insert(children, folderNode(child))
		end
		if #group.sessions == 0 and #(group.children or {}) == 0 then
			table.insert(children, text("empty", "No sessions here · + opens one", "roost.hint"))
		end
	end
	return ui.node("col", {
		key = "f" .. hex, role = if group.worktree then "roost.worktree" else "roost.folder",
	}, children)
end

local function settledNode(row)
	local tip = table.concat({
		row.name, "Folder: " .. row.where, "Host: " .. row.host,
		"Harness: " .. row.harness .. (if row.model then " · " .. row.model else ""),
		"Last active " .. (if row.age == "now" then "now" else row.age .. " ago"),
	}, "\n")
	return ui.node("col", { key = "z" .. row.sid, role = "roost.settledRow" }, {
		ui.node("row", {
			key = "row", role = "roost.settledHead", title = tip,
			aria = row.name .. ", settled " .. row.age .. " ago",
			actions = { menu = { "Restore", "Forget" } },
		}, {
			badge("badge", row.badge, row.role),
			text("name", row.name, "roost.settledName"),
			ui.el("div", { key = "spacer", grow = 1 }),
			text("age", row.age, "roost.age"),
			iconButton("restore", "undo", "restore=" .. row.sid, "Restore " .. row.name, "roost.iconButton"),
		}),
	})
end

local SETTLED_SHOWN = 8

local function settledSection(settled)
	local title = (if settled.open then "Collapse" else "Expand") .. " Settled"
	local children = {
		ui.node("row", { key = "header", role = "roost.settledHeader" }, {
			ui.el("button", {
				key = "toggle", role = "roost.folderToggle", title = title, aria = title,
				actions = { click = "settled-toggle" },
			}, {
				text("caret", if settled.open then "▾" else "▸", "roost.caret"),
				text("name", "Settled", "roost.folderName"),
				text("count", tostring(settled.count), "roost.count"),
			}),
		}),
	}
	if settled.open then
		-- shortcut: the dock does not scroll, so it shows the newest SETTLED_SHOWN; add paging if users keep more.
		for index, row in ipairs(settled.rows) do
			if index > SETTLED_SHOWN then break end
			table.insert(children, settledNode(row))
		end
		if #settled.rows > SETTLED_SHOWN then
			table.insert(children, text("more", "+" .. (#settled.rows - SETTLED_SHOWN) .. " older", "roost.hint"))
		elseif #settled.rows == 0 then
			table.insert(children, text("empty", "Nothing settled yet · right-click a session › Settle", "roost.hint"))
		end
	end
	return ui.node("col", { key = "settled", role = "roost.settled" }, children)
end

function View.render(model)
	local children = {
		ui.node("row", { key = "header", role = "roost.header" }, {
			ui.node("row", { key = "titleGroup", role = "roost.titleGroup", grow = 1 }, {
				text("title", "Roost", "roost.heading"),
				text("total", tostring(model.total), "roost.count"),
			}),
			iconButton("find", "search", "find", "Find session"),
			iconButton("new", "plus", "new", "New session"),
			iconButton("add", "folder-plus", "add", "Add folder"),
			iconButton("refresh", "refresh", "refresh", if model.spinning then "Refreshing…" else "Refresh",
				"roost.iconButton", { busy = model.spinning }),
		}),
	}
	for _, group in ipairs(model.groups) do
		table.insert(children, folderNode(group))
	end
	return ui.node("col", { key = "roost", role = "roost.panel" }, children)
end

-- Settled lives in the canvas dock, so it stays pinned to the panel's bottom edge.
function View.dock(model)
	return settledSection(model.settled)
end

return View
