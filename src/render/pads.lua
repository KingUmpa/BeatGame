-- src/render/pads.lua
-- The 2x2 drum pad board: grey rubber pads with RGB LEDs underneath. Everything about the
-- look comes from juice (layout.*, pads.*, lights.*); what each pad is doing right now
-- comes from the caller:
--
--   Pads.draw(J, {
--     pads = { [i] = { color = {r,g,b}, level = 0..2, press = 0..1, punch = 0..1, white = 0..1,
--                      pop = 0..1 (grow by this fraction, regardless of feel.hit_punch),
--                      tint = 0..1 (how much the light colors the face: pads.translucency if absent) } },
--     shakeX = 0, shakeY = 0,
--   })
--   Pads.rects(J)            -> the four pad rectangles, in virtual pixels
--   Pads.hit(J, x, y)        -> pad number under a virtual point, or nil
--
-- level is the light's brightness: 0 off, 1 full. The halo, the light leaking round the
-- edge and the tint through the rubber all scale with it.

local Level = require("src.game.level")
local Fonts = require("src.render.fonts")

local Pads = {}

function Pads.rects(J)
  local L = J.layout
  local S, gap = L.board_size, L.pad_gap
  local p = (S - gap) / 2
  local x0, y0 = L.board_x - S / 2, L.board_y - S / 2
  return {
    { x = x0, y = y0, w = p, h = p },
    { x = x0 + p + gap, y = y0, w = p, h = p },
    { x = x0, y = y0 + p + gap, w = p, h = p },
    { x = x0 + p + gap, y = y0 + p + gap, w = p, h = p },
  }
end

function Pads.hit(J, x, y)
  for i, r in ipairs(Pads.rects(J)) do
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then return i end
  end
  return nil
end

-- A white soft glow the shape of a rounded pad, faded over `glow` pixels past its edge.
-- Rebuilt only when the pad size, corner or glow size changes.
local glowCache = {}
local function glowImage(size, corner, glow)
  local key = ("%d:%d:%d"):format(size, corner, glow)
  if glowCache.key == key then return glowCache.img, glowCache.span end
  local span = size + 2 * glow
  local res = math.max(16, math.min(384, math.ceil(span / 2)))
  local data = love.image.newImageData(res, res)
  local half, c = size / 2, math.min(corner, size / 2)
  for py = 0, res - 1 do
    for px = 0, res - 1 do
      -- position in virtual pixels from the pad's center
      local x = ((px + 0.5) / res - 0.5) * span
      local y = ((py + 0.5) / res - 0.5) * span
      local qx, qy = math.abs(x) - (half - c), math.abs(y) - (half - c)
      local out = math.sqrt(math.max(qx, 0) ^ 2 + math.max(qy, 0) ^ 2) + math.min(math.max(qx, qy), 0) - c
      local a
      if out <= 0 then a = 1
      elseif glow <= 0 then a = 0
      else
        local k = math.max(0, 1 - out / glow)
        a = k * k * k
      end
      data:setPixel(px, py, 1, 1, 1, a)
    end
  end
  local img = love.graphics.newImage(data)
  img:setFilter("linear", "linear")
  glowCache = { key = key, img = img, span = span }
  return img, span
end

local function rrect(mode, x, y, w, h, r)
  love.graphics.rectangle(mode, x, y, w, h, r, r, 12)
end

