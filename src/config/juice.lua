-- src/config/juice.lua
-- Loads, validates, hot-reloads and writes juice.json against juice_schema.lua.
-- (Same design as CounterCatch's juice loader.)
--
--   local Juice = require("src.config.juice")
--   Juice.load()                       -- reads juice.json (missing keys -> defaults)
--   Juice.data.timing.good_ms          -- validated values; the table stays the same object
--   Juice.set("timing.good_ms", 90)    -- validated live change (the editor's sliders)
--   Juice.onChange(function(keys) end) -- after a reload or a set
--   Juice.update(dt)                   -- polls the file for hot reload
--   Juice.write()                      -- writes every key back to juice.json

local json = require("lib.json")
local schema = require("src.config.juice_schema")
local util = require("src.util")

local Juice = {}
Juice.data = {}
Juice.path = "juice.json"
Juice.issues = {}
Juice.schema = schema

local listeners = {}
local pollClock, lastModTime = 0, nil

Juice.byKey = {}
for _, e in ipairs(schema.entries) do Juice.byKey[e.key] = e end

function Juice.defaults()
  local t = {}
  for _, e in ipairs(schema.entries) do util.setPath(t, e.key, util.deepcopy(e.default)) end
  return t
end

local function isColor(v)
  if type(v) ~= "table" or (#v ~= 3 and #v ~= 4) then return false end
  for i = 1, #v do
    if type(v[i]) ~= "number" or v[i] < 0 or v[i] > 1 then return false end
  end
  return true
end

-- returns the validated value and an issue string (or nil)
function Juice.validateEntry(e, v)
  if v == nil or v == json.null then return util.deepcopy(e.default), nil end
  local t = e.type
  if t == "number" or t == "int" then
    if type(v) ~= "number" then
      return util.deepcopy(e.default), ("%s: expected a number, got %s"):format(e.key, type(v))
    end
    local out = t == "int" and math.floor(v + 0.5) or v
    if e.min and out < e.min then return e.min, ("%s: %s below min %s, clamped"):format(e.key, v, e.min) end
    if e.max and out > e.max then return e.max, ("%s: %s above max %s, clamped"):format(e.key, v, e.max) end
    return out, nil
  elseif t == "bool" then
    if type(v) ~= "boolean" then return e.default, ("%s: expected true/false"):format(e.key) end
    return v, nil
  elseif t == "enum" then
    if not util.contains(e.values, v) then
      return e.default, ("%s: '%s' not one of [%s]"):format(e.key, tostring(v), table.concat(e.values, ", "))
    end
    return v, nil
  elseif t == "color" then
    if not isColor(v) then return util.deepcopy(e.default), ("%s: expected [r,g,b] with 0-1 values"):format(e.key) end
    return util.deepcopy(v), nil
  end
  return v, nil
end

local function collectUnknown(raw, prefix, out)
  for k, v in pairs(raw) do
    local path = prefix and (prefix .. "." .. k) or k
    if not Juice.byKey[path] and k ~= "_comment" then
      if type(v) == "table" and not util.isArray(v) then
        collectUnknown(v, path, out)
      else
        out[#out + 1] = path
      end
    end
  end
end

function Juice.validate(raw)
  local data, issues = {}, {}
  for _, e in ipairs(schema.entries) do
    local v = util.getPath(raw, e.key)
    local value, issue = Juice.validateEntry(e, v)
    if v == nil then issues[#issues + 1] = e.key .. ": missing, using default"
    elseif issue then issues[#issues + 1] = issue end
    util.setPath(data, e.key, value)
  end
  local unknown = {}
  collectUnknown(raw, nil, unknown)
  for _, path in ipairs(unknown) do
    -- kept, so a file from a newer build survives an older one
    util.setPath(data, path, util.deepcopy(util.getPath(raw, path)))
    issues[#issues + 1] = path .. ": not in schema (kept)"
  end
  return data, issues
end

local function apply(data, issues)
  -- refill the same table so modules holding Juice.data see the new values
  for k in pairs(Juice.data) do Juice.data[k] = nil end
  for k, v in pairs(data) do Juice.data[k] = v end
  Juice.issues = issues
end

local function emit(keys)
  for _, fn in ipairs(listeners) do fn(keys) end
end

function Juice.onChange(fn) listeners[#listeners + 1] = fn end

local function readRaw()
  local text = util.readFile(Juice.path)
  if not text then return nil, "no " .. Juice.path .. ", using defaults" end
  local raw, err = json.try_decode(text)
  if not raw then return nil, Juice.path .. ": " .. tostring(err) end
  return raw
end

function Juice.load(path)
  Juice.path = path or Juice.path
  local raw, err = readRaw()
  local data, issues = Juice.validate(raw or {})
  if err then table.insert(issues, 1, err) end
  apply(data, issues)
  for _, msg in ipairs(issues) do print("juice: " .. msg) end
  lastModTime = util.fileModTime(Juice.path)
  return Juice.data
end

function Juice.reload()
  local raw, err = readRaw()
  if not raw then print("juice: reload failed: " .. tostring(err)); return false end
  local before = json.encode(Juice.data)
  local data, issues = Juice.validate(raw)
  apply(data, issues)
  if json.encode(Juice.data) ~= before then
    print("juice: reloaded " .. Juice.path)
    emit({})
  end
  return true
end

function Juice.update(dt)
  local hr = Juice.data.hot_reload
  if not hr or not hr.enabled then return end
  pollClock = pollClock + dt
  if pollClock < hr.poll_interval_s then return end
  pollClock = 0
  local mt = util.fileModTime(Juice.path)
  if mt and mt ~= lastModTime then
    lastModTime = mt
    Juice.reload()
  end
end

function Juice.get(key) return util.getPath(Juice.data, key) end

function Juice.set(key, value)
  local e = Juice.byKey[key]
  if e then value = Juice.validateEntry(e, value) end
  util.setPath(Juice.data, key, value)
  emit({ key })
end

-- every schema key, in schema order, as pretty JSON
function Juice.serialize(data)
  data = data or Juice.data
  local out = {}
  for _, e in ipairs(schema.entries) do util.setPath(out, e.key, util.deepcopy(util.getPath(data, e.key))) end
  out.schema_version = schema.version
  return json.encode(out, { indent = "  " }) .. "\n"
end

function Juice.write()
  local text = Juice.serialize()
  local ok, err = util.writeFile(Juice.path, text)
  if ok then lastModTime = util.fileModTime(Juice.path) end
  return ok, err
end

return Juice
