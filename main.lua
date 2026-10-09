-- main.lua
-- Entry point.
--
--   love .                          the game: the songs in songs/ (else every level in levels/)
--   love . --song=songs/x.json      the game, that song only (--from=2: start at its level 2,
--                                   level 1 already built)
--   love . --level=levels/x.json    the game, that level only
--   love . --juice                  the juice editor: every juice.json key + the live game
--   love . --levels                 the level editor (a .json/.mid path, or a song, opens it)
--   lovec . --test                  unit tests, headless
--   lovec . --write-juice           (re)write juice.json with every key at its default
--   lovec . --export                write exports/<song>_with_backing.wav and _without_backing.wav
--
-- For checking things without playing: --autoplay (the game starts itself and the bot plays
-- every turn),
-- --scenario=<id> (the game drops into one of Game.SCENARIOS), --trace (prints the game's
-- state changes), --shots=1,4.5 (screenshots at those seconds, into the save folder),
-- --quit-after=<seconds>, --run=<file.lua> (a script returning function(app, seconds), called
-- every frame to drive the app; it returns true when it is done).

local util = require("src.util")
local Juice = require("src.config.juice")

local app
local dev   -- --shots / --quit-after

-- the game, full window, with juice hot reload and F11 fullscreen
local GameApp = {}
GameApp.__index = GameApp

function GameApp.load(args)
  local J = Juice.data
  love.window.setMode(J.display.window_width, J.display.window_height,
    { resizable = true, vsync = 0, msaa = 4, minwidth = 320, minheight = 240, fullscreen = J.display.fullscreen, fullscreentype = "desktop" })
  love.window.setTitle("BeatEmUp")
  local function arg(name)
    local v = util.argValue(args, name, nil)
    return v ~= true and v or nil
  end
  local game = require("src.game.game").new({ level = arg("--level"), song = arg("--song"), from = tonumber(arg("--from")),
    autoplay = util.hasArg(args, "--autoplay") })
  local self = setmetatable({ game = game, trace = util.hasArg(args, "--trace") }, GameApp)
  if arg("--scenario") then game:scenario(arg("--scenario"))
  elseif util.hasArg(args, "--autoplay") then game:newGame() end
  return self
end

function GameApp:update(dt)
  Juice.update(dt)
  self.game:update(dt)
  if self.trace then
    local g = self.game
    local s = ("%s | level %s %s | round %s | %s %s"):format(g.state, tostring(g.levelIndex), g.level and g.level.name or "",
      g.round and g.round.number or "-", g.status and g.status.text or "", g.status and g.status.sub or "")
    if s ~= self.lastTrace then
      print(("%8.2fs beat %7.2f  %s"):format(love.timer.getTime(), g.timeline and g:heard() / g.spb or 0, s))
      self.lastTrace = s
    end
  end
end

function GameApp:draw() self.game:draw() end

function GameApp:keypressed(key, isrepeat)
  if isrepeat then return end
  if key == "f11" then
    love.window.setFullscreen(not love.window.getFullscreen(), "desktop")
    return
  end
  local handled = self.game:keypressed(key)
  if key == "escape" and not handled and self.game.state == "title" then love.event.quit() end
end

function GameApp:keyreleased(key) self.game:keyreleased(key) end
function GameApp:mousepressed(x, y, b) if b == 1 then self.game:mousepressed(x, y) end end
function GameApp:mousereleased(x, y, b) if b == 1 then self.game:mousereleased(x, y) end end

