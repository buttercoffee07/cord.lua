local Serialize = {}

local DEFAULT_MAX_DEPTH = 8

local function isIdentifier(text)
	return type(text) == "string" and text:match("^[%a_][%w_]*$") ~= nil
end

local function keySort(a, b)
	local typeA = type(a)
	local typeB = type(b)
	if typeA ~= typeB then
		return typeA < typeB
	end

	if typeA == "number" then
		return a < b
	end

	if typeA == "string" then
		return a < b
	end

	return tostring(a) < tostring(b)
end

local function encode(value, depth, seen)
	local kind = type(value)
	if kind == "nil" then
		return "nil"
	end

	if kind == "boolean" or kind == "number" then
		return tostring(value)
	end

	if kind == "string" then
		return string.format("%q", value)
	end

	if kind ~= "table" then
		return "<" .. kind .. ">"
	end

	if seen[value] then
		return "<cycle>"
	end

	if depth <= 0 then
		return "<max-depth>"
	end

	seen[value] = true

	local parts = {}
	local arrayCount = #value

	for i = 1, arrayCount do
		parts[#parts + 1] = encode(value[i], depth - 1, seen)
	end

	local keys = {}
	for key in pairs(value) do
		local isArrayKey = type(key) == "number" and key >= 1 and key <= arrayCount and key % 1 == 0
		if not isArrayKey then
			keys[#keys + 1] = key
		end
	end

	table.sort(keys, keySort)

	for i = 1, #keys do
		local key = keys[i]
		local keyText
		if isIdentifier(key) then
			keyText = key
		else
			keyText = "[" .. encode(key, depth - 1, seen) .. "]"
		end

		parts[#parts + 1] = keyText .. " = " .. encode(value[key], depth - 1, seen)
	end

	seen[value] = nil

	if #parts == 0 then
		return "{}"
	end

	return "{" .. table.concat(parts, ", ") .. "}"
end

function Serialize.value(value, opts)
	opts = opts or {}
	local depth = tonumber(opts.maxDepth) or DEFAULT_MAX_DEPTH
	if depth < 0 then
		depth = 0
	end

	return encode(value, depth, {})
end

return Serialize
