-- A settled omp session's saved conversation: found by its title, reopened with
-- `omp --restore`, or rendered to Markdown to read without restoring. A remote host's
-- conversations are reached over SSH; `remote` is nil locally, else { host, windows }.
local Harness = require("./harness")
local Platform = require("./platform")

local Transcript = {}

local CONNECT = { "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "--" }

local LIST = [[for f in "$HOME"/.omp/agent/sessions/*/*.jsonl; do
  [ -f "$f" ] && printf '%s\t%s\n' "$f" "$(head -c 4000 "$f" | head -n 1)"
done]]

local WINDOWS_LIST = [[
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = Join-Path $HOME '.omp\agent\sessions'
if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
        Get-ChildItem -LiteralPath $_.FullName -Filter '*.jsonl' -File | ForEach-Object {
            "$($_.FullName)`t$(Get-Content -LiteralPath $_.FullName -TotalCount 1 -Encoding UTF8)"
        }
    }
}
]]

-- PowerShell's encoded command is UTF-16LE. Our scripts contain only ASCII;
-- any path used by a script travels separately as base64-encoded UTF-8.
local function encodedCommand(ascii)
	return tern.base64.encode((string.gsub(ascii, ".", "%0\0")))
end

local function listCommand(remote)
	if not remote then
		if Platform.windows then return { "powershell.exe", "-NoProfile", "-EncodedCommand", encodedCommand(WINDOWS_LIST) } end
		return { "/bin/sh", "-c", LIST }
	end
	local argv = { if Platform.windows then "ssh.exe" else "ssh", table.unpack(CONNECT) }
	table.insert(argv, remote.host)
	if remote.windows then
		table.insert(argv, "powershell -NoProfile -EncodedCommand " .. encodedCommand(WINDOWS_LIST))
		return argv
	end
	table.insert(argv, "sh -s")
	return argv, LIST
end

-- The newest omp transcript whose title is `title` (icons ignored): cb(path?, cx).
function Transcript.find(title, remote, cb)
	if not title or title == "" then cb(nil, nil); return end
	local argv, stdin = listCommand(remote)
	local started = pcall(tern.process.run, argv, { stdin = stdin, timeout_ms = 20000 }, function(result, cx)
		local best, bestName = nil, nil
		if result.status == 0 then
			for line in string.gmatch(result.stdout, "[^\r\n]+") do
				local path, head = string.match(line, "^(.-)\t(.*)$")
				local ok, data = pcall(tern.json.decode, head or "")
				if path and ok and type(data) == "table" and data.type == "title" and Harness.title(data.title, "omp") == title then
					-- Files are named by start time, so the greatest name is the newest.
					local name = string.match(path, "[^/\\]+$")
					if name and (not bestName or name > bestName) then best, bestName = path, name end
				end
			end
		end
		cb(best, cx)
	end)
	if not started then tern.timer(0, function(cx) cb(nil, cx) end) end
end

-- A shell command line that reopens the transcript at `path`.
function Transcript.restoreCommand(path, remote)
	if (remote and remote.windows) or (not remote and Platform.windows) then
		local bytes = tern.base64.encode(path)
		local script = '& omp --restore ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("' .. bytes .. '")))'
		return "powershell.exe -NoProfile -EncodedCommand " .. encodedCommand(script)
	end
	return "omp --restore '" .. string.gsub(path, "'", "'\\''") .. "'"
end

local function messageBody(content, user)
	if user and type(content) == "string" then return content end
	if type(content) ~= "table" then return "" end
	local parts = {}
	for _, part in ipairs(content) do
		if type(part) == "table" then
			if part.type == "text" and type(part.text) == "string" then
				table.insert(parts, part.text)
			elseif not user and part.type == "toolCall" and type(part.name) == "string" then
				local intent = if type(part.arguments) == "table" then part.arguments.i else nil
				if intent == nil or intent == false or intent == tern.json.null then
					intent = ""
				elseif type(intent) ~= "string" then
					intent = tern.json.encode(intent)
				end
				table.insert(parts, "- `" .. part.name .. "` " .. intent)
			end
		end
	end
	return table.concat(parts, if user then "\n\n" else "\n")
end

-- Yield between batches so a long conversation does not spend a whole window hook decoding JSON.
local function renderBatch(lines, parts, previous)
	for _ = 1, 64 do
		local line = lines()
		if not line then return previous, true end
		if not string.find(line, "%S") then continue end
		local row = tern.json.decode(line)
		local message = type(row) == "table" and row.type == "message" and row.message
		if type(message) ~= "table" then continue end
		local speaker = if message.role == "user" then "You" elseif message.role == "assistant" then "Agent" else nil
		if not speaker then continue end
		local body = messageBody(message.content, speaker == "You")
		if body ~= "" then
			if previous ~= speaker then
				table.insert(parts, "## " .. speaker .. "\n\n")
				previous = speaker
			end
			table.insert(parts, body)
			table.insert(parts, "\n\n")
		end
	end
	return previous, false
end

local function render(source, copied, out, heading, cb, cx)
	local ok, data = pcall(tern.fs.read, source)
	if copied then pcall(tern.fs.remove, source) end
	if not ok then return cb(tostring(data), cx) end
	local lines = string.gmatch(data, "[^\r\n]+")
	local parts, previous = { "# ", heading, "\n\n" }, nil
	local function step(nextCx)
		local parsed, speaker, finished = pcall(renderBatch, lines, parts, previous)
		if not parsed then return cb(tostring(speaker), nextCx) end
		previous = speaker
		if not finished then tern.timer(0, step); return end
		table.insert(parts, "\n")
		local written, err = pcall(tern.fs.write, out, table.concat(parts))
		cb(if written then nil else tostring(err), nextCx)
	end
	step(cx)
end

-- Writes the conversation at `path` to `out` as Markdown under `heading`: cb(err?, cx).
function Transcript.markdown(path, remote, out, heading, cb)
	if not remote then
		tern.timer(0, function(cx) render(path, false, out, heading, cb, cx) end)
		return
	end
	local target = out .. "." .. tostring(tern.now()) .. ".jsonl"
	local source = if remote.windows then string.gsub(path, "\\", "/") else path
	local argv = { if Platform.windows then "scp.exe" else "scp", "-q", "-s", table.unpack(CONNECT) }
	table.insert(argv, remote.host .. ":" .. source)
	table.insert(argv, target)
	local started, err = pcall(tern.process.run, argv, { timeout_ms = 60000 }, function(result, cx)
		if result.status == 0 then return render(target, true, out, heading, cb, cx) end
		pcall(tern.fs.remove, target)
		cb(if result.stderr ~= "" then result.stderr else "Could not copy the conversation over SSH", cx)
	end)
	if not started then tern.timer(0, function(cx) cb(tostring(err), cx) end) end
end

assert(encodedCommand("A\n") == "QQAKAA==")
assert(Transcript.restoreCommand("/tmp/O'Neil's work.jsonl", { windows = false }) == [[omp --restore '/tmp/O'\''Neil'\''s work.jsonl']])
do
	local path = [[C:\Users\O'Neil\$drafts\Đổi tên.jsonl]]
	local command = Transcript.restoreCommand(path, { windows = true })
	local encoded = assert(string.match(command, "^powershell%.exe %-NoProfile %-EncodedCommand (%S+)$"))
	local script = (string.gsub(tern.base64.decode(encoded), "%z", ""))
	assert(tern.base64.decode(assert(string.match(script, 'FromBase64String%("([^"]+)"%)'))) == path)
end
do
	local sample = [[{"type":"title","title":"Fixture"}
{"type":"message","message":{"role":"user","content":[{"type":"text","text":"First"},{"type":"image"},{"type":"text","text":"Second"}]}}
{"type":"message","message":{"role":"user","content":"Follow up"}}
{"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hidden"},{"type":"text","text":"Answer"},{"type":"toolCall","name":"read","arguments":{"i":"Read file"}}]}}
{"type":"message","message":{"role":"toolResult","content":"Ignored"}}]]
	local parts = {}
	local _, finished = renderBatch(string.gmatch(sample, "[^\r\n]+"), parts, nil)
	assert(finished and table.concat(parts) == "## You\n\nFirst\n\nSecond\n\nFollow up\n\n## Agent\n\nAnswer\n- `read` Read file\n\n")
end

return Transcript
