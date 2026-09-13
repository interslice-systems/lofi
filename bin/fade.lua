-- fade.lua — gentle volume ramps for the lofi wrapper. Loaded by bin/lofi via
-- --script=, so it only ever runs inside lofi's own mpv.
--
-- What it smooths:
--   pause         any pause request (MPRIS, media keys) is undone, the volume
--                 ramped to 0, then the real pause applied and the volume put back
--   resume        starts at 0 and ramps up to the volume it had
--   file-loaded   every new stream (startup, next/previous, a switch) fades in
--   fade-quit     script message: ramp down, then quit
--   fade-play     script message <playlist> <index>: ramp down, load the
--                 playlist, start at <index>; the fade-in comes from file-loaded
--
-- The user's volume is remembered in `target`, read whenever a fade starts from
-- a state where the current volume is genuinely theirs (not mid-ramp).

local mp = require("mp")

local STEP_S  = 0.04   -- 25 steps/s
local FADE_S  = 0.9    -- pause, resume, stop, and every fade-in
local SWITCH_S = 0.4   -- fade-out before a switch: silence follows anyway,
                       -- and this is on the path to the next stream

local target  = nil    -- the user's volume, restored after every fade
local busy    = false  -- a ramp is running; observers stand down
local ignore  = 0      -- pause notifications we caused ourselves, to be skipped
local primed  = false  -- observe_property fires once at startup; skip that one

local function vol() return mp.get_property_number("volume", 100) end

-- Set pause only if it actually changes, so the observer skip count stays honest.
local function set_pause(want)
  if mp.get_property_bool("pause", false) ~= want then
    ignore = ignore + 1
    mp.set_property_bool("pause", want)
  end
end

local function ramp(from, to, done, secs)
  busy = true
  local steps = math.max(1, math.floor((secs or FADE_S) / STEP_S))
  local i = 0
  local timer
  timer = mp.add_periodic_timer(STEP_S, function()
    i = i + 1
    mp.set_property_number("volume", from + (to - from) * (i / steps))
    if i >= steps then
      timer:kill()
      busy = false
      if done then done() end
    end
  end)
end

mp.observe_property("pause", "bool", function(_, paused)
  if paused == nil then return end
  if not primed then primed = true; return end
  if ignore > 0 then ignore = ignore - 1; return end
  if busy then return end
  if paused then
    -- Undo it, fade, then pause for real with the volume put back.
    target = vol()
    set_pause(false)
    ramp(target, 0, function()
      set_pause(true)
      mp.set_property_number("volume", target)
    end)
  else
    target = target or vol()
    mp.set_property_number("volume", 0)
    ramp(0, target)
  end
end)

mp.register_event("file-loaded", function()
  if busy then return end
  local v = vol()
  if v > 0 then target = v end      -- playing normally: the volume is theirs
  target = target or 100
  mp.set_property_number("volume", 0)
  ramp(0, target)
end)

mp.register_script_message("fade-quit", function()
  if busy or mp.get_property_bool("pause", false) then
    mp.command("quit")
    return
  end
  ramp(vol(), 0, function() mp.command("quit") end)
end)

mp.register_script_message("fade-play", function(playlist, index)
  local function go()
    set_pause(false)
    mp.set_property_number("volume", 0)
    mp.commandv("loadlist", playlist, "replace")
    mp.commandv("playlist-play-index", tonumber(index) or 0)
  end
  if busy or mp.get_property_bool("pause", false) then
    target = target or vol()
    go()
    return
  end
  target = vol()
  ramp(target, 0, go, SWITCH_S)
end)
