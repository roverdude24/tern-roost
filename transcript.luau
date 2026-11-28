-- A settled omp session's saved conversation: found by its title, reopened with
-- `omp --restore`, or rendered to Markdown to read without restoring. A remote host's
-- conversations are reached with this Mac's `ssh <host name>` (a Host line in ~/.ssh/config);
-- `remote` is nil for this Mac, else { host = name, windows = boolean }.
local Harness = require("./harness")

local Transcript = {}

local SSH = 'ssh -o BatchMode=yes -o ConnectTimeout=8 "$1"'

local LIST = [[for f in "$HOME"/.omp/agent/sessions/*/*.jsonl; do
  [ -f "$f" ] && printf '%s\t%s\n' "$f" "$(head -c 4000 "$f" | head -n 1)"
done]]

local WINDOWS_LIST = [[$ProgressPreference = 'SilentlyContinue'; [Console]::OutputEncoding = [Text.Encoding]::UTF8
Get-ChildItem "$HOME\.omp\agent\sessions\*\*.jsonl" | ForEach-Object { "$($_.FullName)`t$(Get-Content -LiteralPath $_.FullName -TotalCount 1 -Encoding UTF8)" }]]

local function listArgv(remote)
	if not remote then return { "/bin/sh", "-c", LIST } end
	if remote.windows then
		-- An encoded command dodges cmd.exe quoting on the Windows side.
		return { "/bin/sh", "-c", SSH .. ' powershell -NoProfile -EncodedCommand "$(printf %s "$2" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d "\\n")"',
			"sh", remote.host, WINDOWS_LIST }
	end
	return { "/bin/sh", "-c", 'printf %s "$2" | ' .. SSH .. " sh -s", "sh", remote.host, LIST }
end

-- The newest omp transcript whose title is `title` (icons ignored): cb(path?, cx).
function Transcript.find(title, remote, cb)
	if not title or title == "" then cb(nil, nil); return end
	tern.process.run(listArgv(remote), { timeout_ms = 20000 }, function(result, cx)
		local best, bestName = nil, nil
		if result.status == 0 then
			for line in string.gmatch(result.stdout, "[^\r\n]+") do
				local path, head = string.match(line, "^(.-)\t(.*)$")
				local ok, data = pcall(tern.json.decode, head or "")
				if ok and type(data) == "table" and data.type == "title" and Harness.title(data.title, "omp") == title then
					-- Files are named by start time, so the greatest name is the newest.
					local name = string.match(path, "[^/\\]+$")
					if not bestName or name > bestName then best, bestName = path, name end
				end
			end
		end
		cb(best, cx)
	end)
end

-- A shell command line that reopens the transcript at `path` (cmd and PowerShell on Windows).
function Transcript.restoreCommand(path, remote)
	if remote and remote.windows then return 'omp --restore "' .. path .. '"' end
	return "omp --restore '" .. string.gsub(path, "'", "'\\''") .. "'"
end

-- One "## You" / "## Agent" heading per change of speaker; tool calls are one-line bullets.
local MARKDOWN = [[
[inputs | select(.type == "message") | .message as $m
  | if $m.role == "user" then
      { r: "You", b: ($m.content | if type == "string" then . else [.[]? | select(.type == "text") | .text] | join("\n\n") end) }
    elif $m.role == "assistant" then
      { r: "Agent", b: ([$m.content[]? | if .type == "text" then .text
        elif .type == "toolCall" then "- `" + .name + "` " + ((.arguments.i // "") | tostring)
        else empty end] | join("\n")) }
    else empty end
  | select(.b != "")]
| reduce .[] as $x ({ p: null, o: "" };
    .o += (if $x.r != .p then "## " + $x.r + "\n\n" else "" end) + $x.b + "\n\n" | .p = $x.r)
| .o
]]

-- Fetches a remote transcript next to `out` first (scp), then renders it locally.
local RENDER = [[src="$1"
if [ -n "$5" ]; then scp -q -o BatchMode=yes -o ConnectTimeout=8 "$5:$1" "$2.jsonl" || exit 1; src="$2.jsonl"; fi
printf "# %s\n\n" "$3" > "$2" && jq -rn "$4" "$src" >> "$2"; s=$?
[ -n "$5" ] && rm -f "$2.jsonl"
exit $s]]

-- Writes the conversation at `path` to `out` as Markdown under `heading`: cb(err?, cx).
function Transcript.markdown(path, remote, out, heading, cb)
	local source = if remote then string.gsub(path, "\\", "/") else path
	tern.process.run({ "/bin/sh", "-c", RENDER, "sh", source, out, heading, MARKDOWN, if remote then remote.host else "" },
		{ timeout_ms = 60000 }, function(result, cx)
			cb(if result.status == 0 then nil else (result.stderr ~= "" and result.stderr or "jq failed"), cx)
		end)
end

return Transcript
