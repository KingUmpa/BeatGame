-- src/tools/juice_ui.lua
-- The juice editor (same design as CounterCatch's Juice tuner): every juice.json key as a
-- control on the left, the real game running on the right. Changes apply instantly.
-- Scenario buttons drop the game into a moment (the demo, the player's turn, a wrong hit,
-- a failed round) and replay it; the audition buttons play a pad clean or wrong so the
-- Wrong Sound sliders can be heard as they move. SAVE writes juice.json, which a running
-- game picks up on its own (hot reload). LAUNCH GAME starts the real game.
--
--   love . --juice        (run juice)
--
-- Type to filter keys by name; Backspace clears. Mouse wheel over a slider nudges it one
-- step. Keys in orange only apply after a restart.

local Juice = require("src.config.juice")
local util = require("src.util")
local Game = require("src.game.game")

local UI = {}
UI.__index = UI

local PANEL_W = 620
local ROW_H = 30
local GAP = 8
local BOTTOM_H = 104

local SECTIONS = {
  { title = "LOOK", ids = { "layout", "type", "pads", "lights" } },
  { title = "GAME", ids = { "timing", "flow", "rules", "scoring", "wrong_sound", "feel", "audio", "song" } },
  { title = "META", ids = { "display", "hot_reload", "debug" } },
}

local COLORS = {
  panel = { 0.09, 0.1, 0.13 }, stripe = { 0.11, 0.12, 0.16 }, header = { 0.18, 0.2, 0.27 },
  text = { 0.88, 0.9, 0.94 }, dim = { 0.55, 0.57, 0.65 }, accent = { 1, 0.8, 0.35 },
  restart = { 0.95, 0.7, 0.4 }, track = { 0.16, 0.17, 0.22 }, fill = { 0.45, 0.62, 0.95 },
  button = { 0.2, 0.22, 0.28 }, selected = { 0.3, 0.45, 0.7 }, good = { 0.6, 1, 0.6 },
}

------------------------------------------------------------------------
-- widgets (immediate mode: drawn and hit-tested in the same pass)
------------------------------------------------------------------------

function UI:hit(x, y, w, h)
  return self.mx >= x and self.mx < x + w and self.my >= y and self.my < y + h
end

function UI:label(text, x, y, w, color, font)
  love.graphics.setFont(font or self.font)
  love.graphics.setColor(color or COLORS.text)
  love.graphics.printf(text, x, y, w or 1000, "left")
end

function UI:button(text, x, y, w, h, opts)
  opts = opts or {}
  local hot = self:hit(x, y, w, h)
  local bg = opts.accent and { 0.95, 0.72, 0.15 } or COLORS.button
  if opts.selected then bg = COLORS.selected end
  if hot then bg = { bg[1] + 0.08, bg[2] + 0.08, bg[3] + 0.08 } end
  love.graphics.setColor(bg)
  love.graphics.rectangle("fill", x, y, w, h, 5, 5)
  local f = opts.font or self.font
  love.graphics.setFont(f)
  love.graphics.setColor(opts.accent and { 0.1, 0.1, 0.1 } or { 0.95, 0.95, 0.97 })
  love.graphics.printf(text, x, y + (h - f:getHeight()) / 2, w, "center")
  return hot and self.clicked
end

local function snap(e, v)
  local step = e.step or (e.type == "int" and 1 or 0)
  if step > 0 then v = math.floor(v / step + 0.5) * step end
  if e.type == "int" then v = math.floor(v + 0.5) end
  return util.clamp(v, e.min or -math.huge, e.max or math.huge)
end

-- slider position <-> value, linear or logarithmic
local function toT(e, v, lo, hi)
  if e.log then return util.clamp01((math.log(v) - math.log(lo)) / (math.log(hi) - math.log(lo))) end
  return util.clamp01(util.inverseLerp(lo, hi, v))
end

local function fromT(e, t, lo, hi)
  if e.log then return math.exp(math.log(lo) + t * (math.log(hi) - math.log(lo))) end
  return util.lerp(lo, hi, t)
end

function UI:slider(id, x, y, w, h, v, lo, hi, e)
  local hot = self:hit(x, y - 5, w, h + 10)
  if self.mdown and (self.active == id or (hot and self.active == nil and self.justPressed)) then self.active = id end
  local t = toT(e, v, lo, hi)
  love.graphics.setColor(COLORS.track)
  love.graphics.rectangle("fill", x, y, w, h, h / 2, h / 2)
  love.graphics.setColor(self.active == id and COLORS.accent or COLORS.fill)
  love.graphics.rectangle("fill", x, y, math.max(h, w * t), h, h / 2, h / 2)
  love.graphics.setColor(1, 1, 1)
  love.graphics.circle("fill", x + w * t, y + h / 2, h * 0.8)
  if self.active == id then
    return snap(e, fromT(e, util.clamp01((self.mx - x) / w), lo, hi))
  end
  return nil
end

------------------------------------------------------------------------
-- rows
------------------------------------------------------------------------

function UI:sliderRange(e, v)
  local d = Juice.data.display
  local lo, hi = e.min or 0, e.max or math.max(1, math.abs(v) * 4)
  if e.unit == "x" then lo, hi = 0, d.virtual_width
  elseif e.unit == "y" then lo, hi = 0, d.virtual_height
  elseif e.unit == "px" then hi = math.min(e.max or hi, math.floor(d.virtual_height / 2))
  elseif not e.log and hi - lo > 2000 then hi = math.max(lo + 10, math.abs(v) * 4) end
  return math.min(lo, v), math.max(hi, v)
end

local function fmt(e, v)
  if e.type == "bool" then return v and "on" or "off" end
  if e.type == "int" then return tostring(math.floor(v + 0.5)) end
  if e.type == "number" then
    if (e.step or 1) >= 1 then return ("%d"):format(math.floor(v + 0.5)) end
    if (e.step or 1) >= 0.1 then return ("%.1f"):format(v) end
    return ("%.3g"):format(v)
  end
  return tostring(v)
end

local FONT_NAMES = {}
for _, f in ipairs(Juice.schema.fonts) do FONT_NAMES[f.id] = f.name end

function UI:drawRow(e, x, y, w)
  local v = util.getPath(Juice.data, e.key)
  local lr = self.listRect
  local hot = self:hit(x, y, w, ROW_H) and self.my >= lr.y and self.my < lr.y + lr.h
  if hot then self.hoverEntry = e end
  self:label(e.key:match("([^.]+)$"), x, y + 7, 230, e.restart and COLORS.restart or nil)
  local cx, cw, vx = x + 232, w - 232 - 88, x + w - 80
  if e.type == "number" or e.type == "int" then
    local lo, hi = self:sliderRange(e, v)
    local nv = self:slider(e.key, cx, y + 10, cw, 10, v, lo, hi, e)
    if nv ~= nil and nv ~= v then Juice.set(e.key, nv) end
    self:label(fmt(e, v), vx, y + 7, 80, { 1, 1, 1 })
  elseif e.type == "bool" then
    if self:button(v and "ON" or "OFF", cx, y + 3, 80, ROW_H - 6, { selected = v }) then Juice.set(e.key, not v) end
  elseif e.type == "enum" then
    if self:button((FONT_NAMES[v] or v) .. "   v", cx, y + 3, cw, ROW_H - 6, { font = self.fontSmall }) then
      self.dropdown = { e = e, x = cx, y = y + ROW_H - 3, w = cw }
    end
  elseif e.type == "color" then
    local sw = (cw - 16) / 3
    for c = 1, 3 do
      local sx = cx + (c - 1) * (sw + 8)
      local nv = self:slider(e.key .. c, sx, y + 10, sw, 10, v[c], 0, 1, { step = 0.01 })
      if nv ~= nil and nv ~= v[c] then
        local col = { v[1], v[2], v[3] }
        col[c] = nv
        Juice.set(e.key, col)
      end
    end
    love.graphics.setColor(v[1], v[2], v[3])
    love.graphics.rectangle("fill", vx, y + 5, 70, ROW_H - 10, 4, 4)
  end
end

function UI:rows()
  local out, lastSub = {}, nil
  local q = self.search ~= "" and self.search:lower() or nil
  for _, e in ipairs(Juice.schema.entries) do
    local g = e.key:match("^([^.]+)%.")
    if g and ((q and e.key:lower():find(q, 1, true)) or (not q and g == self.group)) then
      if q and g ~= lastSub then
        out[#out + 1] = { header = g:upper():gsub("_", " ") }
        lastSub = g
      end
      out[#out + 1] = { e = e }
    end
  end
  return out
end

------------------------------------------------------------------------
-- panel
------------------------------------------------------------------------

function UI:dirty() return Juice.serialize() ~= self.savedText end

function UI:say(msg) self.message, self.messageT = msg, 4 end

function UI:save()
  local ok, err = Juice.write()
  if ok then
    self.savedText = Juice.serialize()
    self:say("saved juice.json")
  else
    self:say("save failed: " .. tostring(err))
  end
end

function UI:revert()
  Juice.load(Juice.path)
  self.savedText = Juice.serialize()
  self:say("reverted to juice.json on disk")
end

function UI:launch()
  local exe = love.filesystem.getExecutablePath():gsub("lovec%.exe$", "love.exe")
  local src = util.projectDir()
  if love.system.getOS() == "Windows" then
    os.execute(('start "" "%s" "%s"'):format(exe, src))
  else
    os.execute(('"%s" "%s" &'):format(exe, src))
  end
  self:say("launched the game")
end

function UI:drawPanel()
  local _, wh = love.graphics.getDimensions()
  love.graphics.setColor(COLORS.panel)
  love.graphics.rectangle("fill", 0, 0, PANEL_W, wh)

  local x, y = GAP, GAP
  self:label("juice.json" .. (self:dirty() and "  *" or ""), x + 2, y + 8, 200, { 1, 1, 1 }, self.fontBold)
  if self:button("SAVE", x + 210, y, 90, 36, { accent = self:dirty() }) then self:save() end
  if self:button("REVERT", x + 308, y, 90, 36) then self:revert() end
  if self:button("LAUNCH GAME", x + 406, y, 190, 36, { accent = true }) then
    if self:dirty() then self:save() end
    self:launch()
  end
  y = y + 46

  local byId = {}
  for _, g in ipairs(Juice.schema.groups) do byId[g.id] = g end
  local headW = self.fontBold:getWidth("LOOK") + 14
  for _, sec in ipairs(SECTIONS) do
    self:label(sec.title, x, y + 3, headW, COLORS.accent, self.fontBold)
    local tx = x + headW
    for _, id in ipairs(sec.ids) do
      local g = byId[id]
      local w = self.fontSmall:getWidth(g.title) + 18
      if tx + w > PANEL_W - GAP then tx = x + headW; y = y + 26 end
      if self:button(g.title, tx, y, w, 22, { selected = self.group == id and self.search == "", font = self.fontSmall }) then
        self.group, self.scroll, self.search = id, 0, ""
      end
      tx = tx + w + 4
    end
    y = y + 26
  end
  y = y + 4
  self:label("filter: " .. (self.search ~= "" and self.search or "(type to search keys, Backspace clears)"), x, y, PANEL_W - 2 * GAP, COLORS.dim, self.fontSmall)
  y = y + 22

  local listTop = y
  local listH = wh - listTop - 120
  local rows = self:rows()
  self.scroll = util.clamp(self.scroll, 0, math.max(0, #rows * ROW_H - listH))
  self.listRect = { x = 0, y = listTop, w = PANEL_W, h = listH }
  self.hoverEntry = nil
  love.graphics.setScissor(0, listTop, PANEL_W, listH)
  for i, row in ipairs(rows) do
    local ry = listTop + (i - 1) * ROW_H - self.scroll
    if ry + ROW_H >= listTop and ry <= listTop + listH then
      if row.header then
        love.graphics.setColor(COLORS.header)
        love.graphics.rectangle("fill", 0, ry, PANEL_W, ROW_H)
        self:label(row.header, x, ry + 6, PANEL_W, COLORS.accent, self.fontBold)
      else
        if i % 2 == 0 then
          love.graphics.setColor(COLORS.stripe)
          love.graphics.rectangle("fill", 0, ry, PANEL_W, ROW_H)
        end
        self:drawRow(row.e, x, ry, PANEL_W - 2 * GAP)
      end
    end
  end
  love.graphics.setScissor()

  -- what the hovered key does, or the group's description
  local dy = wh - 112
  love.graphics.setColor(0.13, 0.14, 0.18)
  love.graphics.rectangle("fill", 0, dy, PANEL_W, 112)
  local e = self.hoverEntry
  if e then
    self:label(e.key, x, dy + 6, PANEL_W - 2 * GAP, COLORS.accent, self.fontBold)
    local range = (e.min or e.max) and ("  [%s .. %s]"):format(tostring(e.min), tostring(e.max)) or ""
    self:label((e.desc or "") .. range .. (e.restart and "  (restart the game to apply)" or ""), x, dy + 28, PANEL_W - 2 * GAP, nil, self.fontSmall)
  elseif self.message then
    self:label(self.message, x, dy + 6, PANEL_W - 2 * GAP, COLORS.good, self.fontBold)
  else
    local g = byId[self.group]
    if g and self.search == "" then
      self:label(g.title, x, dy + 6, PANEL_W - 2 * GAP, COLORS.accent, self.fontBold)
      self:label(g.desc, x, dy + 28, PANEL_W - 2 * GAP, nil, self.fontSmall)
    end
  end
end

function UI:drawDropdown()
  local dd = self.dropdown
  local e = dd.e
  local itemH = 24
  local h = #e.values * itemH
  local _, wh = love.graphics.getDimensions()
  local y0 = dd.y
  if y0 + h > wh - 4 then y0 = math.max(4, wh - 4 - h) end
  love.graphics.setColor(0.14, 0.15, 0.2)
  love.graphics.rectangle("fill", dd.x, y0, dd.w, h, 5, 5)
  love.graphics.setColor(0.4, 0.42, 0.5)
  love.graphics.rectangle("line", dd.x, y0, dd.w, h, 5, 5)
  local cur = util.getPath(Juice.data, e.key)
  local picked
  for i, v in ipairs(e.values) do
    local iy = y0 + (i - 1) * itemH
    local hot = self:hit(dd.x, iy, dd.w, itemH)
    if hot or v == cur then
      love.graphics.setColor(hot and COLORS.selected or { 0.2, 0.22, 0.3 })
      love.graphics.rectangle("fill", dd.x + 2, iy + 1, dd.w - 4, itemH - 2, 4, 4)
    end
    self:label((v == cur and "> " or "   ") .. (FONT_NAMES[v] or v), dd.x + 8, iy + 4, dd.w - 16, nil, self.fontSmall)
    if hot and self.clicked then picked = v end
  end
  if picked then
    Juice.set(e.key, picked)
    self.dropdown = nil
  elseif self.clicked and not self:hit(dd.x, y0, dd.w, h) then
    self.dropdown = nil
  end
end

------------------------------------------------------------------------
-- preview
------------------------------------------------------------------------

function UI:runScenario(sc)
  self.scenario = sc
  self.restartIn = nil
  self.game:scenario(sc.id)
  self.watch = { state = self.game.state, round = self.game.round }
end

-- replay the scenario once the game has moved past it
function UI:checkScenario(dt)
  local g, sc = self.game, self.scenario
  if not sc or sc.id == "title" then return end
  if self.restartIn then
    self.restartIn = self.restartIn - dt
    if self.restartIn <= 0 then self:runScenario(sc) end
    return
  end
  if g.state ~= self.watch.state or g.round ~= self.watch.round then
    self.restartIn = 0.25
  end
end

function UI:drawPreviewControls()
  local ww, wh = love.graphics.getDimensions()
  love.graphics.setColor(COLORS.panel)
  love.graphics.rectangle("fill", PANEL_W, wh - BOTTOM_H, ww - PANEL_W, BOTTOM_H)
  local x0 = PANEL_W + GAP + 4
  local x, y = x0, wh - BOTTOM_H + 10
  for _, sc in ipairs(Game.SCENARIOS) do
    local w = self.fontSmall:getWidth(sc.name) + 20
    if x + w > ww - GAP then x = x0; y = y + 28 end
    if self:button(sc.name, x, y, w, 24, { selected = self.scenario == sc, font = self.fontSmall }) then self:runScenario(sc) end
    x = x + w + 6
  end
  y = wh - 40
  self:label("HEAR", x0, y + 6, 50, COLORS.dim, self.fontSmall)
  x = x0 + 46
  for pad = 1, 4 do
    if self:button(("%s clean"):format(({ "Q", "W", "A", "S" })[pad]), x, y, 78, 28, { font = self.fontSmall }) then self.game:audition(pad, false) end
    x = x + 82
  end
  x = x + 10
  for pad = 1, 4 do
    if self:button(("%s wrong"):format(({ "Q", "W", "A", "S" })[pad]), x, y, 82, 28, { font = self.fontSmall }) then self.game:audition(pad, true) end
    x = x + 86
  end
  local g = self.game
  local phase = ""
  if g.state == "play" and g.round then phase = ":" .. tostring(g.round:phaseAt(g:heard() / g.spb)) end
  self:label(("state: %s%s   level: %s"):format(g.state, phase, g.level.name), x + 10, y + 6, ww - x - 20, COLORS.dim, self.fontSmall)
end

------------------------------------------------------------------------
-- lifecycle
------------------------------------------------------------------------

function UI.load()
  local self = setmetatable({}, UI)
  love.window.setMode(1680, 940, { resizable = true, minwidth = 1200, minheight = 700, vsync = 0, msaa = 4 })
  love.window.setTitle("BeatEmUp - juice editor (juice.json)")
  self.font = love.graphics.newFont(15)
  self.fontBold = love.graphics.newFont(17)
  self.fontSmall = love.graphics.newFont(13)
  self.group, self.scroll, self.search = "lights", 0, ""
  self.mx, self.my, self.mdown = 0, 0, false
  self.savedText = Juice.serialize()
  self.game = Game.new()
  self:runScenario(Game.SCENARIOS[3])
  return self
end

function UI:update(dt)
  if self.messageT then
    self.messageT = self.messageT - dt
    if self.messageT <= 0 then self.message, self.messageT = nil, nil end
  end
  self:checkScenario(dt)
  self.game:update(dt)
end

function UI:previewRect()
  local ww, wh = love.graphics.getDimensions()
  return PANEL_W + GAP, GAP, ww - PANEL_W - 2 * GAP, wh - BOTTOM_H - 2 * GAP
end

function UI:draw()
  love.graphics.clear(0.03, 0.03, 0.04)
  local px, py, pw, ph = self:previewRect()
  self.game:draw(px, py, pw, ph)
  local s = self.game.screen
  love.graphics.setColor(0.25, 0.27, 0.33)
  love.graphics.rectangle("line", s.ox - 1, s.oy - 1, s.W * s.scale + 2, s.H * s.scale + 2)
  if self.dropdown then
    -- an open dropdown owns the click
    local saved = self.clicked
    self.clicked = false
    self:drawPanel()
    self:drawPreviewControls()
    self.clicked = saved
    self:drawDropdown()
  else
    self:drawPanel()
    self:drawPreviewControls()
  end
  self.clicked, self.justPressed = false, false
end

function UI:mousepressed(x, y, b)
  self.mx, self.my = x, y
  if b ~= 1 then return end
  self.mdown, self.justPressed, self.clicked = true, true, true
  -- clicks on the pads in the preview play them, exactly as in the game
  if not self.dropdown and x > PANEL_W and self.game.screen:contains(x, y) then self.game:mousepressed(x, y) end
end

function UI:mousereleased(x, y, b)
  self.mx, self.my = x, y
  if b == 1 then
    self.mdown, self.active = false, nil
    self.game:mousereleased(x, y)
  end
end

function UI:mousemoved(x, y) self.mx, self.my = x, y end

function UI:wheelmoved(_, wy)
  self.dropdown = nil
  local e = self.hoverEntry
  if e and (e.type == "number" or e.type == "int") then
    local v = util.getPath(Juice.data, e.key)
    local step = e.step or 1
    if e.log then
      Juice.set(e.key, snap(e, v * (1.04 ^ wy)))
    else
      Juice.set(e.key, snap(e, v + step * (wy > 0 and 1 or -1)))
    end
    return
  end
  local lr = self.listRect
  if lr and self:hit(lr.x, lr.y, lr.w, lr.h) then self.scroll = self.scroll - wy * ROW_H * 2 end
end

function UI:keypressed(key)
  if key == "escape" then
    if self.search ~= "" then self.search = "" else love.event.quit() end
  elseif key == "backspace" then
    self.search = self.search:sub(1, -2)
  elseif key == "s" and love.keyboard.isDown("lctrl", "rctrl") then
    self:save()
  end
end

function UI:textinput(t)
  if love.keyboard.isDown("lctrl", "rctrl") then return end
  if t:match("^[%w_.]$") then
    self.search = self.search .. t
    self.scroll = 0
  end
end

return UI
