-- src/render/fonts.lua
-- Fonts by schema id (type.font / type.label_font) and size, loaded once.

local schema = require("src.config.juice_schema")

local Fonts = {}
local cache = {}
local files = {}
for _, f in ipairs(schema.fonts) do files[f.id] = f.file end

function Fonts.get(id, size)
  size = math.max(4, math.floor(size + 0.5))
  local key = tostring(id) .. ":" .. size
  if not cache[key] then
    local file = files[id]
    local ok, font = false, nil
    if file then ok, font = pcall(love.graphics.newFont, "assets/fonts/" .. file, size) end
    cache[key] = ok and font or love.graphics.newFont(size)
  end
  return cache[key]
end

return Fonts
