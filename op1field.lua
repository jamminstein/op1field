-- FIELDBOT v3.1 ENHANCED
-- algorithmic command center for OP-1 Field
-- deep drum + synth pages: sections, variation, accidents
-- NOW WITH: status strip, parameter popup, enhanced brightness hierarchy
-- AND: MollyThePoly engine for standalone audio output
--
-- PHILOSOPHY:
--   Everything lives in one scale. Sections (verse/chorus/
--   bridge/drop) switch automatically or on demand. Each
--   section has its own energy level, density, velocity
--   curve, and fill probability. The synth generates
--   context-aware melodic phrases that respect the current
--   harmonic moment. Drums breathe with fills, ghost notes,
--   polyrhythm pockets, and euclidean sub-patterns.
--   Happy accidents come from: probability gates, velocity
--   humanisation, micro-timing nudges, occasional wrong
--   notes that are scale-adjacent, and section transitions
--   that sometimes overshoot or lag.
--
-- CONTROLS:
--   E1        → page (DRUM / SYNTH / LFO / PERFORM)
--   E2        → param A
--   E3        → param B
--   K2        → generate / action
--   K3        → mutate / section forward
--   K1 hold   → alt
--   K1 + K2   → play / stop
--   K1 + K3   → reset / panic
--
-- ENHANCEMENTS (v3.2):
--   Status Strip: FIELDBOT title, current page, page dots, beat pulse
--   Parameter Popup: transient overlay on encoder changes (<0.8s)
--   Brightness Hierarchy: visual depth via level differentiation
--   Beat Phase: tracked for smooth pulse animations
--   MollyThePoly: polyphonic engine for drums + synth playback

engine.name = "MollyThePoly"

local lattice   = require "lattice"
local sequins   = require "sequins"
local musicutil = require "musicutil"

local function midi_to_hz(note)
  return 440 * 2^((note - 69) / 12)
end

-- ============================================================
-- CONFIG
-- ============================================================
local MIDI_DEV = 1
local OP1_CH   = 1
local CC = {1,2,3,4}
local CC_DEST = {"ENGINE","ENV","FX","VOL"}

local DN = {
  kick=36, snare=38, hat_c=40, hat_o=41,
  clap=43, tom_l=45, tom_h=47, ride=48,
  perc1=50, perc2=52,
}

-- Engine note tracking
local engine_ids = {}
local next_engine_id = 1

-- ── OP-XY MIDI output ──
local opxy_out = nil
local function opxy_note_on(note, vel)
  if opxy_out then opxy_out:note_on(note, vel, params:get("opxy_channel")) end
end
local function opxy_note_off(note)
  if opxy_out then opxy_out:note_off(note, 0, params:get("opxy_channel")) end
end

-- ============================================================
-- SCALES & HARMONY
-- ============================================================
local SCALES = {
  minor      = {0,2,3,5,7,8,10},
  major      = {0,2,4,5,7,9,11},
  dorian     = {0,2,3,5,7,9,10},
  pentatonic = {0,3,5,7,10},
  phrygian   = {0,1,3,5,7,8,10},
  lydian     = {0,2,4,6,7,9,11},
  mixolydian = {0,2,4,5,7,9,10},
  blues      = {0,3,5,6,7,10},
}
local scale_names = {"minor","major","dorian","pentatonic","phrygian","lydian","mixolydian","blues"}

-- Diatonic chord roots for each scale (scale degrees as indices)
-- Used to build progressions
local PROGRESSIONS = {
  -- name = list of {degree, chord_quality}
  -- quality: "m"=minor "M"=major "7"=dom7 "m7"=min7 "sus"=sus4
  verse   = {{1,"m"},{6,"m"},{3,"M"},{7,"m"}},
  chorus  = {{1,"m"},{4,"m"},{5,"M"},{1,"m"}},
  bridge  = {{6,"m"},{3,"M"},{4,"m"},{5,"7"}},
  drop    = {{1,"m"},{1,"m"},{1,"m"},{5,"M"}},
  buildup = {{4,"m"},{5,"M"},{6,"m"},{5,"7"}},
  interlude = {{1,"m"},{7,"m"},{6,"m"},{7,"m"}},
}
local prog_names = {"verse","chorus","bridge","drop","buildup","interlude"}

-- Chord intervals by quality
local CHORD_Q = {
  m={0,3,7}, M={0,4,7}, ["7"]={0,4,7,10},
  m7={0,3,7,10}, sus={0,5,7}, sus2={0,2,7},
}

-- ============================================================
-- SECTIONS
-- ============================================================
-- Each section defines the current musical "moment"
-- and shapes how drums + synth behave
local SECTIONS = {
  {
    name="verse",
    energy=0.4,
    drum_density=0.45,
    synth_density=0.5,
    velocity_curve="soft",
    fill_prob=0.1,
    ghost_prob=0.35,
    prog="verse",
    auto_advance=true,
    bars=8,
  },
  {
    name="buildup",
    energy=0.65,
    drum_density=0.6,
    synth_density=0.65,
    velocity_curve="medium",
    fill_prob=0.25,
    ghost_prob=0.2,
    prog="buildup",
    auto_advance=true,
    bars=4,
  },
  {
    name="chorus",
    energy=0.85,
    drum_density=0.75,
    synth_density=0.7,
    velocity_curve="hard",
    fill_prob=0.35,
    ghost_prob=0.1,
    prog="chorus",
    auto_advance=true,
    bars=8,
  },
  {
    name="drop",
    energy=0.9,
    drum_density=0.8,
    synth_density=0.45,
    velocity_curve="accent",
    fill_prob=0.5,
    ghost_prob=0.05,
    prog="drop",
    auto_advance=true,
    bars=4,
  },
  {
    name="interlude",
    energy=0.2,
    drum_density=0.25,
    synth_density=0.6,
    velocity_curve="soft",
    fill_prob=0.05,
    ghost_prob=0.45,
    prog="interlude",
    auto_advance=true,
    bars=4,
  },
  {
    name="bridge",
    energy=0.55,
    drum_density=0.5,
    synth_density=0.75,
    velocity_curve="medium",
    fill_prob=0.2,
    ghost_prob=0.25,
    prog="bridge",
    auto_advance=true,
    bars=4,
  },
}
local section_seq = sequins({1,2,3,4,5,6,3,4,1,2,3,4})

