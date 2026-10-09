-- lib/json.lua
-- Dependency-free JSON encode/decode for LuaJIT / Lua 5.1+.
-- Pretty-prints with sorted keys so juice.json diffs stay readable.
--
-- Notes:
--   * JSON null decodes to json.null (a unique sentinel table).
--   * Empty Lua tables encode as [] unless tagged with json.object(t).
--   * Arrays are tables whose keys are exactly 1..n.

local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end, __name = "json.null" })

local OBJECT_MT = { __jsontype = "object" }
function json.object(t)
  return setmetatable(t or {}, OBJECT_MT)
end

------------------------------------------------------------------------
-- Encoding
------------------------------------------------------------------------

local escape_map = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function escape_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escape_map[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function is_array(t)
  local mt = getmetatable(t)
  if mt and mt.__jsontype == "object" then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
    n = n + 1
  end
  return n == #t
end

local function encode_number(n)
  if n ~= n then error("json: cannot encode NaN") end
  if n == math.huge or n == -math.huge then error("json: cannot encode infinity") end
  if math.floor(n) == n and math.abs(n) < 1e15 then
    return string.format("%d", n)
  end
  return string.format("%.14g", n)
end

local encode_value

local function encode_table(t, indent, depth, seen)
  if seen[t] then error("json: circular reference") end
  seen[t] = true
  local pretty = indent ~= nil
  local pad = pretty and string.rep(indent, depth + 1) or ""
  local closepad = pretty and string.rep(indent, depth) or ""
  local nl = pretty and "\n" or ""
  local sep = pretty and ": " or ":"
  local out = {}

  if is_array(t) then
    if #t == 0 then seen[t] = nil; return "[]" end
    for i = 1, #t do
      out[#out + 1] = pad .. encode_value(t[i], indent, depth + 1, seen)
    end
    seen[t] = nil
    return "[" .. nl .. table.concat(out, "," .. nl) .. nl .. closepad .. "]"
  end

  local keys = {}
  for k in pairs(t) do
    if type(k) ~= "string" then error("json: object keys must be strings, got " .. type(k)) end
    keys[#keys + 1] = k
  end
  if #keys == 0 then seen[t] = nil; return "{}" end
  table.sort(keys)
  for _, k in ipairs(keys) do
    out[#out + 1] = pad .. escape_string(k) .. sep .. encode_value(t[k], indent, depth + 1, seen)
  end
  seen[t] = nil
  return "{" .. nl .. table.concat(out, "," .. nl) .. nl .. closepad .. "}"
end

encode_value = function(v, indent, depth, seen)
  local tv = type(v)
  if v == json.null or v == nil then return "null"
  elseif tv == "boolean" then return tostring(v)
  elseif tv == "number" then return encode_number(v)
  elseif tv == "string" then return escape_string(v)
  elseif tv == "table" then return encode_table(v, indent, depth, seen)
  else error("json: cannot encode type " .. tv) end
end

--- Encode a value. opts.indent = "  " for pretty output (default compact).
function json.encode(v, opts)
  local indent = opts and opts.indent or nil
  return encode_value(v, indent, 0, {})
end

------------------------------------------------------------------------
-- Decoding
------------------------------------------------------------------------

local function decode_error(str, pos, msg)
  local line, col = 1, 1
  for i = 1, pos - 1 do
    if str:sub(i, i) == "\n" then line = line + 1; col = 1 else col = col + 1 end
  end
  error(string.format("json: %s at line %d col %d", msg, line, col), 0)
end

local function skip_ws(str, pos)
  local _, e = str:find("^[ \t\r\n]*", pos)
  return e + 1
end

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  else
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
      0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
end

local unescape_map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function decode_string(str, pos)
  -- pos points at the opening quote
  local out = {}
  local i = pos + 1
  while true do
    local c = str:sub(i, i)
    if c == "" then decode_error(str, pos, "unterminated string") end
    if c == '"' then return table.concat(out), i + 1 end
    if c == "\\" then
      local e = str:sub(i + 1, i + 1)
      if e == "u" then
        local hex = str:sub(i + 2, i + 5)
        if not hex:match("^%x%x%x%x$") then decode_error(str, i, "bad unicode escape") end
        local cp = tonumber(hex, 16)
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          local lo = str:match("^\\u(%x%x%x%x)", i)
          if lo then
            local locp = tonumber(lo, 16)
            if locp >= 0xDC00 and locp <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (locp - 0xDC00)
              i = i + 6
            end
          end
        end
        out[#out + 1] = utf8_char(cp)
      else
        local r = unescape_map[e]
        if not r then decode_error(str, i, "bad escape \\" .. e) end
        out[#out + 1] = r
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

local decode_value

local function decode_array(str, pos)
  local arr = {}
  pos = skip_ws(str, pos + 1)
  if str:sub(pos, pos) == "]" then return arr, pos + 1 end
  while true do
    local v
    v, pos = decode_value(str, pos)
    arr[#arr + 1] = v
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == "]" then return arr, pos + 1 end
    if c ~= "," then decode_error(str, pos, "expected ',' or ']'") end
    pos = skip_ws(str, pos + 1)
  end
end

local function decode_object(str, pos)
  local obj = {}
  pos = skip_ws(str, pos + 1)
  if str:sub(pos, pos) == "}" then return json.object(obj), pos + 1 end
  while true do
    if str:sub(pos, pos) ~= '"' then decode_error(str, pos, "expected string key") end
    local k
    k, pos = decode_string(str, pos)
    pos = skip_ws(str, pos)
    if str:sub(pos, pos) ~= ":" then decode_error(str, pos, "expected ':'") end
    pos = skip_ws(str, pos + 1)
    local v
    v, pos = decode_value(str, pos)
    obj[k] = v
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == "}" then return obj, pos + 1 end
    if c ~= "," then decode_error(str, pos, "expected ',' or '}'") end
    pos = skip_ws(str, pos + 1)
  end
end

local literals = { ["true"] = true, ["false"] = false, ["null"] = json.null }

decode_value = function(str, pos)
  pos = skip_ws(str, pos)
  local c = str:sub(pos, pos)
  if c == "{" then return decode_object(str, pos)
  elseif c == "[" then return decode_array(str, pos)
  elseif c == '"' then return decode_string(str, pos)
  elseif c == "-" or c:match("%d") then
    local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    local n = tonumber(num)
    if not n then decode_error(str, pos, "bad number") end
    return n, pos + #num
  else
    for lit, val in pairs(literals) do
      if str:sub(pos, pos + #lit - 1) == lit then return val, pos + #lit end
    end
    if c == "" then decode_error(str, pos, "unexpected end of input") end
    decode_error(str, pos, "unexpected character: " .. c)
  end
end

--- Decode a JSON string. Raises on malformed input.
function json.decode(str)
  if type(str) ~= "string" then error("json.decode expects a string, got " .. type(str)) end
  local v, pos = decode_value(str, 1)
  pos = skip_ws(str, pos)
  if pos <= #str then decode_error(str, pos, "trailing garbage") end
  return v
end

--- Safe variant: returns value, nil or nil, err.
function json.try_decode(str)
  local ok, res = pcall(json.decode, str)
  if ok then return res, nil end
  return nil, res
end

return json
