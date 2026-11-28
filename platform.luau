local Platform = {}

Platform.windows = tern.runtime.os == "windows"

function Platform.home(): string?
	local home = tern.getenv("HOME")
	return if home and home ~= "" then home else tern.getenv("USERPROFILE")
end

local CHOOSE_FOLDER = {
	"on run argv",
	'POSIX path of (choose folder with prompt (item 2 of argv) default location (POSIX file (item 1 of argv)))',
	"end run",
}

local WINDOWS_PICKER = [[
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
try {
    $dialog.Description = $env:ROOST_PICKER_PROMPT
    $dialog.SelectedPath = $env:ROOST_PICKER_START
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        [Console]::WriteLine($dialog.SelectedPath)
    }
} finally {
    $dialog.Dispose()
}
]]

local function trim(text: string): string
	return text:match("^%s*(.-)%s*$")
end

function Platform.chooseFolder(start, prompt, done)
	local argv, env
	if Platform.windows then
		argv = { "powershell.exe", "-NoProfile", "-STA", "-Command", WINDOWS_PICKER }
		env = { ROOST_PICKER_START = start, ROOST_PICKER_PROMPT = prompt }
	else
		argv = { "/usr/bin/osascript" }
		for _, line in CHOOSE_FOLDER do
			table.insert(argv, "-e")
			table.insert(argv, line)
		end
		table.insert(argv, start)
		table.insert(argv, prompt)
	end
	local ok, err = pcall(tern.process.run, argv, { env = env, timeout_ms = 30 * 60 * 1000 }, function(result, cx)
		if result.status == -1 or (not Platform.windows and result.status ~= 0 and result.stderr:find("-128", 1, true)) then
			done(nil, nil, cx)
		elseif result.status == 0 then
			local path = trim(result.stdout)
			done(if path == "" then nil else path, nil, cx)
		else
			local detail = trim(result.stderr)
			done(nil, if detail == "" then "exit status " .. result.status else detail, cx)
		end
	end)
	if not ok then tern.timer(0, function(cx) done(nil, tostring(err), cx) end) end
end

function Platform.reveal(path, done)
	local app = if Platform.windows then "explorer.exe" else "/usr/bin/open"
	local ok, err = pcall(tern.process.run, { app, path }, { timeout_ms = 15000 }, function(result, cx)
		-- Explorer can return 1 after handing off successfully to its existing process.
		if result.status == 0 or (Platform.windows and result.status == 1) then
			done(nil, cx)
		else
			local detail = trim(result.stderr)
			done(if detail == "" then "exit status " .. result.status else detail, cx)
		end
	end)
	if not ok then tern.timer(0, function(cx) done(tostring(err), cx) end) end
end

function Platform.ternBinary(): string?
	if Platform.windows then
		local base = tern.getenv("LOCALAPPDATA")
		local path = base and base ~= "" and base .. "\\Programs\\Tern\\tern.exe"
		return if path and tern.fs.exists(path) then path else nil
	end
	for _, path in { "/Applications/Tern.app/Contents/MacOS/tern", (tern.getenv("HOME") or "") .. "/Applications/Tern.app/Contents/MacOS/tern" } do
		if tern.fs.exists(path) then return path end
	end
	return nil
end

assert(trim(" \tC:\\My folder\\it's here\r\n") == "C:\\My folder\\it's here" and trim("\r\n") == "")

return Platform