-- ============================================================
-- PATTERN RECORD MODE
-- ============================================================
local record_mode_active = false
local recorded_drum_pattern = {}
local recorded_synth_pattern = {}

local function start_pattern_record()
  record_mode_active = true
  recorded_drum_pattern = {}
  recorded_synth_pattern = {}
  toast("RECORD: capturing pattern")
end

local function stop_pattern_record()
  record_mode_active = false
  toast("PATTERN: recorded & frozen")
end

local function capture_drum_event(step, notes_table)
  if not record_mode_active then return end
  recorded_drum_pattern[step] = notes_table
end

local function capture_synth_event(step, note)
  if not record_mode_active then return end
  recorded_synth_pattern[step] = note
end

-- ============================================================
-- MIDI INPUT SECTION CONTROL
-- ============================================================
local function init_midi_handler()
  if m == nil then return end
  m.event = function(data)
    local msg = midi.to_msg(data)
    if msg.type == "note_on" then
      local note = msg.note
      if note >= 24 and note <= 35 then
        local sec_idx = math.min(6, (note - 24) % 12 + 1)
        local sec = SECTIONS[sec_idx]
        if sec then
          section_state.current = sec_idx
          apply_section(sec_idx)
          toast("section: " .. sec.name)
        end
      elseif note >= 36 then
        local new_root = ((note - 12) % 12) + 36
        synth.root = util.clamp(new_root, 36, 72)
        rebuild_scale()
        toast("root: " .. musicutil.note_num_to_name(synth.root))
      end
    end
  end
end

-- ============================================================
-- VELOCITY CURVES
-- ============================================================
local function vel_curve(curve, base, rand_range)
  local r = rand_range or 15
  if curve == "soft" then
    return util.clamp(math.floor(base * 0.65 + math.random(-r,r)), 40, 90)
  elseif curve == "medium" then
    return util.clamp(math.floor(base * 0.85 + math.random(-r,r)), 60, 110)
  elseif curve == "hard" then
    return util.clamp(math.floor(base * 1.0  + math.random(-r,r)), 80, 127)
  elseif curve == "accent" then
    if math.random() < 0.3 then
      return math.random(30, 60)
    else
      return math.random(100, 127)
    end
  end
  return util.clamp(base + math.random(-r, r), 40, 127)
end

-- ============================================================
-- MICRO-TIMING
-- ============================================================
local function micro_timing(energy)
  local max_ms = (1 - energy) * 0.04
  return (math.random() - 0.5) * max_ms
end

-- ============================================================
-- EUCLIDEAN HELPERS
-- ============================================================
local function gen_euclid(k, n)
  if k <= 0 then return {} end
  local pat, bucket = {}, 0
  for i = 1, n do
    bucket = bucket + k
    if bucket >= n then bucket = bucket - n; table.insert(pat, true)
    else table.insert(pat, false) end
  end
  return pat
end

