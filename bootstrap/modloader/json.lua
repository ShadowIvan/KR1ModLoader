-- Minimal JSON parser for mod.json: strings, numbers, true/false/null, arrays,
-- objects. On error returns nil plus a message with the line number, so a mod
-- author knows where to look.

local J = {}

local function skip_ws(s, i)
	return s:match("^[ \t\r\n]*()", i)
end

local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function utf8_char(code)
	if code < 0x80 then return string.char(code) end
	if code < 0x800 then
		return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
	end
	return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local parse_value

local function parse_string(s, i)
	-- i points at the opening quote
	local out, j = {}, i + 1
	while true do
		local c = s:sub(j, j)
		if c == "" then return nil, j, "unterminated string" end
		if c == '"' then return table.concat(out), j + 1 end
		if c == "\\" then
			local e = s:sub(j + 1, j + 1)
			if e == "u" then
				local hex = s:sub(j + 2, j + 5)
				if not hex:match("^%x%x%x%x$") then return nil, j, "bad \\u escape" end
				out[#out + 1] = utf8_char(tonumber(hex, 16))
				j = j + 6
			elseif escapes[e] then
				out[#out + 1] = escapes[e]
				j = j + 2
			else
				return nil, j, "unknown escape \\" .. e
			end
		else
			out[#out + 1] = c
			j = j + 1
		end
	end
end

local function parse_array(s, i)
	local arr, j = {}, skip_ws(s, i + 1)
	if s:sub(j, j) == "]" then return arr, j + 1 end
	while true do
		local v, nj, err = parse_value(s, j)
		if err then return nil, nj, err end
		arr[#arr + 1] = v
		j = skip_ws(s, nj)
		local c = s:sub(j, j)
		if c == "," then
			j = skip_ws(s, j + 1)
		elseif c == "]" then
			return arr, j + 1
		else
			return nil, j, "expected ',' or ']'"
		end
	end
end

local function parse_object(s, i)
	local obj, j = {}, skip_ws(s, i + 1)
	if s:sub(j, j) == "}" then return obj, j + 1 end
	while true do
		if s:sub(j, j) ~= '"' then return nil, j, "expected a quoted key" end
		local key, nj, err = parse_string(s, j)
		if err then return nil, nj, err end
		j = skip_ws(s, nj)
		if s:sub(j, j) ~= ":" then return nil, j, "expected ':'" end
		local v
		v, nj, err = parse_value(s, skip_ws(s, j + 1))
		if err then return nil, nj, err end
		obj[key] = v
		j = skip_ws(s, nj)
		local c = s:sub(j, j)
		if c == "," then
			j = skip_ws(s, j + 1)
		elseif c == "}" then
			return obj, j + 1
		else
			return nil, j, "expected ',' or '}'"
		end
	end
end

parse_value = function(s, i)
	local c = s:sub(i, i)
	if c == "{" then return parse_object(s, i) end
	if c == "[" then return parse_array(s, i) end
	if c == '"' then return parse_string(s, i) end
	if s:sub(i, i + 3) == "true" then return true, i + 4 end
	if s:sub(i, i + 4) == "false" then return false, i + 5 end
	if s:sub(i, i + 3) == "null" then return nil, i + 4 end
	local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
	if num and num ~= "" and num ~= "-" then
		local n = tonumber(num)
		if n then return n, i + #num end
	end
	return nil, i, "unexpected character '" .. c .. "'"
end

-- Returns the value (usually a table) or nil + an error message.
function J.decode(s)
	if type(s) ~= "string" then return nil, "not a string" end
	-- UTF-8 BOM, e.g. a file saved by Notepad
	if s:sub(1, 3) == "\239\187\191" then s = s:sub(4) end
	local i = skip_ws(s, 1)
	local v, j, err = parse_value(s, i)
	if err then
		local _, newlines = s:sub(1, j):gsub("\n", "")
		return nil, string.format("%s (line %d)", err, newlines + 1)
	end
	j = skip_ws(s, j)
	if j <= #s then return nil, "trailing data after JSON" end
	return v
end

return J
