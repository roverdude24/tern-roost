--!nonstrict
-- Path helpers for the Sessions panel: plain strings and no tern API, so the
-- self-check at the bottom runs the moment the plugin loads.
local Folders = {}

-- The group of sessions whose working directory is unknown. Not an absolute
-- path, so it can never collide with a real folder.
Folders.OTHER = "Other"

-- Strips trailing slashes ("/" stays); anything but a nonempty string gives "".
function Folders.norm(path)
	if type(path) ~= "string" or path == "" then return "" end
	local trimmed = string.gsub(path, "/+$", "")
	return if trimmed == "" then "/" else trimmed
end

function Folders.basename(path)
	return string.match(path, "([^/]+)/*$") or path
end

-- "~" for the home folder and paths inside it.
function Folders.short(path, home)
	if home and home ~= "" and home ~= "/" then
		if path == home then return "~" end
		if string.sub(path, 1, #home + 1) == home .. "/" then return "~" .. string.sub(path, #home + 1) end
	end
	return path
end

-- Whether `path` is `folder` or inside it.
function Folders.within(path, folder)
	local prefix = if string.sub(folder, -1) == "/" then folder else folder .. "/"
	return path == folder or string.sub(path, 1, #prefix) == prefix
end

-- The deepest of `pinned` that holds `path`, else `path` itself.
function Folders.owner(path, pinned)
	local best, length = path, -1
	for _, folder in pinned do
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

-- A folder's label in two parts: its dimmed parent (trailing slash included, may
-- be cut to fit) and its name, which always stays whole: "~/exo" → "~/", "exo".
function Folders.parts(path, home)
	local short = Folders.short(path, home)
	local prefix, name = string.match(short, "^(.*/)([^/]+)$")
	if not prefix then return "", short end
	return prefix, name
end

function Folders.unhex(hex)
	if not hex or #hex % 2 ~= 0 or string.find(hex, "%X") then return nil end
	return (string.gsub(hex, "..", function(byte)
		return string.char(tonumber(byte, 16))
	end))
end

assert(Folders.norm("/a/b//") == "/a/b" and Folders.norm("///") == "/" and Folders.norm(nil) == "")
assert(Folders.basename("/Volumes/VINH MAC/it's here/") == "it's here")
assert(Folders.short("/Users/v/exo", "/Users/v") == "~/exo" and Folders.short("/Users/v", "/Users/v") == "~")
assert(Folders.short("/Users/vv", "/Users/v") == "/Users/vv")
assert(Folders.within("/p/a", "/p") and not Folders.within("/pa", "/p") and Folders.within("/x", "/"))
assert(Folders.owner("/p/a/b", { "/p/a", "/p", "/q" }) == "/p/a" and Folders.owner("/x", { "/p" }) == "/x")
assert(Folders.owner("/p", { "/", "/p" }) == "/p")
assert(Folders.relative("/p/a/b", "/p") == "a/b" and Folders.relative("/a", "/") == "a")
assert(Folders.unhex(Folders.hex("/tmp/sf-test dir/it's here")) == "/tmp/sf-test dir/it's here")
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

return Folders
