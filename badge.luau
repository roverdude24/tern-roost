--!nonstrict
-- A folder's badge: two initials on one of 8 colours that stays with its path.
local Badge = {}

local TONES = 8

-- Accented letters -> base letter: { base, lowercase forms, uppercase forms }. Covers Vietnamese in full.
local GROUPS = {
	{ "A", "àáảãạăằắẳẵặâầấẩẫậäåāą", "ÀÁẢÃẠĂẰẮẲẴẶÂẦẤẨẪẬÄÅĀĄ" },
	{ "E", "èéẻẽẹêềếểễệëēę", "ÈÉẺẼẸÊỀẾỂỄỆËĒĘ" },
	{ "I", "ìíỉĩịïī", "ÌÍỈĨỊÏĪ" },
	{ "O", "òóỏõọôồốổỗộơờớởỡợöøō", "ÒÓỎÕỌÔỒỐỔỖỘƠỜỚỞỠỢÖØŌ" },
	{ "U", "ùúủũụưừứửữựüū", "ÙÚỦŨỤƯỪỨỬỮỰÜŪ" },
	{ "Y", "ỳýỷỹỵÿ", "ỲÝỶỸỴŸ" },
	{ "D", "đð", "ĐÐ" },
	{ "C", "çćč", "ÇĆČ" },
	{ "N", "ñń", "ÑŃ" },
	{ "S", "śšß", "ŚŠ" },
	{ "Z", "źżž", "ŹŻŽ" },
	{ "L", "ł", "Ł" },
}
local FOLD = {}
for _, group in GROUPS do
	for _, forms in { group[2], group[3] } do
		for char in string.gmatch(forms, utf8.charpattern) do FOLD[char] = group[1] end
	end
end

-- Letters of scripts without case or accents (Greek/Cyrillic, kana, CJK, Hangul) and other Latin kept whole.
local function isLetter(cp)
	return (cp >= 0xC0 and cp <= 0x24F and cp ~= 0xD7 and cp ~= 0xF7) or (cp >= 0x370 and cp <= 0x52F)
		or (cp >= 0x3040 and cp <= 0x30FF) or (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xAC00 and cp <= 0xD7AF)
end

-- Words of a name as lists of characters; punctuation splits words, apostrophes don't ("VINH's" -> VINHS).
local function words(name)
	local result, word = {}, {}
	local function flush()
		if #word > 0 then table.insert(result, word) end
		word = {}
	end
	for char in string.gmatch(name, utf8.charpattern) do
		local ok, cp = pcall(utf8.codepoint, char)
		if not ok then
			flush()
		elseif char == "'" or char == "’" then
			-- joins
		elseif FOLD[char] then
			table.insert(word, FOLD[char])
		elseif (cp < 128 and string.find(char, "^%w$")) or isLetter(cp) then
			table.insert(word, char)
		else
			flush()
		end
	end
	flush()
	return result
end

-- "OMACHI MI Y TRON" -> "OT", "MAX D Collab" -> "MC", "exo" -> "EX", "Đẩy" -> "DA"; "" -> "?".
function Badge.initials(name)
	local list = words(if type(name) == "string" then name else "")
	if #list == 0 then return "?" end
	local result
	if #list == 1 then
		result = list[1][1] .. (list[1][2] or "")
	else
		result = list[1][1] .. list[#list][1]
	end
	return string.upper(result)
end

-- 32-bit FNV-1a of the path: a stable tone 1..8. Multiplying by 2^24 + 0x193 is split so every
-- intermediate stays below 2^53.
function Badge.color(path)
	local hash = 2166136261
	for index = 1, #(path or "") do
		hash = bit32.bxor(hash, string.byte(path, index))
		hash = (hash * 0x193 + (hash % 256) * 16777216) % 4294967296
	end
	return hash % TONES + 1
end

-- The CSS role for a path's tone; style it with the block below.
function Badge.role(path)
	return "roost.badge" .. tostring(Badge.color(path))
end

--[[ Paste into styles.css (colours are the Radix hues the existing roost.hue* rules use):
[data-role^='roost.badge'] {
  flex-shrink: 0;
  min-width: 22px;
  padding: 1px 4px;
  border-radius: 6px;
  font-size: 0.72em;
  font-weight: 700;
  line-height: 1.5;
  text-align: center;
  letter-spacing: 0.02em;
}
[data-role='roost.badge1'] { color: #e5484d; background: color-mix(in srgb, #e5484d 18%, transparent); }
[data-role='roost.badge2'] { color: #f76b15; background: color-mix(in srgb, #f76b15 18%, transparent); }
[data-role='roost.badge3'] { color: #d6a100; background: color-mix(in srgb, #d6a100 18%, transparent); }
[data-role='roost.badge4'] { color: #46a758; background: color-mix(in srgb, #46a758 18%, transparent); }
[data-role='roost.badge5'] { color: #12a594; background: color-mix(in srgb, #12a594 18%, transparent); }
[data-role='roost.badge6'] { color: #3e63dd; background: color-mix(in srgb, #3e63dd 18%, transparent); }
[data-role='roost.badge7'] { color: #6e56cf; background: color-mix(in srgb, #6e56cf 18%, transparent); }
[data-role='roost.badge8'] { color: #d6409f; background: color-mix(in srgb, #d6409f 18%, transparent); }
]]

assert(Badge.initials("OMACHI MI Y TRON") == "OT" and Badge.initials("MAX D Collab") == "MC")
assert(Badge.initials("exo") == "EX" and Badge.initials("x") == "X" and Badge.initials("rt-git-test") == "RT")
assert(Badge.initials("Đẩy") == "DA" and Badge.initials("Đẩy nhanh Ồ") == "DO" and Badge.initials("ưu tiên") == "UT")
assert(Badge.initials("2026 Sales") == "2S" and Badge.initials("VINH's WORKS") == "VW" and Badge.initials("it's") == "IT")
assert(Badge.initials("") == "?" and Badge.initials("--- !!") == "?" and Badge.initials(nil) == "?" and Badge.initials("日本 語") == "日語")
assert(Badge.initials("\xff\xfe") == "?")
assert(Badge.color("/a") == Badge.color("/a") and Badge.color("") >= 1 and Badge.color("/Volumes/VINH MAC/x") <= TONES)
-- FNV-1a 32 reference values: "" -> 0x811c9dc5, "a" -> 0xe40c292c, "foobar" -> 0xbf9cf968.
assert(Badge.color("a") == 0xe40c292c % TONES + 1 and Badge.color("foobar") == 0xbf9cf968 % TONES + 1)
assert(Badge.color("") == 0x811c9dc5 % TONES + 1 and Badge.role("a") == "roost.badge" .. tostring(0xe40c292c % TONES + 1))

return Badge