function Pads.draw(J, look)
  local L, P, Li = J.layout, J.pads, J.lights
  local rects = Pads.rects(J)
  local sx, sy = look.shakeX or 0, look.shakeY or 0
  love.graphics.push()
  love.graphics.translate(sx, sy)

  -- the device body
  if L.frame then
    local S, m = L.board_size, L.frame_padding
    love.graphics.setColor(L.frame_color)
    rrect("fill", L.board_x - S / 2 - m, L.board_y - S / 2 - m, S + 2 * m, S + 2 * m, L.frame_corner)
    love.graphics.setColor(0, 0, 0, 0.35)
    love.graphics.setLineWidth(2)
    rrect("line", L.board_x - S / 2 - m + 1, L.board_y - S / 2 - m + 1, S + 2 * m - 2, S + 2 * m - 2, L.frame_corner)
  end

  local size = rects[1].w
  local glow = math.floor(Li.glow_size + 0.5)
  local img, span = glowImage(math.floor(size + 0.5), math.floor(P.corner + 0.5), glow)

  for i, r in ipairs(rects) do
    local s = look.pads[i] or {}
    local c = s.color or Level.DEFAULT_COLORS[i]
    local lvl = math.max(0, (s.level or 0) * Li.brightness)
    local press = s.press or 0
    local k = (1 - (1 - P.press_scale) * press) * (1 + J.feel.hit_punch * (s.punch or 0)) * (1 + (s.pop or 0))
    local cx, cy = r.x + r.w / 2, r.y + r.h / 2
    local w = r.w * k

    -- the halo, added onto whatever is underneath
    love.graphics.setBlendMode("add")
    if lvl > 0 and Li.glow_strength > 0 then
      love.graphics.setColor(c[1], c[2], c[3], math.min(1, lvl * Li.glow_strength))
      local sc = (span * k) / img:getWidth()
      love.graphics.draw(img, cx, cy, 0, sc, sc, img:getWidth() / 2, img:getHeight() / 2)
    end
    love.graphics.setBlendMode("alpha")

    -- rim and face
    local x, y = cx - w / 2, cy - w / 2
    love.graphics.setColor(P.rim_color)
    rrect("fill", x, y, w, w, P.corner * k)
    local inset = P.rim_width * k
    local fx, fy, fw = x + inset, y + inset, w - 2 * inset
    local dark = 1 - P.press_darken * press
    local base = { P.color[1] * dark, P.color[2] * dark, P.color[3] * dark }
    local t = math.min(1, (s.tint or P.translucency) * math.min(1, lvl))
    local face = {
      base[1] + (c[1] - base[1]) * t, base[2] + (c[2] - base[2]) * t, base[3] + (c[3] - base[3]) * t,
    }
    local white = s.white or 0
    face[1], face[2], face[3] = face[1] + (1 - face[1]) * white, face[2] + (1 - face[2]) * white, face[3] + (1 - face[3]) * white
    love.graphics.setColor(face)
    local fr = math.max(0, P.corner * k - inset)
    rrect("fill", fx, fy, fw, fw, fr)

    -- soft top highlight on the rubber, kept inside the face
    if P.highlight > 0 then
      love.graphics.stencil(function() rrect("fill", fx, fy, fw, fw, fr) end, "replace", 1)
      love.graphics.setStencilTest("greater", 0)
      local bands = 8
      for b = 0, bands - 1 do
        love.graphics.setColor(1, 1, 1, P.highlight * (1 - b / bands) * (1 - press * 0.6))
        love.graphics.rectangle("fill", fx, fy + b * fw * 0.06, fw, fw * 0.06)
      end
      love.graphics.setStencilTest()
    end

    -- light escaping round the pad's edge
    if lvl > 0 and Li.edge_bleed > 0 then
      love.graphics.setBlendMode("add")
      love.graphics.setColor(c[1], c[2], c[3], math.min(1, lvl * Li.edge_bleed * 0.8))
      love.graphics.setLineWidth(math.max(1, 3 * k))
      rrect("line", x - 2, y - 2, w + 4, w + 4, P.corner * k + 2)
      love.graphics.setBlendMode("alpha")
    end

    -- engraved key letter
    if L.show_key_labels then
      local f = Fonts.get(J.type.label_font, J.type.label_size * k)
      love.graphics.setFont(f)
      local lx, ly = fx + fw * 0.08, fy + fw * 0.06
      love.graphics.setColor(1, 1, 1, 0.08)
      love.graphics.print(Level.KEYS[i], lx, ly + 1)
      local lc = L.key_label_color
      love.graphics.setColor(lc[1], lc[2], lc[3], 1)
      love.graphics.print(Level.KEYS[i], lx, ly)
    end
  end
  love.graphics.pop()
end

return Pads
