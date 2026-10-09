-- src/game/lights.lua
-- How a button lights its pad, shared by the game and the level editor's preview so the two
-- always match. A button is a tap: fade in over lights.attack_s, stay on for lights.hold_s,
-- fade out over lights.decay_s, the same for every button however wide its box (the box only
-- says which notes the tap plays). Buttons of soft notes are dimmer by
-- lights.velocity_brightness.

local Lights = {}

function Lights.envelope(t, attack, hold, decay)
  if t < 0 then return 0 end
  if t < attack then return t / attack end
  t = t - attack
  if t < hold then return 1 end
  t = t - hold
  if t < decay then
    local k = 1 - t / decay
    return k * k
  end
  return 0
end

-- seconds a tap keeps the light fully on
function Lights.hold(J)
  return J.lights.hold_s
end

-- the brightness and color of button b's light, `dt` seconds after it came on
function Lights.button(J, b, dt, spb)
  local Li = J.lights
  local env = Lights.envelope(dt, Li.attack_s, Lights.hold(J), Li.decay_s)
  if env <= 0 then return 0, nil end
  local v = 1 - Li.velocity_brightness * (1 - (b.vel or 100) / 127)
  return env * Li.demo_level * v, b.color
end

return Lights
