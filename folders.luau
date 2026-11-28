--!nonstrict
-- Path, label and time helpers for Roost: plain values and no tern API, so the
-- self-check at the bottom runs the moment the plugin loads.
local Folders = {}

-- The group of sessions whose working directory is unknown. Not an absolute
-- path, so it can never collide with a real folder.
Folders.OTHER = "Other"

-- Whether `key` is a path on this machine: "/..." (macOS, Linux) or "C:\..." (Windows);
-- anything else is "host:path" on another machine, or Other.
function Folders.isLocal(key)
	return string.sub(key, 1, 1) == "/" or string.find(key, "^%a:[\\/]") ~= nil
end

-- A folder key on another machine split into host name and path; nil for this machine's folders and Other.
function Folders.splitKey(key)
	if key == Folders.OTHER or Folders.isLocal(key) then return nil end
	return string.match(key, "^([^:]+):(.+)$")
end

-- macOS spells /tmp, /var and /etc as /private/...; tools disagree about which,
-- so every path is held in the short form.
local function canon(path)
	for _, top in { "/tmp", "/var", "/etc" } do
		local prefix = "/private" .. top
		if path == prefix or string.sub(path, 1, #prefix + 1) == prefix .. "/" then
			return string.sub(path, 9)
		end
	end
	return path
end

-- Strips trailing slashes ("/" and "C:\" stay); anything but a nonempty string gives "".
-- Windows drive paths take "\" throughout, as Tern reports them (Git for Windows says "C:/").
function Folders.norm(path)
	if type(path) ~= "string" or path == "" then return "" end
	if string.find(path, "^%a:[\\/]") then path = string.gsub(path, "/", "\\") end
	if string.find(path, "^%a:\\+$") then return string.sub(path, 1, 2) .. "\\" end
	local trimmed = string.gsub(path, "[/\\]+$", "")
	if trimmed == "" then return "/" end
	return canon(trimmed)
end

-- Remote Windows hosts report paths with backslashes, so both separators count here.
function Folders.basename(path)
	return string.match(path, "([^/\\]+)[/\\]*$") or path
end

-- "~" for the home folder and paths inside it (either separator).
function Folders.short(path, home)
	if home and home ~= "" and home ~= "/" then
		if path == home then return "~" end
		local next = string.sub(path, #home + 1, #home + 1)
		if string.sub(path, 1, #home) == home and (next == "/" or next == "\\") then return "~" .. string.sub(path, #home + 1) end
	end
	return path
end

-- Whether `path` is `folder` or inside it; remote Windows paths separate with "\".
function Folders.within(path, folder)
	if path == folder then return true end
	if string.sub(path, 1, #folder) ~= folder then return false end
	local last, after = string.sub(folder, -1), string.sub(path, #folder + 1, #folder + 1)
	return last == "/" or last == "\\" or after == "/" or after == "\\"
end

-- The deepest of `owners` that holds `path`, else `path` itself.
function Folders.owner(path, owners)
	local best, length = path, -1
	for _, folder in owners do
		if #folder > length and Folders.within(path, folder) then best, length = folder, #folder end
	end
	return best
end

-- `path` below `folder`; "" for the folder itself.
function Folders.relative(path, folder)
	if path == folder then return "" end
	return string.sub(path, #folder + (if folder == "/" then 1 else 2))
end

-- Canvas node keys are joined with dots, so a path travels as hex.
function Folders.hex(value)
	return (string.gsub(value, ".", function(byte)
		return string.format("%02x", string.byte(byte))
	end))
end

function Folders.unhex(hex)
	if not hex or #hex % 2 ~= 0 or string.find(hex, "%X") then return nil end
	return (string.gsub(hex, "..", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

-- Time since `seconds` ago, as "now", "12m", "4h" or "31d".
function Folders.age(seconds)
	if seconds == nil then return "" end
	if seconds < 60 then return "now" end
	if seconds < 3600 then return tostring(math.floor(seconds / 60)) .. "m" end
	if seconds < 86400 then return tostring(math.floor(seconds / 3600)) .. "h" end
	return tostring(math.floor(seconds / 86400)) .. "d"
end

-- `list` with `item` moved into `target`'s place: after it when moving down,
-- before it when moving up, as a drag would drop it. nil when either is missing.
function Folders.move(list, item, target)
	local out = table.clone(list)
	local from, to = table.find(out, item), table.find(out, target)
	if not from or not to then return nil end
	table.remove(out, from)
	table.insert(out, to, item)
	return out
end

-- A folder's label in two parts: its dimmed parent (trailing slash included, may
-- be cut to fit) and its name, which always stays whole: "~/exo" → "~/", "exo".
function Folders.parts(path, home)
	local short = Folders.short(path, home)
	local prefix, name = string.match(short, "^(.*[/\\])([^/\\]+)$")
	if not prefix then return "", short end
	return prefix, name
end

assert(Folders.norm("/a/b//") == "/a/b" and Folders.norm("///") == "/" and Folders.norm(nil) == "")
assert(Folders.norm("/private/tmp/x/") == "/tmp/x" and Folders.norm("/private/tmpx") == "/private/tmpx")
assert(Folders.norm("C:/Users/x/") == "C:\\Users\\x" and Folders.norm("C:\\") == "C:\\" and Folders.norm("C:/") == "C:\\")
assert(Folders.isLocal("/a") and Folders.isLocal("C:\\a") and not Folders.isLocal("pc:C:\\a") and not Folders.isLocal("Other"))
do
	local host, path = Folders.splitKey("vinhlam-pc:C:\\Users")
	assert(host == "vinhlam-pc" and path == "C:\\Users" and Folders.splitKey("C:\\Users") == nil and Folders.splitKey("/x") == nil)
end
assert(Folders.short("C:\\Users\\l\\dev", "C:\\Users\\l") == "~\\dev")
assert(Folders.basename("/Volumes/VINH MAC/it's here/") == "it's here")
assert(Folders.short("/Users/v/exo", "/Users/v") == "~/exo" and Folders.short("/Users/v", "/Users/v") == "~")
assert(Folders.short("/Users/vv", "/Users/v") == "/Users/vv")
assert(Folders.basename("C:\\Users\\lamvi\\tmp") == "tmp" and select(2, Folders.parts("C:\\Users\\lamvi\\tmp", nil)) == "tmp")
assert(Folders.within("/p/a", "/p") and not Folders.within("/pa", "/p") and Folders.within("/x", "/"))
assert(Folders.owner("/p/a/b", { "/p/a", "/p", "/q" }) == "/p/a" and Folders.owner("/x", { "/p" }) == "/x")
assert(Folders.owner("/p", { "/", "/p" }) == "/p")
assert(Folders.within("C:\\U\\x\\y", "C:\\U\\x") and not Folders.within("C:\\U\\xy", "C:\\U\\x"))
assert(Folders.owner("C:\\U\\dev\\home\\src", { "C:\\U\\dev", "C:\\U\\dev\\home" }) == "C:\\U\\dev\\home")
assert(Folders.relative("/p/a/b", "/p") == "a/b" and Folders.relative("/a", "/") == "a")
assert(Folders.unhex(Folders.hex("/tmp/sf-test dir/it's here")) == "/tmp/sf-test dir/it's here")
assert(Folders.unhex("zz") == nil and Folders.unhex("abc") == nil)
do
	local a, b = Folders.parts("/Users/v/exo", "/Users/v")
	assert(a == "~/" and b == "exo")
	a, b = Folders.parts("/tmp", nil)
	assert(a == "/" and b == "tmp")
	a, b = Folders.parts("/", nil)
	assert(a == "" and b == "/")
	a, b = Folders.parts("/Users/v", "/Users/v")
	assert(a == "" and b == "~")
end
assert(Folders.age(5) == "now" and Folders.age(720) == "12m" and Folders.age(4 * 3600 + 5) == "4h")
assert(Folders.age(2 * 86400) == "2d" and Folders.age(31 * 86400 + 9) == "31d" and Folders.age(nil) == "")
assert(table.concat(Folders.move({ "a", "b", "c" }, "a", "c"), "") == "bca")
assert(table.concat(Folders.move({ "a", "b", "c" }, "c", "a"), "") == "cab")
assert(Folders.move({ "a" }, "a", "z") == nil)

return Folders
