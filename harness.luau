--!nonstrict
-- Which coding agent (if any) a session runs, plus display helpers for it and its host.
local Harness = {}

-- Agent CLIs by program name -> kind.
local KINDS = {
	omp = "omp", claude = "claude", ["claude-code"] = "claude", codex = "codex", pi = "pi",
	hermes = "hermes", gemini = "gemini", opencode = "opencode", aider = "aider",
}

local LABELS = {
	omp = "omp", claude = "Claude Code", codex = "Codex", pi = "Pi", hermes = "Hermes",
	gemini = "Gemini", opencode = "OpenCode", aider = "Aider", shell = "Shell",
}

-- Names Tern accepts (checked against tern.chrome.program_icon); pi and aider have none, so they get sparkle.
local ICONS = {
	omp = "omp", claude = "provider-anthropic", codex = "provider-openai-codex",
	gemini = "provider-google-gemini-cli", opencode = "provider-opencode", hermes = "hermes",
	pi = "sparkle", aider = "sparkle", shell = "terminal",
}

-- Agents tried in this order when more than one has the same state.
local RANK = { working = 3, waiting = 2, idle = 1 }
local STATES = { working = "working", waiting_input = "waiting" }

-- The agent a command line runs, e.g. "omp", "cd x && claude --resume", "FOO=1 /usr/bin/codex".
local function kindOfLine(line)
	if type(line) ~= "string" then return nil end
	for segment in string.gmatch(line, "[^;&|]+") do
		for word in string.gmatch(segment, "%S+") do
			if not string.find(word, "=", 1, true) then
				local kind = KINDS[string.lower(string.match(word, "([^/]+)$") or "")]
				if kind then return kind end
				break
			end
		end
	end
	return nil
end

-- tern.json.null and other non-strings count as absent.
local function str(value)
	if type(value) == "string" and value ~= "" then return value end
	return nil
end

