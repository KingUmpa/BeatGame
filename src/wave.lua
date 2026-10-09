-- src/wave.lua
-- Waveform drawing for mixer samples ({ data = float* stereo, frames }). A min/max table
-- per 128-frame block is built once, so a strip of any zoom costs one lookup per pixel.
--
--   local p = Wave.peaks(sample)
--   local lo, hi = Wave.range(p, a, b)                      -- over frames [a, b)
--   Wave.draw(p, x, y, w, h, frameAtX)                      -- frameAtX(px) -> frame

local ffi = require("ffi")

local Wave = {}

local BLOCK = 128

function Wave.peaks(sample)
  local d, frames = sample.data, sample.frames
  local n = math.ceil(frames / BLOCK)
  local lo, hi = ffi.new("float[?]", n), ffi.new("float[?]", n)
  local peak = 0
  for blk = 0, n - 1 do
    local mn, mx = 1e9, -1e9
    for f = blk * BLOCK, math.min(frames, (blk + 1) * BLOCK) - 1 do
      local v = (d[f * 2] + d[f * 2 + 1]) * 0.5
      if v < mn then mn = v end
      if v > mx then mx = v end
      local a = math.max(math.abs(d[f * 2]), math.abs(d[f * 2 + 1]))
      if a > peak then peak = a end
    end
    lo[blk], hi[blk] = mn, mx
  end
  return { lo = lo, hi = hi, n = n, frames = frames, data = d, peak = peak }
end

function Wave.range(p, a, b)
  a, b = math.max(0, math.floor(a)), math.min(p.frames, math.floor(b))
  if b <= a then return nil end
  local mn, mx = 1e9, -1e9
  if b - a < BLOCK * 2 then
    local d = p.data
    for f = a, b - 1 do
      local v = (d[f * 2] + d[f * 2 + 1]) * 0.5
      if v < mn then mn = v end
      if v > mx then mx = v end
    end
  else
    for blk = math.floor(a / BLOCK), math.floor((b - 1) / BLOCK) do
      if p.lo[blk] < mn then mn = p.lo[blk] end
      if p.hi[blk] > mx then mx = p.hi[blk] end
    end
  end
  return mn, mx
end

-- one vertical bar per pixel column; frameAtX maps a column's left edge to a frame
function Wave.draw(p, x, y, w, h, frameAtX)
  local mid = y + h / 2
  for px = 0, math.floor(w) - 1 do
    local mn, mx = Wave.range(p, frameAtX(px), frameAtX(px + 1))
    if mn then
      local top, bot = mid - mx * h / 2, mid - mn * h / 2
      love.graphics.rectangle("fill", x + px, top, 1, math.max(1, bot - top))
    end
  end
end

-- What a .wav file really contains (LÖVE decodes everything to 16-bit, so this is the only
-- place the source format shows): { format = "PCM" | "float", bits, channels, rate,
-- frames, seconds, chunks = { "JUNK 28", "fmt 16", "data 808712" } }
function Wave.fileInfo(bytes)
  if not bytes or bytes:sub(1, 4) ~= "RIFF" or bytes:sub(9, 12) ~= "WAVE" then return nil end
  local function u32(i) local a, b, c, d = bytes:byte(i, i + 3); return a + b * 256 + c * 65536 + d * 16777216 end
  local function u16(i) local a, b = bytes:byte(i, i + 1); return a + b * 256 end
  local info, p = { chunks = {} }, 13
  while p + 7 <= #bytes do
    local id, size = bytes:sub(p, p + 3), u32(p + 4)
    info.chunks[#info.chunks + 1] = id:gsub(" ", "") .. " " .. size
    if id == "fmt " then
      local tag = u16(p + 8)
      if tag == 0xFFFE and size >= 40 then tag = u16(p + 32) end   -- WAVE_FORMAT_EXTENSIBLE
      info.format = tag == 3 and "float" or "PCM"
      info.channels, info.rate, info.bits = u16(p + 10), u32(p + 12), u16(p + 22)
    elseif id == "data" and info.bits then
      info.frames = math.floor(size / (info.channels * info.bits / 8))
      info.seconds = info.frames / info.rate
    end
    p = p + 8 + size + size % 2
  end
  return info
end

-- last frame louder than `db` (default -60 dBFS): how long a one-shot actually sounds
function Wave.audibleFrames(sample, db)
  local th = 10 ^ ((db or -60) / 20)
  local d = sample.data
  for f = sample.frames - 1, 0, -1 do
    if math.abs(d[f * 2]) > th or math.abs(d[f * 2 + 1]) > th then return f + 1 end
  end
  return 0
end

return Wave
