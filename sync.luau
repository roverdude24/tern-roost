--!nonstrict
-- Projects shared by every machine running Roost: one file, `~/.roost/projects.json`, written in a
-- machine-neutral form ({ updated, projects = { { name, folders = { "Machine:path" } } } }, where Machine
-- is each computer's name) so the same text is valid on every machine. This Roost reads its own copy;
-- `Sync.exchange` copies the newer file to or from a connected host over this machine's `ssh <host>`.
local Folders = require("./folders")
local Sync = {}

-- "Machine:path" folders → this machine's keys: its own paths bare, a connected host's under that
-- host's name as shown here (matched without case), any other machine as written.
function Sync.localize(projects, me, hosts)
	local out = {}
	for _, project in projects or {} do
		local folders = {}
		for _, key in project.folders or {} do
			local machine, path = string.match(key, "^([^:]+):(.+)$")
			if machine and string.lower(machine) == string.lower(me) then
				table.insert(folders, path)
			elseif machine and hosts[string.lower(machine)] then
				table.insert(folders, hosts[string.lower(machine)] .. ":" .. path)
			else
				table.insert(folders, key)
			end
		end
		table.insert(out, { name = project.name, folders = folders })
	end
	return out
end

-- This machine's keys → "Machine:path".
function Sync.canonical(projects, me)
	local out = {}
	for _, project in projects or {} do
		local folders = {}
		for _, key in project.folders do
			table.insert(folders, if Folders.isLocal(key) then me .. ":" .. key else key)
		end
		table.insert(out, { name = project.name, folders = folders })
	end
	return out
end

function Sync.decode(text)
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" or type(data.projects) ~= "table" then return nil end
	data.updated = tonumber(data.updated) or 0
	return data
end

-- PowerShell takes its script as base64 UTF-16LE, so no value is ever spliced into a quoted command line.
local function encoded(script)
	return tern.base64.encode((string.gsub(script, ".", "%0\0")))
end

local READ_PS = "$ProgressPreference='SilentlyContinue'; $p=Join-Path $env:USERPROFILE '.roost\\projects.json'; "
	.. "if (Test-Path $p) { [IO.File]::ReadAllText($p) }"
local WRITE_PS = "$ProgressPreference='SilentlyContinue'; $d=Join-Path $env:USERPROFILE '.roost'; "
	.. "New-Item -ItemType Directory -Force $d | Out-Null; "
	.. "[IO.File]::WriteAllText((Join-Path $d 'projects.json'), [Console]::In.ReadToEnd())"

-- The remote command reading (or, from stdin, writing) the host's file; `windows` hosts run PowerShell.
local function remoteCommand(windows, write)
	if windows then return "powershell -NoProfile -NonInteractive -EncodedCommand " .. encoded(if write then WRITE_PS else READ_PS) end
	if write then return "mkdir -p ~/.roost && cat > ~/.roost/projects.json" end
	return "cat ~/.roost/projects.json 2>/dev/null; true"
end

-- Brings `host` and this machine to the newer file. `localText` is this machine's file (nil when none);
-- `done(newText, err, cx)`: newText is the remote file to adopt here, nil when this side was newer or equal.
function Sync.exchange(ssh, host, windows, localText, done)
	local base = { ssh, "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host }
	local readArgv = table.clone(base)
	table.insert(readArgv, remoteCommand(windows, false))
	tern.process.run(readArgv, { timeout_ms = 20000 }, function(result, cx)
		if result.status ~= 0 then done(nil, "ssh " .. host .. ": " .. (result.stderr or ""), cx) return end
		local mine, theirs = localText and Sync.decode(localText), Sync.decode(result.stdout or "")
		-- An unreadable remote file is never overwritten: it may hold edits made there.
		if not theirs and string.find(result.stdout or "", "%S") then done(nil, "unreadable projects file on " .. host, cx) return end
		if theirs and (not mine or theirs.updated > mine.updated) then done(result.stdout, nil, cx) return end
		if not mine or (theirs and theirs.updated == mine.updated) then done(nil, nil, cx) return end
		local writeArgv = table.clone(base)
		table.insert(writeArgv, remoteCommand(windows, true))
		tern.process.run(writeArgv, { timeout_ms = 20000, stdin = localText }, function(written, writeCx)
			done(nil, if written.status == 0 then nil else "ssh " .. host .. ": " .. (written.stderr or ""), writeCx)
		end)
	end)
end

do
	local here = Sync.localize({ { name = "P", folders = { "MacBook Air:/a b/it's", "VINHLAM-PC:C:\\x", "far:/y" } } },
		"macbook air", { ["vinhlam-pc"] = "vinhlam-pc" })
	assert(here[1].folders[1] == "/a b/it's" and here[1].folders[2] == "vinhlam-pc:C:\\x" and here[1].folders[3] == "far:/y")
	local back = Sync.canonical(here, "MacBook Air")
	assert(back[1].folders[1] == "MacBook Air:/a b/it's" and back[1].folders[2] == "vinhlam-pc:C:\\x")
	local pc = Sync.localize(back, "VINHLAM-PC", {})
	assert(pc[1].folders[2] == "C:\\x" and pc[1].folders[1] == "MacBook Air:/a b/it's")
	assert(Sync.canonical(pc, "VINHLAM-PC")[1].folders[2] == "VINHLAM-PC:C:\\x")
	assert(Sync.decode("nope") == nil and Sync.decode('{"projects":[],"updated":5}').updated == 5)
end

return Sync
