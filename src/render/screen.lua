-- src/render/screen.lua
-- The game draws at a fixed virtual size into a canvas, which is scaled (letterboxed) into
-- a viewport: the whole window in the game, a pane in the juice editor.
--
--   local s = Screen.new(1280, 800)
--   s:setViewport(x, y, w, h)
--   s:begin() ... draw in virtual pixels ... s:finish()
--   local vx, vy = s:toVirtual(mouseX, mouseY)

local Screen = {}
Screen.__index = Screen

function Screen.new(w, h)
  local s = setmetatable({ W = w, H = h }, Screen)
  s.canvas = love.graphics.newCanvas(w, h, { msaa = 4 })
  s:setViewport(0, 0, love.graphics.getWidth(), love.graphics.getHeight())
  return s
end

function Screen:setViewport(x, y, w, h)
  self.vx, self.vy, self.vw, self.vh = x, y, w, h
  self.scale = math.min(w / self.W, h / self.H)
  self.ox = x + (w - self.W * self.scale) / 2
  self.oy = y + (h - self.H * self.scale) / 2
end

function Screen:begin(bg)
  love.graphics.push("all")
  love.graphics.setCanvas({ self.canvas, stencil = true })
  love.graphics.origin()
  love.graphics.clear(bg[1], bg[2], bg[3], 1, true, 0)
end

function Screen:finish()
  love.graphics.setCanvas()
  love.graphics.pop()
  love.graphics.push("all")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("alpha", "premultiplied")
  love.graphics.draw(self.canvas, self.ox, self.oy, 0, self.scale, self.scale)
  love.graphics.pop()
end

function Screen:toVirtual(x, y)
  return (x - self.ox) / self.scale, (y - self.oy) / self.scale
end

function Screen:contains(x, y)
  return x >= self.ox and y >= self.oy and x < self.ox + self.W * self.scale and y < self.oy + self.H * self.scale
end

return Screen
