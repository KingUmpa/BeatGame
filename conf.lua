-- conf.lua
-- LÖVE configuration. Headless flags (--test, --write-juice) drop the window, graphics and
-- realtime audio so they run from a console with no display. The game sizes its window
-- from juice.json once it loads; the editors size their own.

-- Point OpenAL Soft at alsoft.ini (a ~20 ms device buffer instead of ~60 ms). It reads
-- ALSOFT_CONF when the audio module starts, which is after this file runs. On Windows
-- OpenAL32.dll and LuaJIT share msvcr120's environment, so setting it here reaches it.
local function useLowLatencyAudio()
  if os.getenv("ALSOFT_CONF") then return end
  local ok, ffi = pcall(require, "ffi")
  if not ok or ffi.os ~= "Windows" then return end
  -- beside main.lua when run from the project folder; beside the .exe in a packaged build
  local dir = love.filesystem.isFused() and love.filesystem.getSourceBaseDirectory() or love.filesystem.getSource()
  local ini = dir .. "/alsoft.ini"
  local f = io.open(ini, "r")
  if not f then return end
  f:close()
  pcall(function()
    ffi.cdef("int _putenv_s(const char *name, const char *value);")
    ffi.load("msvcr120")._putenv_s("ALSOFT_CONF", ini)
  end)
end
useLowLatencyAudio()

local function headlessRequested()
  for _, a in ipairs(arg or {}) do
    if a == "--test" or a == "--write-juice" or a == "--export" then return true end
  end
  return false
end

function love.conf(t)
  t.identity = "beatemup"
  t.version = "11.5"
  t.console = false

  if headlessRequested() then
    t.window = nil
    t.modules.window = false
    t.modules.graphics = false
    t.modules.audio = false
    t.modules.font = false
    t.modules.image = false
    t.modules.video = false
    t.modules.joystick = false
    t.modules.touch = false
    t.modules.keyboard = false
    t.modules.mouse = false
    return
  end

  t.window.title = "BeatEmUp"
  t.window.width = 1280
  t.window.height = 800
  t.window.minwidth = 320
  t.window.minheight = 240
  t.window.resizable = true
  t.window.vsync = 0   -- main.lua's loop paces drawing itself and polls input every ~1 ms
  t.window.msaa = 4
  t.modules.joystick = false
  t.modules.touch = false
  t.modules.video = false
end
