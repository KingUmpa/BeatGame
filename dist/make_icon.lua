-- dist/make_icon.lua
-- Draws the app icon, assets/images/icon.png, with the game's own board: the four pads lit in
-- their colors on the dark screen. dist/app_icon.py rounds it off for the Windows and Mac builds.
--
--   lovec . --run=dist/make_icon.lua

local Juice = require("src.config.juice")
local Pads = require("src.render.pads")
local Level = require("src.game.level")
local util = require("src.util")

local SIZE = 1024

return function(_, t)
  if t < 0.3 then return end
  -- the board as the game draws it, without the key letters
  local J = setmetatable({ layout = setmetatable({ show_key_labels = false }, { __index = Juice.data.layout }) },
    { __index = Juice.data })
  local L = J.layout
  local canvas = love.graphics.newCanvas(SIZE, SIZE)
  love.graphics.push("all")
  love.graphics.setCanvas({ canvas, stencil = true })
  love.graphics.clear(L.background)
  love.graphics.origin()
  local span = L.board_size + 2 * L.frame_padding
  local scale = SIZE / span * 0.86
  love.graphics.translate(SIZE / 2, SIZE / 2)
  love.graphics.scale(scale)
  love.graphics.translate(-L.board_x, -L.board_y)
  local pads = {}
  for i = 1, 4 do
    pads[i] = { color = Level.DEFAULT_COLORS[i], level = 1.25, press = 0, punch = 0, white = 0.08, tint = 0.85 }
  end
  Pads.draw(J, { pads = pads })
  love.graphics.pop()
  local png = canvas:newImageData():encode("png")
  local ok, err = util.writeFile("assets/images/icon.png", png:getString())
  print(ok and "wrote assets/images/icon.png" or ("failed: " .. tostring(err)))
  return true
end