local function euclid_hit(pat, step)
  if #pat == 0 then return false end
  return pat[((step-1) % #pat) + 1] == true
end

-- ============================================================
-- DRUM ENGINE
-- ============================================================
local drum_voices = {
  "kick","snare","hat_c","hat_o","clap","tom_l","tom_h","perc1"
}
local drum_voice_notes = {
  kick=DN.kick, snare=DN.snare, hat_c=DN.hat_c, hat_o=DN.hat_o,
  clap=DN.clap, tom_l=DN.tom_l, tom_h=DN.tom_h, perc1=DN.perc1,
}

local drum = {
  steps = 16,
  pattern = {},
  vels    = {},
  ghost   = {},
  ghost_v = {},
  fill    = {},
  fill_active = false,
  fill_step = 13,
  euclid  = {
    hat_c  = gen_euclid(7, 16),
    perc1  = gen_euclid(3, 16),
    tom_l  = gen_euclid(2, 16),
  },
  en = {kick=true,snare=true,hat_c=true,hat_o=false,
        clap=true,tom_l=false,tom_h=false,perc1=false},
  swing_amt = 0,
  auto_mutate = false,
  mutate_interval = 4,
  mutate_count = 0,
  seq_density = nil,
  density = 0.5,
  velocity_curve = "medium",
  fill_prob = 0.15,
  ghost_prob = 0.3,
}

local function gen_drum_fill(section)
  local f = {}
  for s = 1, drum.steps do f[s] = {} end
  local e = section.energy
  for s = drum.fill_step, drum.steps do
    f[s].snare = math.random() < (0.4 + e * 0.4)
    f[s].tom_h = math.random() < (0.3 + e * 0.3)
    f[s].tom_l = math.random() < (0.2 + e * 0.4)
    f[s].kick  = (s == drum.steps) and math.random() < 0.5
    f[s].hat_c = math.random() < (0.5 + e * 0.3)
  end
  return f
end

local function gen_drums(section)
  section = section or SECTIONS[1]
  local d  = section.drum_density
  local vc = section.velocity_curve
  drum.density = d
  drum.velocity_curve = vc
  drum.fill_prob = section.fill_prob
  drum.ghost_prob = section.ghost_prob

  for s = 1, drum.steps do
    drum.pattern[s] = {}; drum.vels[s] = {}
    drum.ghost[s]   = {}; drum.ghost_v[s] = {}
    for v = 1, #drum_voices do
      local voice = drum_voices[v]
      local hit = (not drum.en[voice]) and false or (math.random() < d)
      drum.pattern[s][voice] = hit
      drum.vels[s][voice] = hit and vel_curve(vc, 95) or 0
      local ghost = math.random() < section.ghost_prob
      drum.ghost[s][voice] = ghost
      drum.ghost_v[s][voice] = ghost and math.random(30, 50) or 0
    end
  end

  anim.drum_flash = 1.0
end

-- ============================================================
-- SYNTH ENGINE
-- ============================================================
local synth = {
  steps = 16,
  pattern = {},
  notes = {},
  vels = {},
  lengths = {},
  root = 48,
  scale = "minor",
  register = 1,
  contour = "arch",
  contour_names = {"arch","fall","rise","zigzag","static","random"},
  seq_scale = nil,
  seq_density = nil,
  seq_contour = nil,
}

local function gen_scale(root, scale_name)
  if not SCALES[scale_name] then scale_name = "minor" end
  local scale_intervals = SCALES[scale_name]
  local scale = {}
  for oct = 0, 3 do
    for _, interval in ipairs(scale_intervals) do
      table.insert(scale, root + oct * 12 + interval)
    end
  end
  return scale
end

local SCALE_CACHE = {}
local function get_scale(root, scale_name)
  local key = root .. "_" .. scale_name
  if not SCALE_CACHE[key] then
    SCALE_CACHE[key] = gen_scale(root, scale_name)
  end
  return SCALE_CACHE[key]
end

local function contour_arch(step, max_step)
  local ratio = step / max_step
  return math.sin(ratio * math.pi)
end
local function contour_fall(step, max_step)
  return 1 - (step / max_step)
end
local function contour_rise(step, max_step)
  return step / max_step
end
local function contour_zigzag(step, max_step)
  local ratio = (step % 4) / 4
  return step % 8 < 4 and ratio or (1 - ratio)
end
local function contour_static(step, max_step)
  return 0.5
end
local function contour_random(step, max_step)
  math.randomseed(step * 997)
  return math.random()
end

local CONTOURS = {
  arch = contour_arch,
  fall = contour_fall,
  rise = contour_rise,
  zigzag = contour_zigzag,
  static = contour_static,
  random = contour_random,
}

local function gen_synth(section)
  section = section or SECTIONS[1]
  local scale_name = synth.scale or "minor"
  local sc = get_scale(synth.root, scale_name)
  local density = section.synth_density
  local contour_fn = CONTOURS[synth.contour] or contour_arch

  for s = 1, synth.steps do
    synth.pattern[s] = nil
    synth.notes[s] = nil
    synth.vels[s] = 0
    synth.lengths[s] = 0.25
    if math.random() < density then
      local c_val = contour_fn(s, synth.steps)
      local scale_idx = math.floor(c_val * (#sc - 1)) + 1
      local note = sc[scale_idx]
      synth.notes[s] = note
      synth.vels[s] = vel_curve(section.velocity_curve, 85)
      synth.lengths[s] = math.random(1, 4) * 0.125
      synth.pattern[s] = {note = note, vel = synth.vels[s], len = synth.lengths[s]}
    end
  end

  anim.note_flash = 1.0
end

-- ============================================================
-- ARPEGGIATOR
-- ============================================================
local arp = {
  on = false,
  pattern = "up",
  chord = "minor",
  speed = 1,
  root = 36,
  seq_pattern = nil,
  seq_chord = nil,
}

local ARP_PATTERNS = {
  up      = function(notes, step) return notes[((step - 1) % #notes) + 1] end,
  down    = function(notes, step) return notes[#notes - ((step - 1) % #notes)] end,
  bounce  = function(notes, step)
    local cycle = #notes * 2 - 2
    if cycle < 1 then return notes[1] end
    local pos = (step - 1) % cycle
    if pos < #notes then return notes[pos + 1]
    else return notes[cycle - pos + 1] end
  end,
  skip    = function(notes, step)
    local idx = ((step - 1) * 2) % #notes + 1
    return notes[idx]
  end,
  cascade = function(notes, step)
    -- plays 1,1-2,1-2-3,... building up the chord
    local group = ((step - 1) % #notes) + 1
    local inner = ((step - 1) % group) + 1
    return notes[inner]
  end,
  trill   = function(notes, step)
    -- alternates between root and scale tones
    if step % 2 == 1 then return notes[1]
    else return notes[math.min(2 + math.floor((step - 1) / 2) % (#notes - 1), #notes)] end
  end,
  random  = function(notes, step) return notes[math.random(1, #notes)] end,
}

local function build_arp_()
  -- Build a set of notes from the arp chord/root in the current scale
  local sc = get_scale(arp.root, synth.scale or "minor")
  if not sc or #sc == 0 then return end

  -- Select chord intervals based on arp.chord type
  local CHORD_INTERVALS = {
    minor  = {0, 3, 7},
    major  = {0, 4, 7},
    sus2   = {0, 2, 7},
    sus4   = {0, 5, 7},
    min7   = {0, 3, 7, 10},
    dom7   = {0, 4, 7, 10},
    maj7   = {0, 4, 7, 11},
    power  = {0, 7, 12},
    dim    = {0, 3, 6},
    aug    = {0, 4, 8},
  }

  local intervals = CHORD_INTERVALS[arp.chord] or CHORD_INTERVALS.minor
  local arp_notes = {}

  -- Build notes across 2 octaves for extended arps
  for oct = 0, 1 do
    for _, iv in ipairs(intervals) do
      local note = arp.root + iv + (oct * 12)
      -- Snap to nearest scale note for musicality
      local best, best_d = note, 999
      for _, sn in ipairs(sc) do
        local d = math.abs(sn - note)
        if d < best_d then best = sn; best_d = d end
      end
      if best >= 24 and best <= 96 then
        table.insert(arp_notes, best)
      end
    end
  end

  -- Remove duplicates
  local seen = {}
  local unique = {}
  for _, n in ipairs(arp_notes) do
    if not seen[n] then seen[n] = true; table.insert(unique, n) end
  end
  arp_notes = unique

  if #arp_notes == 0 then return end

  -- Set up the arp lattice pattern if not already running
  local pattern_fn = ARP_PATTERNS[arp.pattern] or ARP_PATTERNS.up
  local arp_step = 0

  -- If a lattice pattern already exists, we just store the notes;
  -- the lattice action will use the current arp state
  arp._notes = arp_notes
  arp._pattern_fn = pattern_fn
  arp._step = 0
end

-- ============================================================
-- SECTION STATE
-- ============================================================
local section_state = {
  current = 1,
  name = "verse",
  energy = 0.4,
  elapsed_bars = 0,
  auto_mode = true,
}

local function apply_section(idx)
  if idx < 1 or idx > #SECTIONS then idx = 1 end
  local sec = SECTIONS[idx]
  section_state.current = idx
  section_state.name = sec.name
  section_state.energy = sec.energy
  section_state.elapsed_bars = 0
  gen_drums(sec)
  gen_synth(sec)
  anim.section_flash = 1.0
end

local function next_section()
  local idx = section_seq()
  apply_section(idx)
  return SECTIONS[idx].name
end

local function rebuild_scale()
  SCALE_CACHE = {}
  gen_synth(cur_section)
end

-- ============================================================
-- PLAYBACK (with engine + MIDI)
-- ============================================================
local function send_note_on(note,vel)
  -- Engine output
  local freq = midi_to_hz(note)
  local engine_id = next_engine_id
  engine.noteOn(engine_id, freq, vel / 127)
  engine_ids[note] = engine_id
  next_engine_id = next_engine_id + 1
  
  -- MIDI output
  if m then m:note_on(note,math.floor(util.clamp(vel,1,127)),OP1_CH) end
  opxy_note_on(note, math.floor(util.clamp(vel,1,127)))
end

local function send_note_off(note)
  -- Engine output
  local engine_id = engine_ids[note]
  if engine_id then
    engine.noteOff(engine_id)
    engine_ids[note] = nil
  end

  -- MIDI output
  if m then m:note_off(note,0,OP1_CH) end
  opxy_note_off(note)
end

local function send_cc(slot,val)
  if m then m:cc(CC[slot],math.floor(util.clamp(val,0,127)),OP1_CH) end
  anim.lfo_flash[slot]=math.max(anim.lfo_flash[slot],0.3)
end

local function stop_all()
  engine.noteKillAll()
  engine_ids = {}
  if m then
    for i = 0, 127 do m:note_off(i, 0, OP1_CH) end
    m:cc(123, 0, OP1_CH)
  end
  if opxy_out then opxy_out:cc(123, 0, params:get("opxy_channel")) end
end

-- ============================================================
-- LFO ENGINE
-- ============================================================
local function shape_sine(ph)   return 0.5+0.5*math.sin(ph*math.pi*2) end
local function shape_tri(ph)    return ph<0.5 and ph*2 or 2-ph*2 end
local function shape_saw_u(ph)  return ph end
local function shape_saw_d(ph)  return 1-ph end
local function shape_sq(ph)     return ph<0.5 and 1 or 0 end
local function shape_sqs(ph)
  local s=0.05; if ph<s then return ph/s elseif ph<0.5-s then return 1
  elseif ph<0.5+s then return 1-((ph-(0.5-s))/(s*2)) else return 0 end
end
local function shape_steps(ph) math.randomseed(math.floor(ph*8)*997); return math.random() end
local SHAPE_NAMES = {"sine","tri","saw↑","saw↓","sq","s.sq","steps","S&H"}
local SHAPE_FNS   = {shape_sine,shape_tri,shape_saw_u,shape_saw_d,shape_sq,shape_sqs,shape_steps,nil}

local lfo = {}
for i=1,4 do
  lfo[i]={on=false,shape=1,sync=true,sync_div=4,phase=0,depth=40,centre=64,
          polarity=1,env_shape=1,sh_val={0.5},last_cc=64,euclid_on=false,
          euclid_k=4,euclid_n=8,euclid_pat=gen_euclid(4,8)}
end

local function lfo_env_amp(e,ph)
  if e==1 then return 1 elseif e==2 then return ph elseif e==3 then return 1-ph
  elseif e==4 then return math.sin(ph*math.pi) else return 1-math.sin(ph*math.pi) end
end

local function tick_lfo(i, dt)
  local l=lfo[i]; if not l.on then return l.last_cc end
  local rate_hz = l.sync and (1/clock.get_beat_sec()/l.sync_div) or l.rate
  local prev=l.phase; l.phase=(l.phase+rate_hz*dt)%1
  if l.shape==8 and l.phase<prev then l.sh_val[1]=math.random() end
  local raw=(SHAPE_FNS[l.shape] or function() return l.sh_val[1] end)(l.phase)
  raw=raw*lfo_env_amp(l.env_shape,l.phase)
  if l.euclid_on and #l.euclid_pat>0 then
    if not l.euclid_pat[math.floor(l.phase*#l.euclid_pat)+1] then raw=0.5 end
  end
  local cv = l.polarity==1 and (l.centre+(raw-0.5)*2*l.depth) or (l.centre+raw*l.depth)
  l.last_cc=math.floor(util.clamp(cv,0,127))
  return l.last_cc
end

-- ============================================================
-- ANIMATION STATE (ENHANCED WITH POPUP & BEAT PHASE)
-- ============================================================
local anim = {
  msg="",msg_timer=0,msg_ttl=1.8,
  note_flash=0,drum_flash=0,lfo_flash={0,0,0,0},
  page_anim=1,play_pulse=0,enc_spark={0,0,0},
  arp_history={},arp_hist_max=32,drum_last={},
  section_flash=0,
  drum_sparks={},
  phrase_history={},
  -- ENHANCED: Popup parameter display (transient)
  popup_param = "",
  popup_val = "",
  popup_time = 0,
  popup_ttl = 0.8,
  -- ENHANCED: Beat phase for pulse animations
  beat_phase = 0,
  -- ENHANCED: MIDI input indicator
  midi_flash = 0,
}
local DECAY=0.10
local redraw_metro

local function toast(msg) anim.msg=msg; anim.msg_timer=anim.msg_ttl end

-- ENHANCED: Helper to set transient parameter popup
local function set_popup(param, val)
  anim.popup_param = param
  anim.popup_val = val
  anim.popup_time = anim.popup_ttl
end

-- ============================================================
-- STATE
-- ============================================================
local m
local playing  = false
local page     = 1
local alt      = false
local step_vis = 1
local pages     = {"DRUM","SYNTH","LFO","PERFORM"}
local page_icon = {"◈","~","∿","✦"}
local lfo_focus = 1

local glob = {
  tempo_bpm=120, clock_send=true,
  mute_drum=false, mute_synth=false, mute_arp=false,
  vel_follow=false,
}

local cur_section = SECTIONS[1]

-- ============================================================
-- HELPERS
-- ============================================================
local function rrand(lo,hi) return lo+math.floor(math.random()*(hi-lo+1)) end

-- ============================================================
-- SEQUINS
-- ============================================================
local function init_sequins()
  synth.seq_scale   = sequins({"minor","dorian","pentatonic","minor","phrygian","blues"})
  synth.seq_density = sequins({0.4,0.65,0.5,0.7,0.35,0.6})
  synth.seq_contour = sequins({"arch","fall","rise","zigzag","static","random"})
  drum.seq_density  = sequins({0.4,0.65,0.5,0.75,0.45,0.7})
  arp.seq_pattern   = sequins({"up","bounce","skip","cascade","trill","random"})
  arp.seq_chord     = sequins({"minor","sus2","min7","dom7","power","maj7"})
end

-- ============================================================
-- LATTICE
-- ============================================================
local the_lattice
local patt_drum,patt_synth,patt_arp,patt_lfo,patt_section

local function drum_hit(note, vel, len, timing_nudge)
  local nudge = timing_nudge or 0
  clock.run(function()
    if nudge > 0 then clock.sleep(nudge) end
    send_note_on(note, vel)
    clock.sleep(clock.get_beat_sec() * (len or 0.15))
    send_note_off(note)
  end)
end

local function build_lattice()
  if the_lattice then the_lattice:destroy() end
  the_lattice=lattice:new{auto=true,meter=4,ppqn=96}

  -- DRUM: 16th notes with micro-timing, ghost notes, fills
  local ds=0
  patt_drum=the_lattice:new_pattern{
    division=1/4, enabled=true,
    action=function(t)
      ds=(ds%drum.steps)+1; step_vis=ds
      anim.drum_last={}

      local is_bar_end = (ds >= drum.fill_step)
      if ds == 1 then
        drum.fill_active = math.random() < drum.fill_prob
        if drum.fill_active then
          drum.fill = gen_drum_fill(cur_section)
        end
      end

      if not glob.mute_drum then
        local p  = drum.pattern[ds]
        local v  = drum.vels[ds]
        local gp = drum.ghost[ds]
        local gv = drum.ghost_v[ds]
        local fp = drum.fill_active and drum.fill[ds]

        for _,voice in ipairs(drum_voices) do
          local note = drum_voice_notes[voice]
          if not note then goto continue end
          local hit_vel = 0
          local use_fill = fp and fp[voice]
          if use_fill and is_bar_end then
            hit_vel = vel_curve(drum.velocity_curve, 90)
          elseif p and p[voice] and v and v[voice] and v[voice]>0 then
            hit_vel = v[voice]
          elseif gp and gp[voice] and gv and gv[voice] then
            hit_vel = gv[voice]
          end
          if hit_vel > 0 then
            local nudge = 0
            if drum.swing_amt > 0 and ds % 2 == 0 then
              nudge = clock.get_beat_sec() * drum.swing_amt
            end
            nudge = nudge + micro_timing(section_state.energy) * clock.get_beat_sec()
            drum_hit(note, hit_vel, 0.12, math.max(0, nudge))
            anim.drum_last[voice]=true
            anim.drum_flash=1.0
            if record_mode_active and drum.pattern[ds][voice] then
              capture_drum_event(ds, drum.pattern[ds])
            end
          end
          ::continue::
        end
      end

      anim.play_pulse=1.0
      -- ENHANCED: Track beat phase for status strip pulse
      anim.beat_phase = (anim.beat_phase + 0.0625) % 1.0
    end
  }

  -- SYNTH: 16th notes, phrase-aware, with passing tones
  local ss=0
  patt_synth=the_lattice:new_pattern{
    division=1/4, enabled=true,
    action=function(t)
      ss=(ss%synth.steps)+1
      if not glob.mute_synth and synth.pattern[ss] then
        local n=synth.notes[ss]; local vel=synth.vels[ss]
        local len=synth.lengths[ss]
        vel=vel+math.random(-8,8)
        if n and vel>0 then
          send_note_on(n,vel)
          anim.note_flash=1.0
          clock.run(function()
            clock.sleep(clock.get_beat_sec()*len)
            send_note_off(n)
          end)
          if record_mode_active then
            capture_synth_event(ss, n)
          end
        end
      end
    end
  }

  -- LFO: every beat for smoother CV
  patt_lfo=the_lattice:new_pattern{
    division=1, enabled=true,
    action=function(t)
      for i=1,4 do
        if lfo[i].on then
          local cc_val=tick_lfo(i,0.016)
          send_cc(i,cc_val)
        end
      end
    end
  }

  -- ARP: variable speed arp playback
  local arp_step_count = 0
  patt_arp=the_lattice:new_pattern{
    division=1/4, enabled=true,
    action=function(t)
      if not arp.on or glob.mute_arp then return end
      if not arp._notes or #arp._notes == 0 then return end
      arp_step_count = arp_step_count + 1
      -- speed: 1=every 16th, 2=every 8th, 4=every beat
      if arp_step_count % arp.speed ~= 0 then return end
      arp._step = (arp._step or 0) + 1
      local pattern_fn = arp._pattern_fn or ARP_PATTERNS.up
      local note = pattern_fn(arp._notes, arp._step)
      if note then
        local vel = vel_curve(section_state.velocity_curve or "medium", 85)
        send_note_on(note, vel)
        clock.run(function()
          clock.sleep(clock.get_beat_sec() * 0.2)
          send_note_off(note)
        end)
        -- track for arp history visualization
        table.insert(anim.arp_history, 1, note)
        while #anim.arp_history > anim.arp_hist_max do
          table.remove(anim.arp_history)
        end
      end
    end
  }

  -- SECTION: auto-advance (every bar = 4 beats)
  patt_section=the_lattice:new_pattern{
    division=4, enabled=true,
    action=function(t)
      if section_state.auto_mode then
        section_state.elapsed_bars = (section_state.elapsed_bars % 999) + 1
        local sec = SECTIONS[section_state.current]
        if sec.auto_advance and section_state.elapsed_bars >= sec.bars then
          next_section()
        end
      end
    end
  }

  the_lattice:start()
end

-- ============================================================
-- PAGES: DRAW
-- ============================================================
local function draw_drum_page()
  screen.level(5); screen.move(2,25); screen.text("16 STEPS")
  local dy=35
  for si=1,2 do
    for si2=1,8 do
      local s=(si-1)*8+si2
      local is_cur=(s==step_vis)
      local on=drum.pattern[s] and drum.pattern[s].snare
      screen.level(is_cur and 15 or (on and 10 or 2))
      local x=2+(si2-1)*15
      screen.rect(x,dy+(si-1)*8,13,7); if on or is_cur then screen.fill() else screen.stroke() end
    end
  end
  draw_energy_bar()
end

local function draw_synth_page()
  screen.level(5); screen.move(2,25); screen.text("SYNTH")
  for s=1,16 do
    local n=synth.notes[s]
    if n then
      screen.level(s==step_vis and 15 or 10)
      local x=2+(s-1)*7.5
      screen.rect(x,40,6,6); screen.fill()
    end
  end
  draw_energy_bar()
end

local function draw_lfo_page()
  screen.level(5)
  screen.move(2,25); screen.text("LFO "..lfo_focus)
  local l=lfo[lfo_focus]
  screen.level(10); screen.move(35,25); screen.text(SHAPE_NAMES[l.shape].." d:"..l.depth)
  screen.level(5); screen.move(2,35); screen.text("sync:"..( l.sync and "ON" or "OFF"))
  screen.level(10); screen.move(40,35); screen.text("div:"..l.sync_div)
  draw_energy_bar()
end

local function draw_perform_page()
  screen.level(5)
  screen.move(2,25); screen.text("PERFORM")
  for i=1,4 do
    screen.level(lfo[i].on and 12 or 3)
    screen.move(2,35+(i-1)*8); screen.text(CC_DEST[i].." "..lfo[i].centre)
  end
end

local function pill(x,y,w,h,val,mx,bl,fl)
  screen.level(bl or 2); screen.rect(x,y,w,h); screen.stroke()
  local fw=math.max(0,math.floor(w*util.clamp(val/mx,0,1)))
  if fw>0 then screen.level(fl or 10); screen.rect(x,y,fw,h); screen.fill() end
end

-- Energy bar (right side, vertical)
local function draw_energy_bar()
  local e=section_state.energy
  local bh=40; local by=14; local bx=122
  screen.level(2); screen.rect(bx,by,4,bh); screen.stroke()
  local fh=math.floor(bh*e)
  local el=math.floor(4+e*11+anim.section_flash*6)
  screen.level(el); screen.rect(bx,by+bh-fh,4,fh); screen.fill()
end

-- ============================================================
-- MAIN
-- ============================================================
function init()
  math.randomseed(os.time())
  m=midi.connect(MIDI_DEV)
  init_midi_handler()

  params:add_separator("FIELDBOT")
  params:add_number("midi_dev","MIDI device",1,4,1)
  params:set_action("midi_dev",function(v) MIDI_DEV=v; m=midi.connect(v); init_midi_handler() end)
  params:add_number("op1_ch","OP-1 channel",1,16,1)
  params:set_action("op1_ch",function(v) OP1_CH=v end)
  params:add_separator("OP-XY")
  params:add_number("opxy_device","OP-XY MIDI Device",1,4,2)
  params:set_action("opxy_device",function(v)
    opxy_out=midi.connect(v)
  end)
  params:add_number("opxy_channel","OP-XY MIDI Channel",1,16,1)
  opxy_out=midi.connect(params:get("opxy_device"))
  params:add_option("scale","Scale",scale_names,1)
  params:set_action("scale",function(v)
    synth.scale=scale_names[v]; arp.root=synth.root-12
    gen_synth(cur_section); toast("scale → "..scale_names[v])
  end)
  params:add_number("root","Root (MIDI)",48,72,60)
  params:set_action("root",function(v)
    synth.root=v; arp.root=v-12; gen_synth(cur_section)
  end)

  for i=1,4 do lfo[i].euclid_pat=gen_euclid(lfo[i].euclid_k,lfo[i].euclid_n) end
  init_sequins()

  apply_section(1)
  cur_section=SECTIONS[1]
  build_arp_()

  redraw_metro=metro.init(function()
    local function d(v) return math.max(0,v-DECAY) end
    anim.note_flash=d(anim.note_flash); anim.drum_flash=d(anim.drum_flash)
    anim.play_pulse=d(anim.play_pulse); anim.section_flash=d(anim.section_flash)
    for i=1,4 do anim.lfo_flash[i]=d(anim.lfo_flash[i]) end
    for i=1,3 do anim.enc_spark[i]=d(anim.enc_spark[i]) end
    anim.page_anim=math.min(1,anim.page_anim+0.14)
    if anim.msg_timer>0 then
      anim.msg_timer=anim.msg_timer-(1/60)
      if anim.msg_timer<=0 then anim.msg="" end
    end
    redraw()
  end,1/60,-1)
  redraw_metro:start()

  anim.page_anim=0
  toast("FIELDBOT v3.2 ENHANCED")
  redraw()
end

-- ============================================================
-- CONTROLS
-- ============================================================
function key(id,z)
  if id==1 then alt=(z==1); redraw(); return end
  if z==0 then return end

  if id==2 then
    if alt then
      playing=not playing
      if playing then
        if m then m:start() end
        build_lattice(); toast("▶  "..section_state.name)
      else
        stop_all(); toast("■  stopped")
      end
    else
      if page==1 then
        gen_drums(cur_section); toast("drums regen → "..section_state.name)
      elseif page==2 then
        gen_synth(cur_section); toast("synth regen / "..synth.contour)
      elseif page==3 then
        lfo_focus=(lfo_focus%4)+1; toast("LFO "..lfo_focus.." → "..CC_DEST[lfo_focus])
      elseif page==4 then
        for i=1,4 do lfo[i].shape=rrand(1,#SHAPE_NAMES); lfo[i].depth=rrand(20,55) end
        toast("LFOs randomised")
      end
    end
  end

  if id==3 then
    if alt then
      if m then m:stop(); clock.sleep(0.05); m:start() end
      toast("seq reset")
    else
      if page==1 then
        local sname=next_section()
        cur_section=SECTIONS[section_state.current]
        anim.section_flash=1.0
        toast("→ "..sname)
      elseif page==2 then
        synth.contour=synth.seq_contour()
        gen_synth(cur_section)
        toast("contour → "..synth.contour)
      elseif page==3 then
        lfo[lfo_focus].on=not lfo[lfo_focus].on
        toast("LFO "..lfo_focus.." "..(lfo[lfo_focus].on and "ON" or "OFF"))
      elseif page==4 then
        stop_all(); toast("PANIC")
      end
    end
  end

  redraw()
end

-- ENHANCED: encoder with popup tracking
function enc(id,d)
  anim.enc_spark[id]=1.0
  if id==1 then page=util.clamp(page+d,1,#pages); anim.page_anim=0; return end

  if page==1 then  -- DRUM
    if id==2 then
      section_state.energy=util.clamp(section_state.energy+d*0.05,0,1)
      SECTIONS[section_state.current].energy=section_state.energy
      gen_drums(SECTIONS[section_state.current])
      toast(string.format("energy %.0f%%",section_state.energy*100))
      set_popup("ENERGY", string.format("%.0f%%",section_state.energy*100))
    elseif id==3 then
      drum.swing_amt=util.clamp(drum.swing_amt+d*0.005,0,0.15)
      toast(string.format("swing %.0f%%",drum.swing_amt/0.15*100))
      set_popup("SWING", string.format("%.0f%%",drum.swing_amt/0.15*100))
    end

  elseif page==2 then  -- SYNTH
    if id==2 then
      synth.register=util.clamp(synth.register+d,0,2)
      local regs={"low","mid","high"}
      gen_synth(cur_section)
      toast("register: "..regs[synth.register+1])
      set_popup("REGISTER", regs[synth.register+1])
    elseif id==3 then
      local names=synth.contour_names
      local ci=1
      for i,n in ipairs(names) do if n==synth.contour then ci=i end end
      ci=util.clamp(ci+d,1,#names)
      synth.contour=names[ci]
      gen_synth(cur_section)
      toast("contour: "..synth.contour)
      set_popup("CONTOUR", synth.contour)
    end

  elseif page==3 then  -- LFO
    local l=lfo[lfo_focus]
    if id==2 then
      l.shape=util.clamp(l.shape+d,1,#SHAPE_NAMES)
      toast("LFO"..lfo_focus.." "..SHAPE_NAMES[l.shape])
      set_popup("LFO"..lfo_focus.." SHAPE", SHAPE_NAMES[l.shape])
    elseif id==3 then
      if alt then
        local divs={0.25,0.5,1,2,4,8,16}
        local dn={"1/16","1/8","1/4","1/2","1b","2b","4b"}
        local ci=1
        for i,v in ipairs(divs) do if math.abs(v-l.sync_div)<0.01 then ci=i end end
        ci=util.clamp(ci+d,1,#divs); l.sync_div=divs[ci]
        toast("LFO"..lfo_focus.." "..dn[ci])
        set_popup("LFO"..lfo_focus.." DIV", dn[ci])
      else
        l.depth=util.clamp(l.depth+d,0,64)
        toast("LFO"..lfo_focus.." depth "..l.depth)
        set_popup("LFO"..lfo_focus.." DEPTH", tostring(l.depth))
      end
    end

  elseif page==4 then  -- PERFORM
    if id==2 then
      lfo_focus=util.clamp(lfo_focus+d,1,4)
      toast("focus: "..CC_DEST[lfo_focus])
      set_popup("FOCUS", CC_DEST[lfo_focus])
    elseif id==3 then
      local l=lfo[lfo_focus]
      l.centre=util.clamp(l.centre+d,0,127)
      if not l.on then send_cc(lfo_focus,l.centre) end
      toast(CC_DEST[lfo_focus].." centre "..l.centre)
      set_popup(CC_DEST[lfo_focus].." CENTRE", tostring(l.centre))
    end
  end
  redraw()
end

-- ============================================================
-- SCREEN (ENHANCED WITH STATUS STRIP & POPUP)
-- ============================================================
function redraw()
  screen.clear(); screen.aa(0); screen.font_size(8)

  -- =============== STATUS STRIP (y=0-8) ===============
  -- FIELDBOT title (level 4: structure)
  screen.level(4)
  screen.move(2, 8); screen.text("FIELDBOT")
  
  -- Current page name (level 8: primary content)
  screen.level(8)
  screen.move(40, 8); screen.text(pages[page])
  
  -- Page dots (filled for current, level 3/12: structure/active)
  for i = 1, 4 do
    local dot_x = 72 + (i-1) * 6
    if i == page then
      screen.level(12); screen.rect(dot_x, 3, 4, 4); screen.fill()
    else
      screen.level(3); screen.rect(dot_x, 3, 4, 4); screen.stroke()
    end
  end
  
  -- Beat pulse dot at x=124 (pulsing with beat phase)
  local pulse_bright = math.floor(3 + anim.beat_phase * 12)
  screen.level(pulse_bright)
  screen.rect(124, 3, 3, 3); screen.fill()
  
  -- Separator line (level 3: structure)
  screen.level(3)
  screen.move(0, 9); screen.line(128, 9); screen.stroke()

  -- =============== ORIGINAL CONTENT (BRIGHTNESS ENHANCED) ===============
  -- Play indicator (pulsing when playing, level 6-15)
  screen.level(playing and math.floor(6+anim.play_pulse*9) or 2)
  screen.move(0, 18); screen.text(playing and "▶" or "■")
  
  -- Page icon animation (level 15 at full)
  screen.level(math.floor(anim.page_anim*15))
  screen.move(10, 18); screen.text(page_icon[page])
  
  -- Note activity (level 5-15: labels to active)
  screen.level(5 + math.floor(anim.note_flash*10))
  screen.move(80, 18); screen.text("♩")
  
  -- Drum activity (level 5-15: labels to active)
  screen.level(5 + math.floor(anim.drum_flash*10))
  screen.move(88, 18); screen.text("●")
  
  -- LFO dots (level 2-15: inactive to active hierarchy)
  for i=1,4 do
    if lfo[i].on then
      screen.level(math.floor(10 + anim.lfo_flash[i]*5))
    else
      screen.level(2)
    end
    screen.move(96+(i-1)*7, 18); screen.text("∿")
  end
  
  -- Step counter (level 3-5: structure)
  screen.level(playing and 5 or 2)
  screen.move(122, 18)
  screen.text(string.format("%02d", step_vis))

  -- TOAST (popup toast message)
  if anim.msg~="" and anim.msg_timer>0 then
    local a=math.min(1,anim.msg_timer*2.5)
    local tw=string.len(anim.msg)*5+8
    screen.level(1); screen.rect(64-tw/2,11,tw,9); screen.fill()
    screen.level(math.floor(a*15)); screen.move(65-tw/2,19); screen.text(anim.msg)
  end

  -- PAGE CONTENT
  if     page==1 then draw_drum_page()
  elseif page==2 then draw_synth_page()
  elseif page==3 then draw_lfo_page()
  elseif page==4 then draw_perform_page()
  end

  -- ENCODER SPARK (level 15 at peak: active/selected)
  for i=1,3 do
    if anim.enc_spark[i]>0.05 then
      local s=math.floor(anim.enc_spark[i]*3)
      screen.level(math.floor(anim.enc_spark[i]*15))
      screen.rect((i-1)*55+5,60,s,s); screen.fill()
    end
  end

  -- ALT INDICATOR (level 15: active/selected)
  if alt then screen.level(15); screen.move(118,18); screen.text("[⇧]") end
  
  -- =============== PARAMETER POPUP OVERLAY (ENHANCED) ===============
  if anim.popup_time > 0 then
    anim.popup_time = anim.popup_time - (1/60)
    
    -- Dark background (level 1: background)
    screen.level(1)
    screen.rect(10, 25, 108, 20)
    screen.fill()
    
    -- Popup border (level 3: structure)
    screen.level(3)
    screen.rect(10, 25, 108, 20)
    screen.stroke()
    
    -- Parameter name (level 15: active)
    screen.level(15)
    screen.move(15, 33)
    screen.text(anim.popup_param)
    
    -- Parameter value (level 15: active)
    screen.level(15)
    screen.move(15, 42)
    screen.text(anim.popup_val)
  end
  
  screen.update()
end

-- ============================================================
-- CLEANUP
-- ============================================================
function cleanup()
  if redraw_metro then redraw_metro:stop() end
  if the_lattice  then the_lattice:destroy() end
  stop_all()
  if m then
    m:stop()
    for i=0,127 do m:note_off(i,0,OP1_CH) end
    m:cc(123,0,OP1_CH)
    for i=1,4 do m:cc(CC[i],64,OP1_CH) end
  end
  if opxy_out then opxy_out:cc(123, 0, params:get("opxy_channel")) end
end
