-- src/util.lua
-- Small helpers shared by the game, the editors and the tests.

local util = {}

function util.clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end

function util.clamp01(v) return util.clamp(v, 0, 1) end
function util.lerp(a, b, t) return a + (b - a) * t end

function util.inverseLerp(a, b, v)
  if a == b then return 0 end
  return (v - a) / (b - a)
end

function util.round(v) return math.floor(v + 0.5) end

function util.lerpColor(a, b, t)
  return { util.lerp(a[1], b[1], t), util.lerp(a[2], b[2], t), util.lerp(a[3], b[3], t) }
end

function util.deepcopy(t, seen)
  if type(t) ~= "table" then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end
  local out = {}
  seen[t] = out
  for k, v in pairs(t) do out[util.deepcopy(k, seen)] = util.deepcopy(v, seen) end
  return setmetatable(out, getmetatable(t))
end

function util.isArray(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t and n > 0
end

function util.split(s, sep)
  local out = {}
  for piece in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = piece end
  return out
end

-- dotted path access: util.getPath(t, "a.b.c")
function util.getPath(t, path)
  local node = t
  for _, key in ipairs(util.split(path, ".")) do
    if type(node) ~= "table" then return nil end
    node = node[key]
  end
  return node
end

function util.setPath(t, path, value)
  local keys = util.split(path, ".")
  local node = t
  for i = 1, #keys - 1 do
    local k = keys[i]
    if type(node[k]) ~= "table" then node[k] = {} end
    node = node[k]
  end
  node[keys[#keys]] = value
end

function util.contains(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

-- Reads a whole file. Paths inside the game folder go through love.filesystem; anything
-- else (an absolute path into an Ableton project, say) falls back to io.open.
function util.readFile(path)
  if love and love.filesystem and love.filesystem.getInfo(path, "file") then
    return love.filesystem.read(path)
  end
  local f = io.open(path, "rb")
  if not f then return nil, "cannot open " .. path end
  local s = f:read("*a")
  f:close()
  return s
end

function util.fileModTime(path)
  if love and love.filesystem then
    local info = love.filesystem.getInfo(path, "file")
    if info then return info.modtime end
  end
  return nil
end

-- The project folder on disk, for writing files next to the code (love.filesystem can only
-- write to the save folder).
function util.projectDir()
  return (love.filesystem.getRealDirectory("main.lua") or love.filesystem.getSource())
end

function util.writeFile(rel, data)
  local f, err = io.open(util.projectDir() .. "/" .. rel, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  return true
end

function util.hasArg(args, name)
  for _, a in ipairs(args or {}) do
    if a == name or a:sub(1, #name + 1) == name .. "=" then return true end
  end
  return false
end

-- "--name=value" -> value; "--name" alone -> true; missing -> default
function util.argValue(args, name, default)
  for _, a in ipairs(args or {}) do
    if a == name then return true end
    if a:sub(1, #name + 1) == name .. "=" then return a:sub(#name + 2) end
  end
  return default
end

function util.basename(path)
  return path:match("([^/\\]+)$") or path
end

return util