-- "claude-opus-5-5" -> "Opus 5.5", "gpt-6-astra" -> "GPT-6 Astra". Names that already
-- have capitals or spaces (omp reports "Opus 5.5") pass through.
function Harness.prettyModel(id)
	id = str(id)
	if not id then return nil end
	id = string.match(id, "^%s*(.-)%s*$")
	if string.find(id, "[%sA-Z]") then return id end
	id = string.match(id, "([^/]+)$") -- provider/model
	id = string.gsub(id, "[:@%[].*$", "") -- :latest, @date, [1m]
	local tokens = {}
	for token in string.gmatch(id, "[^%-_]+") do
		if not (string.match(token, "^%d+$") and (#token == 8 or #token == 6)) then table.insert(tokens, token) end -- date stamps
	end
	if tokens[1] == "claude" and #tokens > 1 then table.remove(tokens, 1) end
	local words = {}
	local index = 1
	while index <= #tokens do
		local token = tokens[index]
		local word
		if string.match(token, "^%d+$") then
			word = token
			-- "5-5" is version 5.5; a 3+ digit run is a date or build, not a minor.
			while string.match(tokens[index + 1] or "", "^%d%d?$") and string.match(word, "^%d+[%.%d]*$")
				and not string.find(word, ".", 1, true) do
				word = word .. "." .. tokens[index + 1]
				index += 1
			end
		elseif token == "gpt" or token == "glm" then
			word = string.upper(token)
			-- GPT-6, GPT-5.5: the version stays glued.
			if string.match(tokens[index + 1] or "", "^%d[%d%.]*$") then
				local version = tokens[index + 1]
				index += 1
				while string.match(tokens[index + 1] or "", "^%d%d?$") and not string.find(version, ".", 1, true) do
					version = version .. "." .. tokens[index + 1]
					index += 1
				end
				word = word .. "-" .. version
			end
		elseif string.match(token, "^%d+[bkm]$") then
			word = string.upper(token) -- 70b -> 70B
		elseif string.match(token, "^o%d") then
			word = token -- o3, o4-mini
		else
			word = string.upper(string.sub(token, 1, 1)) .. string.sub(token, 2)
		end
		table.insert(words, word)
		index += 1
	end
	if #words == 0 then return nil end
	return table.concat(words, " ")
end

-- Pane facts by id for the session: panes whose tab belongs to it.
local function sessionPanes(cx, sessionId)
	local id = tostring(sessionId)
	local tabs = {}
	for _, tab in cx.session:tabs() do
		if tostring(tab.session) == id then tabs[tab.id] = true end
	end
	local panes = {}
	for _, pane in cx.session:panes() do
		if pane.tab and tabs[pane.tab] then panes[pane.pane] = pane end
	end
	return panes
end

local function describe(kind, state, model, pane, title)
	return { kind = kind, label = LABELS[kind], model = model, icon = ICONS[kind], state = state, pane = pane, title = title }
end

-- A pane title worth naming a session after, e.g. omp's "<icon> OMNI: Evaluate repos" -> "OMNI: Evaluate repos".
-- Leading icons and spinners go (Nerd Font glyphs, Claude's ✳, braille); nil for a path or the program's own name.
function Harness.title(raw, kind)
	raw = str(raw)
	if not raw then return nil end
	local start = #raw + 1
	for pos, cp in utf8.codes(raw) do
		local icon = cp == 32 or cp == 9 or (cp >= 0x2000 and cp < 0x3000) or (cp >= 0xE000 and cp <= 0xF8FF) or cp >= 0x1F000
		if not icon then start = pos; break end
	end
	local text = string.match(string.sub(raw, start), "^(.-)%s*$")
	if text == "" or string.find(text, "^[/~]") then return nil end
	local lower = string.lower(text)
	if KINDS[lower] or lower == string.lower(LABELS[kind] or "") then return nil end
	return text
end

-- The most relevant agent in a session: working beats waiting beats idle; native agent
-- blocks (which know their model) beat agent CLIs found in plain terminals.
-- -> { kind, label, model?, icon, state, pane? }; a session without an agent is kind "shell".
function Harness.detect(cx, sessionId)
	local ok, result = pcall(function()
		local panes = sessionPanes(cx, sessionId)
		local best, bestScore
		local function consider(found, state, native)
			local score = RANK[state] * 2 + (if native then 1 else 0)
			if not bestScore or score > bestScore then best, bestScore = found, score end
		end
		local seen = {}
		for _, agent in cx.agents:list() do
			local pane = panes[agent.pane]
			if pane and agent.state ~= "exited" then
				seen[agent.pane] = true
				local kind = kindOfLine(str(agent.agent_command)) or kindOfLine(str(agent.command))
					or kindOfLine(str(agent.program)) or kindOfLine(str(pane.program)) or kindOfLine(str(pane.title))
					or "omp" -- an unnamed native agent block is omp
				local state = STATES[agent.state] or "idle"
				consider(describe(kind, state, Harness.prettyModel(agent.model), agent.pane, Harness.title(pane.title, kind)), state, true)
			end
		end
		for id, pane in panes do
			if not seen[id] and pane.kind == "terminal" and pane.exited == nil then
				local kind = kindOfLine(pane.running and pane.running.line) or kindOfLine(str(pane.program))
				if kind then
					local state = if pane.busy and pane.running then "working" else "idle"
					consider(describe(kind, state, nil, id, Harness.title(pane.title, kind)), state, false)
				end
			end
		end
		return best or describe("shell", "idle", nil, nil)
	end)
	if ok then return result end
	return describe("shell", "idle", nil, nil)
end

-- The command that starts a harness in a new terminal; nil for a plain shell.
function Harness.launchCommand(kind)
	return if kind ~= "shell" and LABELS[kind] then kind else nil
end

-- Tern names the local host after the network (`MacBook-Air`); people know it by its Sharing name.
local computerName
local pending = {}
local fetching = false

-- Reads the computer name once, off-thread; `onReady` (optional) runs after it lands.
function Harness.warm(onReady)
	if computerName then
		if onReady then onReady() end
		return
	end
	if onReady then table.insert(pending, onReady) end
	if fetching then return end
	fetching = true
	local started = pcall(tern.process.run, { "/usr/sbin/scutil", "--get", "ComputerName" }, { timeout_ms = 3000 },
		function(result)
			local name = result.status == 0 and string.match(result.stdout or "", "^%s*(.-)%s*$") or nil
			computerName = if name and name ~= "" then name else false
			local callbacks = pending
			pending = {}
			if computerName then
				for _, callback in callbacks do pcall(callback) end
			end
		end)
	if not started then computerName = false end
end

-- Display name of a host by id (nil: the current host). A remote host keeps Tern's name;
-- the local one shows its computer name once read, else Tern's name minus ".local".
function Harness.host(cx, hostId)
	local ok, name = pcall(function()
		local found
		if hostId == nil then
			found = cx.hosts:current()
		else
			for _, host in cx.hosts:list() do
				if tostring(host.id) == tostring(hostId) then found = host end
			end
		end
		if not found then return nil end
		if found.kind ~= "local" then return found.name end
		if computerName == nil then Harness.warm() end
		return computerName or string.gsub(string.gsub(found.name, "%.local$", ""), "%-", " ")
	end)
	return if ok then name else nil
end

-- Self-checks for the pure parts.
assert(Harness.prettyModel("claude-opus-5-5") == "Opus 5.5" and Harness.prettyModel("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
assert(Harness.prettyModel("gpt-6-astra") == "GPT-6 Astra" and Harness.prettyModel("gpt-5.5-codex") == "GPT-5.5 Codex")
assert(Harness.prettyModel("gemini-3.1-flash-lite") == "Gemini 3.1 Flash Lite" and Harness.prettyModel("anthropic/claude-3-5-haiku") == "3.5 Haiku")
assert(Harness.prettyModel("Opus 5.5") == "Opus 5.5" and Harness.prettyModel("") == nil and Harness.prettyModel(nil) == nil)
assert(Harness.prettyModel("llama-3-70b:latest") == "Llama 3 70B" and Harness.prettyModel("grok-4.6") == "Grok 4.6")
assert(kindOfLine("cd x && FOO=1 /usr/local/bin/claude --resume") == "claude" and kindOfLine("ls omp") == nil and kindOfLine(nil) == nil)
assert(Harness.launchCommand("omp") == "omp" and Harness.launchCommand("shell") == nil and Harness.launchCommand("x") == nil)
assert(Harness.title("\u{F0D9A} OMNI: Evaluate repos", "omp") == "OMNI: Evaluate repos" and Harness.title("✳ Fix login", "claude") == "Fix login")
assert(Harness.title("omp", "omp") == nil and Harness.title("✳ Claude Code", "claude") == nil and Harness.title("~/src", "omp") == nil)
assert(Harness.title("Đổi tên phiên", "omp") == "Đổi tên phiên" and Harness.title(nil, "omp") == nil and Harness.title("  ", "omp") == nil)

return Harness