function love.load(args)
  args = args or {}
  if util.hasArg(args, "--test") then
    require("tests.run").main(args)
    return
  end
  Juice.load("juice.json")
  if util.hasArg(args, "--write-juice") then
    local defaults = Juice.defaults()
    for k in pairs(Juice.data) do Juice.data[k] = nil end
    for k, v in pairs(defaults) do Juice.data[k] = v end
    local ok, err = Juice.write()
    print(ok and "wrote juice.json" or ("failed: " .. tostring(err)))
    love.event.quit(ok and 0 or 1)
    return
  end
  if util.hasArg(args, "--export") then
    local ok = require("src.export").main(Juice.data)
    love.event.quit(ok and 0 or 1)
    return
  end
  if util.hasArg(args, "--juice") then
    app = require("src.tools.juice_ui").load(args)
  elseif util.hasArg(args, "--levels") then
    love.keyboard.setKeyRepeat(true)
    app = require("src.tools.level_editor").load(args)
  else
    app = GameApp.load(args)
  end
  local shots = util.argValue(args, "--shots", nil)
  dev = { t = 0, shots = {}, quitAfter = tonumber(util.argValue(args, "--quit-after", nil)) }
  if type(shots) == "string" then
    for s in shots:gmatch("[^,]+") do dev.shots[#dev.shots + 1] = tonumber(s) end
  end
  local run = util.argValue(args, "--run", nil)
  if type(run) == "string" then dev.step = assert(loadfile(run))() end
end

local function call(name, ...)
  if app and app[name] then return app[name](app, ...) end
end

-- --shots / --quit-after
local function devTick(dt)
  if not dev then return end
  dev.t = dev.t + dt
  if dev.shots[1] and dev.t >= dev.shots[1] then
    local name = ("shot_%05.1f.png"):format(table.remove(dev.shots, 1))
    love.graphics.captureScreenshot(name)
    print("screenshot " .. love.filesystem.getSaveDirectory() .. "/" .. name)
  end
  if dev.step and dev.step(app, dev.t) then dev.step = nil; love.event.quit() end
  if dev.quitAfter and dev.t >= dev.quitAfter then love.event.quit() end
end

function love.update(dt) call("update", dt); devTick(dt) end
function love.draw() call("draw") end
function love.keypressed(key, _, isrepeat) call("keypressed", key, isrepeat) end
function love.keyreleased(key) call("keyreleased", key) end
function love.textinput(t) call("textinput", t) end
function love.mousepressed(x, y, button, _, presses) call("mousepressed", x, y, button, presses) end
function love.mousereleased(x, y, button) call("mousereleased", x, y, button) end
function love.mousemoved(x, y) call("mousemoved", x, y) end
function love.wheelmoved(x, y) call("wheelmoved", x, y) end
function love.resize(w, h) call("resize", w, h) end
function love.filedropped(file) call("filedropped", file) end

-- LÖVE's stock loop waits for vsync after every frame, so input is only read and the audio
-- queue only topped up once a frame. This loop does both about every millisecond (hits are
-- timed to ~1 ms, a small audio queue is safe) and draws at the display's refresh rate.
-- conf.lua turns vsync off for it.
function love.run()
  if love.load then love.load(love.arg.parseGameArguments(arg), arg) end
  if love.timer then love.timer.step() end

  local drawEvery = 1 / 60
  if love.window and love.window.isOpen() then
    local _, _, flags = love.window.getMode()
    if flags.refreshrate and flags.refreshrate > 0 then drawEvery = 1 / flags.refreshrate end
  end
  local nextDraw = 0

  return function()
    if love.event then
      love.event.pump()
      for name, a, b, c, d, e, f in love.event.poll() do
        if name == "quit" then
          if not love.quit or not love.quit() then return a or 0 end
        end
        love.handlers[name](a, b, c, d, e, f)
      end
    end

    local dt = love.timer and love.timer.step() or 0
    if love.update then love.update(dt) end

    if love.graphics and love.graphics.isActive() then
      local now = love.timer.getTime()
      if now >= nextDraw then
        nextDraw = math.max(nextDraw + drawEvery, now)
        love.graphics.origin()
        love.graphics.clear(love.graphics.getBackgroundColor())
        if love.draw then love.draw() end
        love.graphics.present()
      end
    end

    if love.timer then love.timer.sleep(0.001) end
  end
end
