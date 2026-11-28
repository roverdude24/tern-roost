-- A settled omp session's saved conversation: found by its title, reopened with
-- `omp --restore`, or rendered to Markdown to read without restoring.
local Harness = require("./harness")

local Transcript = {}

local LIST = [[for f in "$HOME"/.omp/agent/sessions/*/*.jsonl; do
  [ -f "$f" ] && printf '%s\t%s\n' "$f" "$(head -c 4000 "$f" | head -n 1)"
done]]

-- The newest omp transcript whose title is `title` (icons ignored): cb(path?, cx).
function Transcript.find(title, cb)
	if not title or title == "" then cb(nil, nil); return end
	tern.process.run({ "/bin/sh", "-c", LIST }, { timeout_ms = 15000 }, function(result, cx)
		local best, bestName = nil, nil
		if result.status == 0 then
			for line in string.gmatch(result.stdout, "[^\n]+") do
				local path, head = string.match(line, "^(.-)\t(.*)$")
				local ok, data = pcall(tern.json.decode, head or "")
				if ok and type(data) == "table" and data.type == "title" and Harness.title(data.title, "omp") == title then
					-- Files are named by start time, so the greatest name is the newest.
					local name = string.match(path, "[^/]+$")
					if not bestName or name > bestName then best, bestName = path, name end
				end
			end
		end
		cb(best, cx)
	end)
end

-- A shell command line that reopens the transcript at `path`.
function Transcript.restoreCommand(path)
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

-- Writes the conversation at `path` to `out` as Markdown under `heading`: cb(err?, cx).
function Transcript.markdown(path, out, heading, cb)
	local script = 'printf "# %s\\n\\n" "$3" > "$2" && jq -rn "$4" "$1" >> "$2"'
	tern.process.run({ "/bin/sh", "-c", script, "sh", path, out, heading, MARKDOWN }, { timeout_ms = 30000 }, function(result, cx)
		cb(if result.status == 0 then nil else (result.stderr ~= "" and result.stderr or "jq failed"), cx)
	end)
end

return Transcript
