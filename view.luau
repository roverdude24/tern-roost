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

local function text(key, value, role, props)
	props = props or {}
	props.key, props.text, props.role = key, value, role
	return ui.node("text", props)
end

local function button(key, label, action, title, role)
	return ui.el("button", {
		key = key, text = label, role = role or "sessions.button",
		title = title, aria = title, actions = { click = action },
	})
end

local function plural(n, word)
	return tostring(n) .. " " .. word .. (if n == 1 then "" else "s")
end

local function details(session)
	local lines = { session.name, session.where, "" }
	local agent = if session.agent == "waiting" then " · agent waiting for you"
		elseif session.agent == "working" then " · agent working"
		else ""
	table.insert(lines, plural(session.tabs, "tab") .. agent .. (if session.locked then " · locked" else ""))
	table.insert(lines, "Click to switch · right-click for more")
	return table.concat(lines, "\n")
end

local function sessionNode(session)
	local menu = {
		"Rename", "New tab here",
		if session.locked then "Unlock session" else "Lock session",
		"Close session",
	}
	local role, dotTitle = "sessions.dotIdle", "Idle"
	if session.agent == "waiting" then
		role, dotTitle = "sessions.dotWaiting", "Agent waiting for you"
	elseif session.agent == "working" then
		role, dotTitle = "sessions.dotAgent", "Agent working"
	end
	local head = {
		ui.el("div", { key = "status", role = role, title = dotTitle }),
		text("name", session.name, "sessions.name"),
		ui.el("div", { key = "spacer", grow = 1 }),
	}
	if session.locked then
		table.insert(head, text("lock", "🔒", "sessions.lockMark", { title = "Locked: unlock it to close" }))
	end
	table.insert(head, text("tabs", plural(session.tabs, "tab"), "sessions.badge"))
	local rowChildren = { ui.node("row", { key = "head", role = "sessions.head" }, head) }
	if session.sub then
		table.insert(rowChildren, text("sub", session.sub, "sessions.sub"))
	end
	local row = ui.node("col", {
		key = "row", role = "sessions.row", title = details(session),
		aria = session.name .. ", " .. plural(session.tabs, "tab")
			.. (if session.agent == "waiting" then ", agent waiting for you"
				elseif session.agent == "working" then ", agent working" else "")
			.. (if session.current then ", current session" else ""),
		actions = { click = "switch=" .. tostring(session.id), menu = menu },
	}, rowChildren)
	return ui.node("col", {
		key = "s" .. tostring(session.id), role = "sessions.session",
		mark = if session.current then "pick" else nil,
	}, { row })
end

local function folderNode(group)
	local hex = Folders.hex(group.path)
	local toggleTitle = (if group.collapsed then "Expand " else "Collapse ") .. group.path
	local toggle = ui.el("button", {
		key = "collapse", role = "sessions.folderToggle", title = toggleTitle, aria = toggleTitle,
		actions = { click = "collapse=" .. hex },
	}, {
		text("caret", if group.collapsed then "▸" else "▾", "sessions.caret"),
		text("prefix", group.prefix, "sessions.folderParent"),
		text("name", group.name, "sessions.folderName"),
	})
	local header = { toggle, text("count", tostring(#group.sessions), "sessions.count") }
	local menu
	if not group.other then
		table.insert(header, ui.el("div", { key = "spacer", grow = 1 }))
		table.insert(header, button("new", "+", "folder-new=" .. hex, "New session in " .. group.path, "sessions.iconButton"))
		table.insert(header, button("omp", "omp", "folder-omp=" .. hex, "New session running omp in " .. group.path, "sessions.iconButton"))
		table.insert(header, button("reveal", "↗", "reveal=" .. hex, "Reveal in Finder", "sessions.iconButton"))
		table.insert(header, button("pin", "📌", "pin=" .. hex,
			if group.pinned then "Unpin folder (it hides when it has no sessions)" else "Pin folder (always shown)",
			if group.pinned then "sessions.iconButtonOn" else "sessions.iconButton"))
		menu = {
			"New session here", "New omp session here", "Reveal in Finder",
			if group.pinned then "Unpin folder" else "Pin folder",
		}
	end
	local children = {
		ui.node("row", {
			key = "header", role = "sessions.folderHeader", actions = if menu then { menu = menu } else nil,
		}, header),
	}
	if not group.collapsed then
		for _, session in ipairs(group.sessions) do
			table.insert(children, sessionNode(session))
		end
		if #group.sessions == 0 then
			table.insert(children, text("empty", "No sessions here · + opens one", "sessions.hint"))
		end
	end
	return ui.node("col", { key = "f" .. hex, role = "sessions.folder" }, children)
end

function View.render(model)
	local children = {
		ui.node("row", { key = "header", role = "sessions.header" }, {
			ui.node("row", { key = "titleGroup", role = "sessions.titleGroup", grow = 1 }, {
				text("title", "Sessions", "sessions.heading"),
				text("total", tostring(model.total), "sessions.count"),
			}),
			button("find", "Find", "find", "Find a session by name or folder"),
			button("new", "New", "new", "New session in a folder"),
			button("add", "Add folder", "add", "Pin a folder so it always shows"),
			-- The glyph is its own element so only the arrow turns, not the button's frame.
			ui.el("button", {
				key = "refresh", role = "sessions.iconButton", actions = { click = "refresh" },
				title = if model.spinning then "Refreshing…" else "Refresh sessions",
				aria = if model.spinning then "Refreshing" else "Refresh sessions",
			}, {
				text("glyph", "↻", if model.spinning then "sessions.refreshGlyphSpin" else "sessions.refreshGlyph"),
			}),
		}),
	}
	for _, group in ipairs(model.groups) do
		table.insert(children, folderNode(group))
	end
	return ui.node("col", { key = "sessions", role = "sessions.panel" }, children)
end

return View
