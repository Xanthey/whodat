
-- graphs.lua
-- WhoDAT – production-ready graphs module using optimized sparkline renderer (Wrath 3.3.5a safe)
local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS
local U = NS.Utils or {}
local function now() return time() end

-- ============================================================================
-- Utilities
-- ============================================================================

-- --- NEW: Session window helpers -------------------------------------------
local function _sortedLastSessions(db, n)
  -- Accepts top-level WhoDatDB.sessions (global) or per-character sessions
  -- Returns a list of {start_ts = <number>, end_ts = <number>} sorted ascending, sliced to last n.
  if not db then return {} end

  -- Prefer per-character sessions if present; else use global
  local key, C = (U.GetPlayerKey and U.GetPlayerKey()) or ( (GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player") )
  local charBucket = db.characters and db.characters[key]
  local sessions = (charBucket and charBucket.sessions) or db.sessions or {}

  -- Copy defensively and sort by start_ts (fallback to ts if needed)
  local buf = {}
  for _, s in pairs(sessions) do
    local start_ts = tonumber(s.start_ts or s.ts or 0) or 0
    local end_ts   = tonumber(s.end_ts   or s.te or start_ts) or start_ts
    if start_ts > 0 then
      buf[#buf+1] = { start_ts = start_ts, end_ts = math.max(end_ts, start_ts) }
    end
  end
  table.sort(buf, function(a,b) return (a.start_ts or 0) < (b.start_ts or 0) end)

  if type(n) ~= "number" or n <= 0 then return buf end
  local take = math.min(n, #buf)
  local out = {}
  for i = (#buf - take + 1), #buf do
    if i >= 1 then out[#out+1] = buf[i] end
  end
  return out
end

local function _filterPointsBySessions(points, sessions)
  if not points or #points == 0 then return {} end
  if not sessions or #sessions == 0 then return points end -- fallback: no session scope
  local out = {}
  for i = 1, #points do
    local p = points[i]
    local ts = p and tonumber(p.ts or 0) or 0
    if ts > 0 then
      -- include point if it falls within any of the last-N session ranges
      for _, s in ipairs(sessions) do
        if ts >= (s.start_ts or 0) and ts <= (s.end_ts or ts) then
          out[#out+1] = p
          break
        end
      end
    end
  end
  return out
end

local function getChar()
  local key = (U.GetPlayerKey and U.GetPlayerKey())
            or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  return key, C
end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b else return v end end

-- Strip any trailing "(... data)" marker appended previously
local function stripNoData(label)
  local s = (label or "")
  s = s:gsub('%s%(%w+%sdata%)$', '')          -- "(no data)" etc.
  s = s:gsub('%s%([^%)]*data%)$', '')         -- "(no non-zero data)" etc. (FIXED)
  return s
end

local function getValue(points, i)
  local p = points[i]
  return (p and (p.value or p.val or p.hp)) or 0
end
local function lastValue(points)
  if not points or #points == 0 then return nil end
  local p = points[#points]
  return (p and (p.value or p.val or p.hp)) or 0
end

-- Compress runs of identical values (for money or extremely flat series)
local function compressRuns(arr)
  local out, last = {}, nil
  for i = 1, #(arr or {}) do
    local p = arr[i]
    local v = (p and (p.value or p.val or p.hp)) or 0
    if last == nil or v ~= last then out[#out+1] = p; last = v end
  end
  return out
end

-- Filter out samples with zero value (compacts timeline by removing 0s)
local function filterNonZero(arr)
  local out = {}
  for i = 1, #(arr or {}) do
    local p = arr[i]
    local v = (p and (p.value or p.val or p.hp)) or 0
    if v ~= 0 then out[#out+1] = p end
  end
  return out
end

-- ============================================================================
-- Formatting helpers (tooltips)
-- ============================================================================
local function formatCopperLocal(copper)
  copper = tonumber(copper or 0) or 0
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  return string.format("%dg %ds %dc", g, s, c)
end
local function formatMoney(copper)
  if U and U.FormatMoney then return U.FormatMoney(copper) end
  return formatCopperLocal(copper)
end
local function formatDelta(val, prev, unitLabel)
  local delta = (tonumber(val or 0) or 0) - (tonumber(prev or 0) or 0)
  local sign = delta >= 0 and "+" or "-"
  local abs = math.abs(delta)
  if unitLabel == "copper" then
    return string.format("%s %s", sign, formatMoney(abs))
  elseif unitLabel and unitLabel ~= "" then
    return string.format("%s %d %s", sign, abs, unitLabel)
  else
    return string.format("%s %d", sign, abs)
  end
end
local function formatTimestamp(ts)
  ts = tonumber(ts or 0) or 0
  return date("%Y-%m-%d %H:%M:%S", ts)
end

-- ============================================================================
-- Forward declarations (closures below capture these as locals/upvalues)
-- ============================================================================
local _explainPower, _explainDefense
local _explainPowerAt, _explainDefenseAt

-- Helpers used by synthesis & breakdowns
local function _last(tbl) return (tbl and #tbl>0) and tbl[#tbl] or nil end
local function _safe(v) return tonumber(v or 0) or 0 end
local function _inv_speed(s) s = _safe(s); if s <= 0 then return 0 end; return 1.0 / s end

-- Return the last sample on or before ts; fallback to last available
local function _getLastOnOrBefore(arr, ts)
  if not arr or #arr == 0 then return nil end
  if not ts then return _last(arr) end
  for i = #arr, 1, -1 do
    local item = arr[i]
    local its = item and item.ts
    if its and its <= ts then return item end
  end
  return _last(arr)
end

-- ============================================================================
-- Sparkline/Plot object (optimized)
-- ============================================================================
local function CreateSparkline(parent, w, h)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(h or 80)
  if f.SetClipsChildren then f:SetClipsChildren(true) end -- hard clip children

  -- Background
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  bg:SetVertexColor(0, 0, 0, 0.6)

  -- Baseline
  local axis = f:CreateTexture(nil, "ARTWORK")
  axis:SetTexture("Interface\\Buttons\\WHITE8x8")
  axis:SetVertexColor(1, 1, 1, 0.15)
  axis:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  axis:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  axis:SetHeight(1)

  -- Caches (reused)
  f.columns = {}
  f.paddingL, f.paddingR, f.paddingT, f.paddingB = 4, 4, 4, 4
  function f:SetPalette(r, g, b, a) f.r, f.g, f.b, f.a = r or 0.2, g or 0.7, b or 1.0, a or 0.85 end
  f:SetPalette(0.2, 0.7, 1.0, 0.85)

  -- Stable scale cache
  f._prevMinV, f._prevMaxV, f._prevWindowLen, f._prevLastVal = nil, nil, nil, nil

  -- series/meta/opts
  function f:SetSeries(series, opts)
    f.series = series or {}
    f.opts = opts or {}
    if f.opts.tooltip_enable == nil then f.opts.tooltip_enable = true end
    if f.opts.max_points == nil then f.opts.max_points = 1000 end
    if f.opts.max_ui_columns == nil then f.opts.max_ui_columns = 256 end
    if f.opts.gradient_enable == nil then f.opts.gradient_enable = false end
  end

  -- Single hover overlay
  local hover = CreateFrame("Button", nil, f)
  hover:EnableMouse(true)
  hover:SetFrameLevel(f:GetFrameLevel() + 20)
  hover:SetAllPoints(f)
  hover:SetHitRectInsets(0, 0, 0, 0)
  f._hoverActive = false
  f._lastHoverCol = nil
  hover:SetScript("OnEnter", function() f._hoverActive = true end)
  hover:SetScript("OnLeave", function() f._hoverActive = false; if GameTooltip then GameTooltip:Hide() end end)
  hover:SetScript("OnUpdate", function()
    if not f._hoverActive or not GameTooltip or not f._indexMap then return end
    local w, h = f:GetWidth(), f:GetHeight()
    local padL, padR, padT, padB = f.paddingL, f.paddingR, f.paddingT, f.paddingB
    local innerW = w - padL - padR
    if innerW <= 0 then return end

    local xCursor = select(1, GetCursorPosition())
    local scale = UIParent:GetScale()
    xCursor = xCursor / (scale or 1)
    local left = f:GetLeft() or 0
    local xRel = xCursor - left - padL
    local colW = f._colW or 1
    local idx = math.floor(xRel / colW) + 1
    if idx < 1 then idx = 1 end
    if idx > (f._usedCols or 0) then idx = (f._usedCols or 0) end

    if idx ~= f._lastHoverCol then
      f._lastHoverCol = idx
      local dataIndex = f._indexMap[idx]
      if dataIndex then
        local p = f.series[dataIndex]
        local val = (p and (p.value or p.val or p.hp)) or 0
        local prevVal = getValue(f.series, dataIndex - 1) or 0
        local tsHover = p and p.ts
        local tsText = formatTimestamp(tsHover)
        local key = f.opts.meta and f.opts.meta.key or "series"
        local label = f.opts.meta and f.opts.meta.label or "Series"

        -- Power/Defense-aware tooltip using hovered timestamp
        GameTooltip:SetOwner(hover, "ANCHOR_CURSOR")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(label .. " • " .. tsText, 1, 1, 1)
        if key == "money" then
          GameTooltip:AddLine("Value: " .. formatMoney(val), 1, 0.82, 0)
          GameTooltip:AddLine("Δ Change: " .. formatDelta(val, prevVal, "copper"), 0.8, 0.9, 1)
        elseif key == "xp" then
          GameTooltip:AddLine("XP gained: " .. formatDelta(val, prevVal, "XP"), 0.8, 0.9, 1)
          GameTooltip:AddLine("Snapshot: " .. tostring(val) .. " XP", 0.9, 0.9, 0.9)
        elseif key == "rested" then
          GameTooltip:AddLine("Rested gained: " .. formatDelta(val, prevVal, "XP"), 0.8, 0.9, 1)
          GameTooltip:AddLine("Snapshot: " .. tostring(val) .. " rested XP", 0.9, 0.9, 0.9)
        elseif key == "honor" then
          GameTooltip:AddLine("Honor gained: " .. formatDelta(val, prevVal, "honor"), 0.8, 0.9, 1)
          GameTooltip:AddLine("Snapshot: " .. tostring(val) .. " honor", 0.9, 0.9, 0.9)
        elseif key == "power" then
          local _, CC = getChar()
          local expl = (tsHover and _explainPowerAt(CC or {}, tsHover)) or _explainPower(CC or {})
          GameTooltip:AddLine(("Total: %.2f"):format(expl.total), 0.9, 0.9, 0.9)
          GameTooltip:AddLine(("• Melee AP: %.2f  • Melee Crit: %.2f"):format(expl.melee_ap, expl.melee_crit), 0.8, 0.9, 1)
          GameTooltip:AddLine(("• MH Speed: %.2f  • OH Speed: %.2f"):format(expl.mh_inv, expl.oh_inv), 0.8, 0.9, 1)
          GameTooltip:AddLine(("• Ranged AP: %.2f  • Ranged Crit: %.2f  • Ranged Speed: %.2f"):format(expl.ranged_ap, expl.ranged_crit, expl.ranged_spd), 0.8, 0.9, 1)
          GameTooltip:AddLine(("• Spell Power: %.2f  • Spell Crit: %.2f  • Penetration: %.2f"):format(expl.spell_power, expl.spell_crit, expl.penetration), 0.8, 0.9, 1)
          GameTooltip:AddLine(("• Strength: %.2f  • Agility: %.2f"):format(expl.strength, expl.agility), 0.8, 0.9, 1)
        elseif key == "defense" then
          local _, CC = getChar()
          local expl = (tsHover and _explainDefenseAt(CC or {}, tsHover)) or _explainDefense(CC or {})
          GameTooltip:AddLine(("Total: %.2f"):format(expl.total), 0.9, 0.9, 0.9)
          GameTooltip:AddLine(("• Max HP: %.2f  • Stamina: %.2f"):format(expl.hp_max, expl.stamina), 0.8, 0.9, 1)
          GameTooltip:AddLine(("• Armor: %.2f  • Defense: %.2f"):format(expl.armor, expl.defense), 0.8, 0.9, 1)
          GameTooltip:AddLine(("• Dodge: %.2f  • Parry: %.2f  • Block: %.2f"):format(expl.dodge, expl.parry, expl.block), 0.8, 0.9, 1)
          GameTooltip:AddLine(("• Resist (avg): %.2f"):format(expl.resist_avg), 0.8, 0.9, 1)
        else
          -- Generic series fallback
          GameTooltip:AddLine("Value: " .. tostring(val), 0.9, 0.9, 0.9)
          GameTooltip:AddLine("Δ Change: " .. formatDelta(val, prevVal, ""), 0.8, 0.9, 1)
        end
        GameTooltip:Show()
      end
    end
  end)

  -- Render (sampling & pooled textures)
  function f:Render()
    local w, h = self:GetWidth(), self:GetHeight()
    local padL, padR, padT, padB = self.paddingL, self.paddingR, self.paddingT, self.paddingB
    local innerW = w - padL - padR
    local innerH = h - padT - padB
    local function hideAll() for i = 1, #self.columns do local t = self.columns[i]; if t then t:Hide() end end end
    if innerW <= 0 or innerH <= 0 then hideAll(); return end

    local points = self.series or {}
    local N = #points
    if N > 0 and self._emptyLabel then self._emptyLabel:Hide() end
    if N == 0 then hideAll(); return end

    local take = math.max(1, math.min(self.opts.max_points or innerW, N))
    local startIdx = N - take + 1; if startIdx < 1 then startIdx = 1 end

    local minV, maxV = math.huge, -math.huge
    for i = startIdx, N do
      local v = getValue(points, i)
      if v < minV then minV = v end
      if v > maxV then maxV = v end
    end
    if minV == math.huge then minV = 0 end
    if maxV == -math.huge then maxV = 1 end

    local windowLen = (N - startIdx + 1)
    local lastVal = getValue(points, N)
    local stable = (windowLen == self._prevWindowLen) and (lastVal == self._prevLastVal)
    if stable and self._prevMinV and self._prevMaxV then
      minV, maxV = self._prevMinV, self._prevMaxV
    else
      if maxV == minV then maxV = minV + 1 end
      self._prevMinV, self._prevMaxV = minV, maxV
      self._prevWindowLen, self._prevLastVal = windowLen, lastVal
    end
    local function norm01(v) local n = (v - minV) / (maxV - minV); if n < 0 then n = 0 elseif n > 1 then n = 1 end; return n end

    local maxCols = math.max(32, self.opts.max_ui_columns or 256)
    local usedCols = math.min(maxCols, innerW)
    local stride = math.ceil(windowLen / usedCols)
    usedCols = math.min(usedCols, math.ceil(windowLen / stride))

    for i = #self.columns + 1, maxCols do
      local t = self:CreateTexture(nil, "OVERLAY")
      t:SetTexture("Interface\\Buttons\\WHITE8x8")
      t:SetVertexColor(self.r, self.g, self.b, self.a)
      self.columns[#self.columns + 1] = t
    end

    local smoothing = (self.opts.enable_smoothing ~= false)
    local colW = math.max(1, math.floor(innerW / usedCols))
    local ci, x = 1, padL
    self._indexMap = {}
    for dataIndex = startIdx, N, stride do
      if ci > usedCols then break end
      local v = getValue(points, dataIndex)
      local vSmooth = v
      if smoothing then
        local vp = getValue(points, dataIndex - 1)
        local vn = getValue(points, dataIndex + 1)
        vSmooth = (vp + v + vn) / 3
      end
      local norm = norm01(vSmooth)
      local colH = math.floor(norm * innerH); if colH < 1 then colH = 1 end

      local t = self.columns[ci]
      t:ClearAllPoints();
      local px = clamp(x, padL, w - padR - colW)
      local py = padB
      t:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", px, py)
      t:SetWidth(colW); t:SetHeight(colH)
      local bodyR, bodyG, bodyB, bodyA = self.r * 0.95, self.g * 0.95, self.b * 0.95, self.a * 0.90
      t:SetVertexColor(bodyR, bodyG, bodyB, bodyA)
      t:Show()
      self._indexMap[ci] = dataIndex
      x = x + colW
      ci = ci + 1
    end
    for j = ci, #self.columns do local t = self.columns[j]; if t then t:Hide() end end
    self._usedCols = ci - 1
    self._colW = colW
  end
  f:SetScript("OnSizeChanged", function(self) if self.Render then self:Render() end end)

  local E = _G.ElvUI and _G.ElvUI[1]
  if E and E.GetModule then local ok, S = pcall(E.GetModule, E, "Skins"); if ok and S and S.HandleFrame then S:HandleFrame(f) end end
  return f
end
NS.CreateSparkline = CreateSparkline

-- ============================================================================
-- Graphs module defaults (config via WhoDAT_Config.ui.graphs)
-- ============================================================================
NS.Graphs_DefaultConfig = {
  max_points_per_series = 1000,
  max_ui_columns = 256,
  enable_smoothing = true,
  gradient_enable = false,
  gradient_top_px = 2,
  gradient_bottom_px = 3,
  money_on_change_only = true,
  money_step_style = false,
  tooltip_enable = true,
  omit_zero_points = false,
  omit_zero_points_by_key = nil,
  empty_title_suffix_enable = true,
  empty_watermark_enable = false,
}
NS.Graphs = NS.Graphs or {}

-- === Synthesis Weights (class-agnostic, tunable) ===
NS.Graphs_Weights = {
  power = {
    -- Melee
    ap = 1.00,           -- total AP (apBase + apPos - apNeg)
    crit = 12.0,         -- melee crit %
    mh_speed_inv = 6.0,  -- faster mainhand increases swings (use 1/speed)
    oh_speed_inv = 3.0,  -- offhand contributes less
    -- Ranged
    r_ap = 0.80,
    r_crit = 10.0,
    r_speed_inv = 5.0,
    -- Spells
    spell_power = 0.60,  -- average spell bonus damage across schools
    spell_crit = 9.0,    -- average spell crit %
    penetration = 0.25,  -- spell pen helps against resist
    -- Primaries (broad nudge)
    strength = 0.40,
    agility  = 0.40,
  },
  defense = {
    hp_max = 1.00,       -- absolute buffer
    stamina = 10.0,      -- surrogate for HP scaling
    armor = 0.15,        -- physical mitigation
    defense = 8.0,       -- reduces crits & glancing blows
    dodge = 30.0,
    parry = 35.0,
    block = 22.0,
    resist_avg = 8.0,    -- average resist across schools
  },
}

-- ============================================================================
-- Synthesis snapshot helpers (used to feed synthetic series)
-- ============================================================================
local function _computePowerSnapshot(C)
  if not C or not C.series then return 0 end
  local W = NS.Graphs_Weights.power
  local a = _last(C.series and C.series.attack) or {}
  local s = _last(C.series and C.series["spell_ranged"]) or {}
  local b = _last(C.series and C.series.base_stats) or {}
  local vals = b or {}  -- NEW: flat structure
  
  -- Access directly: vals.strength, vals.agility, etc.
  local strength = _safe(vals.strength)
  local agility = _safe(vals.agility)

  -- Melee chunk
  local ap_total = _safe(a.apBase) + _safe(a.apPos) - _safe(a.apNeg)
  local melee = W.ap * ap_total
              + W.crit * _safe(a.crit)
              + W.mh_speed_inv * _inv_speed(a.mhSpeed)
              + W.oh_speed_inv * _inv_speed(a.ohSpeed)

  -- Ranged chunk
  local r = s.ranged or {}
  local ranged = W.r_ap * _safe(r.ap)
               + W.r_crit * _safe(r.crit)
               + W.r_speed_inv * _inv_speed(r.speed)

  -- Spell chunk (average across schools)
  local spell = s.spell or {}
  local schools = spell.schools or {}
  local sp_sum, sc_sum, sp_n = 0, 0, 0
  for _, info in pairs(schools) do
    sp_sum = sp_sum + _safe(info.dmg)
    sc_sum = sc_sum + _safe(info.crit)
    sp_n = sp_n + 1
  end
  local sp_avg = (sp_n > 0) and (sp_sum / sp_n) or 0
  local sc_avg = (sp_n > 0) and (sc_sum / sp_n) or 0
  local caster = W.spell_power * sp_avg
               + W.spell_crit  * sc_avg
               + W.penetration * _safe(spell.penetration)

  -- Broad primaries (small nudge)
  local primaries = W.strength * _safe(vals.strength)
                  + W.agility  * _safe(vals.agility)

  return melee + ranged + caster + primaries
end


-- Computes a defense snapshot using flat base_stats and top-level resistances
local function _computeDefenseSnapshot(C)
  -- Guard: if container/series missing, treat as 0
  if not C or not C.series then return 0 end

  local W = NS.Graphs_Weights.defense

  -- Latest snapshots from series
  local a = _last(C.series and C.series.attack) or {}
  local b = _last(C.series and C.series.base_stats) or {}      -- now flat
  local r = _last(C.series and C.series["resource_max"]) or {} -- for max HP

  -- NEW: base_stats are flat; no b.values
  local vals = b or {}

  -- Extract core stats safely
  local stamina = _safe(vals.stamina)
  local armor   = _safe(vals.armor)
  local defense = _safe(vals.defense)

  -- Resistances are now top-level in base_stats
  local resist_sum   = 0
  local resist_count = 0
  for _, key in ipairs({
    "resist_physical",
    "resist_holy",
    "resist_fire",
    "resist_nature",
    "resist_frost",
    "resist_shadow",
    "resist_arcane",
  }) do
    local val = _safe(vals[key])
    if val > 0 then
      resist_sum   = resist_sum + val
      resist_count = resist_count + 1
    end
  end
  local resist_avg = (resist_count > 0) and (resist_sum / resist_count) or 0

  -- Final weighted score
  return W.hp_max     * _safe(r.hp)
       + W.stamina    * stamina
       + W.armor      * armor
       + W.defense    * defense
       + W.dodge      * _safe(a.dodge)
       + W.parry      * _safe(a.parry)
       + W.block      * _safe(a.block)
       + W.resist_avg * resist_avg
end


-- ============================================================================
-- Build subplots on the panel
-- ============================================================================
local function getArea(panel)
  if NS.Graphs_GetDrawArea then return NS.Graphs_GetDrawArea(panel) end
  return (panel and panel.GraphRoot) or panel
end

-- Helper: clear any previously built rows (prevents duplicates)
local function clearBuiltGraphs(panel)
  if not panel or not panel._graphs then return end
  for _, g in ipairs(panel._graphs) do
    if g.plot then g.plot:Hide() end
    if g.title then g.title:Hide() end
  end
  panel._graphs = {}
end

-- Build only visible plots
function NS.Graphs_Init(panel)
  panel._graphs = panel._graphs or {}
  --- *** IMPORTANT: clear old rows before rebuilding ***
  clearBuiltGraphs(panel)

  local area = getArea(panel)
  local totalH = math.max(1, area:GetHeight())
  local vMargin = 24
  local curY = -8

  local ui = (WhoDAT_GetUI and WhoDAT_GetUI()) or (WhoDAT_Config and WhoDAT_Config.ui) or {}
  if _G.WhoDatDB and _G.WhoDatDB.ui then ui = _G.WhoDatDB.ui end
  local vis = (ui.graphs and ui.graphs.visible) or { money=true, xp=true, rested=true, honor=true }

  -- palettes and order including new series
  local palette = {
    money   = {1.00, 0.84, 0.00},
    xp      = {0.40, 0.80, 1.00},
    rested  = {0.60, 0.90, 0.60},
    honor   = {1.00, 0.30, 0.30},
    power   = {0.80, 0.60, 1.00}, -- violet
    defense = {0.30, 0.90, 0.70}, -- teal
  }
  local order = { "money", "xp", "rested", "honor", "power", "defense" }

  -- count visible rows to size initial layout sanely
  local rows = 0
  for _, k in ipairs(order) do if vis[k] == true then rows = rows + 1 end end
  local rowH = math.floor((totalH - vMargin) / math.max(1, rows))

  local function addPlot(label, color)
    local title = area:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", area, "TOPLEFT", 8, curY)
    title:SetText(label)

    local plotH = math.max(8, rowH - 18)
    local plot = CreateSparkline(area, 1, plotH)
    plot:ClearAllPoints()
    plot:SetPoint("TOPLEFT", area, "TOPLEFT", 8, curY - 18)
    plot:SetPoint("TOPRIGHT", area, "TOPRIGHT", -8, curY - 18)
    plot:SetHeight(plotH)
    plot:SetPalette(color[1], color[2], color[3], 0.9)

    table.insert(panel._graphs, { title = title, plot = plot })
    curY = curY - rowH
  end

  for _, key in ipairs(order) do
    if vis[key] == true then
      local label = (key == "money"   and "Gold")
                 or (key == "xp"      and "XP")
                 or (key == "rested"  and "Rested")
                 or (key == "honor"   and "Honor")
                 or (key == "power"   and "Power")
                 or (key == "defense" and "Defense")
                 or key
      addPlot(label, palette[key] or {0.6,0.6,0.6})
    end
  end

  function panel:UpdateLayout()
    local area = getArea(panel)
    local totalH = math.max(1, area:GetHeight())
    local vMargin = 24
    local rows = #panel._graphs
    local rowH = math.floor((totalH - vMargin) / math.max(1, rows))
    local curY = -8
    for _, g in ipairs(panel._graphs) do
      g.title:ClearAllPoints(); g.title:SetPoint("TOPLEFT", area, "TOPLEFT", 8, curY)
      g.plot:ClearAllPoints();  g.plot:SetPoint("TOPLEFT", area, "TOPLEFT", 8, curY - 18)
      g.plot:SetPoint("TOPRIGHT", area, "TOPRIGHT", -8, curY - 18)
      g.plot:SetHeight(math.max(8, rowH - 18))
      curY = curY - rowH
    end
  end

  panel._graphsBuilt = true
end

-- ============================================================================
-- Refresh only visible series
-- ============================================================================

-- === Breakdown helpers for tooltip details ===
_explainPower = function(C)
  local W = NS.Graphs_Weights.power
  local a = _last(C.series and C.series.attack) or {}
  local s = _last(C.series and C.series["spell_ranged"]) or {}
  local b = _last(C.series and C.series.base_stats) or {}
  local vals = (b and b.values) or {}
  local r = s.ranged or {}
  local spell = s.spell or {}
  local schools = spell.schools or {}

  local ap_total    = _safe(a.apBase) + _safe(a.apPos) - _safe(a.apNeg)
  local melee_ap    = W.ap           * ap_total
  local melee_crit  = W.crit         * _safe(a.crit)
  local mh_inv      = W.mh_speed_inv * _inv_speed(a.mhSpeed)
  local oh_inv      = W.oh_speed_inv * _inv_speed(a.ohSpeed)

  local ranged_ap   = W.r_ap         * _safe(r.ap)
  local ranged_crit = W.r_crit       * _safe(r.crit)
  local ranged_spd  = W.r_speed_inv  * _inv_speed(r.speed)

  local sp_sum, sc_sum, n = 0, 0, 0
  for _, info in pairs(schools) do
    sp_sum = sp_sum + _safe(info.dmg)
    sc_sum = sc_sum + _safe(info.crit)
    n = n + 1
  end
  local sp_avg = (n > 0) and (sp_sum / n) or 0
  local sc_avg = (n > 0) and (sc_sum / n) or 0

  local spell_power = W.spell_power * sp_avg
  local spell_crit  = W.spell_crit  * sc_avg
  local penetration = W.penetration * _safe(spell.penetration)

  local strength    = W.strength     * _safe(vals.strength)
  local agility     = W.agility      * _safe(vals.agility)

  local total = melee_ap + melee_crit + mh_inv + oh_inv
              + ranged_ap + ranged_crit + ranged_spd
              + spell_power + spell_crit + penetration
              + strength + agility

  return {
    total = total,
    melee_ap = melee_ap, melee_crit = melee_crit, mh_inv = mh_inv, oh_inv = oh_inv,
    ranged_ap = ranged_ap, ranged_crit = ranged_crit, ranged_spd = ranged_spd,
    spell_power = spell_power, spell_crit = spell_crit, penetration = penetration,
    strength = strength, agility = agility,
  }
end

_explainDefense = function(C)
  local W = NS.Graphs_Weights.defense
  local a = _last(C.series and C.series.attack) or {}
  local b = _last(C.series and C.series.base_stats) or {}
  local r = _last(C.series and C.series["resource_max"]) or {}
  local vals = (b and b.values) or {}
  local res  = (b and b.resistances) or {}

  local rs_sum, rs_n = 0, 0
  for school = 0, 6 do
    if res[school] ~= nil then rs_sum = rs_sum + _safe(res[school]); rs_n = rs_n + 1 end
  end
  local rs_avg = (rs_n > 0) and (rs_sum / rs_n) or 0

  local hp_max     = W.hp_max     * _safe(r.hp)
  local stamina    = W.stamina    * _safe(vals.stamina)
  local armor      = W.armor      * _safe(vals.armor)
  local defense    = W.defense    * _safe(vals.defense)
  local dodge      = W.dodge      * _safe(a.dodge)
  local parry      = W.parry      * _safe(a.parry)
  local block      = W.block      * _safe(a.block)
  local resist_avg = W.resist_avg * rs_avg

  local total = hp_max + stamina + armor + defense + dodge + parry + block + resist_avg

  return {
    total = total,
    hp_max = hp_max, stamina = stamina, armor = armor, defense = defense,
    dodge = dodge, parry = parry, block = block, resist_avg = resist_avg,
  }
end

-- === Timestamp-aware breakdown helpers (use hovered ts) ===
_explainPowerAt = function(C, ts)
  local W = NS.Graphs_Weights.power
  local a = _getLastOnOrBefore(C.series and C.series.attack, ts) or {}
  local s = _getLastOnOrBefore(C.series and C.series["spell_ranged"], ts) or {}
  local b = _getLastOnOrBefore(C.series and C.series.base_stats, ts) or {}
  local vals = (b and b.values) or {}
  local r = s.ranged or {}
  local spell = s.spell or {}
  local schools = spell.schools or {}

  local ap_total    = _safe(a.apBase) + _safe(a.apPos) - _safe(a.apNeg)
  local melee_ap    = W.ap           * ap_total
  local melee_crit  = W.crit         * _safe(a.crit)
  local mh_inv      = W.mh_speed_inv * _inv_speed(a.mhSpeed)
  local oh_inv      = W.oh_speed_inv * _inv_speed(a.ohSpeed)

  local ranged_ap   = W.r_ap         * _safe(r.ap)
  local ranged_crit = W.r_crit       * _safe(r.crit)
  local ranged_spd  = W.r_speed_inv  * _inv_speed(r.speed)

  local sp_sum, sc_sum, n = 0, 0, 0
  for _, info in pairs(schools) do
    sp_sum = sp_sum + _safe(info.dmg)
    sc_sum = sc_sum + _safe(info.crit)
    n = n + 1
  end
  local sp_avg = (n > 0) and (sp_sum / n) or 0
  local sc_avg = (n > 0) and (sc_sum / n) or 0

  local spell_power = W.spell_power * sp_avg
  local spell_crit  = W.spell_crit  * sc_avg
  local penetration = W.penetration * _safe(spell.penetration)

  local strength    = W.strength     * _safe(vals.strength)
  local agility     = W.agility      * _safe(vals.agility)

  local total = melee_ap + melee_crit + mh_inv + oh_inv
              + ranged_ap + ranged_crit + ranged_spd
              + spell_power + spell_crit + penetration
              + strength + agility

  return {
    total = total,
    melee_ap = melee_ap, melee_crit = melee_crit, mh_inv = mh_inv, oh_inv = oh_inv,
    ranged_ap = ranged_ap, ranged_crit = ranged_crit, ranged_spd = ranged_spd,
    spell_power = spell_power, spell_crit = spell_crit, penetration = penetration,
    strength = strength, agility = agility,
  }
end

_explainDefenseAt = function(C, ts)
  local W = NS.Graphs_Weights.defense
  local a = _getLastOnOrBefore(C.series and C.series.attack, ts) or {}
  local b = _getLastOnOrBefore(C.series and C.series.base_stats, ts) or {}
  local r = _getLastOnOrBefore(C.series and C.series["resource_max"], ts) or {}
  local vals = (b and b.values) or {}
  local res  = (b and b.resistances) or {}

  local rs_sum, rs_n = 0, 0
  for school = 0, 6 do
    if res[school] ~= nil then rs_sum = rs_sum + _safe(res[school]); rs_n = rs_n + 1 end
  end
  local rs_avg = (rs_n > 0) and (rs_sum / rs_n) or 0

  local hp_max     = W.hp_max     * _safe(r.hp)
  local stamina    = W.stamina    * _safe(vals.stamina)
  local armor      = W.armor      * _safe(vals.armor)
  local defense    = W.defense    * _safe(vals.defense)
  local dodge      = W.dodge      * _safe(a.dodge)
  local parry      = W.parry      * _safe(a.parry)
  local block      = W.block      * _safe(a.block)
  local resist_avg = W.resist_avg * rs_avg

  local total = hp_max + stamina + armor + defense + dodge + parry + block + resist_avg

  return {
    total = total,
    hp_max = hp_max, stamina = stamina, armor = armor, defense = defense,
    dodge = dodge, parry = parry, block = block, resist_avg = resist_avg,
  }
end


function NS.Graphs_Refresh(panel)
  -- Ensure the graphs are built once
  if not panel._graphsBuilt then NS.Graphs_Init(panel) end

  -- Resolve current character bucket (may be nil on first run)
  local _, C = getChar()
  if not C then
    for _, g in ipairs(panel._graphs or {}) do
      g.plot:Hide()
      g.title:SetText(stripNoData(g.title:GetText()) .. " (no data)")
    end
    return
  end

  -- Clean any "(no data)" suffix from titles
  for _, g in ipairs(panel._graphs or {}) do
    g.title:SetText(stripNoData(g.title:GetText()))
  end

  -- Resolve UI graph config, merged with defaults
  local ui = (WhoDAT_GetUI and WhoDAT_GetUI()) or (WhoDAT_Config and WhoDAT_Config.ui)
  if _G.WhoDatDB and _G.WhoDatDB.ui then ui = _G.WhoDatDB.ui end
  local gcfg = ui and ui.graphs or NS.Graphs_DefaultConfig
  for k, v in pairs(NS.Graphs_DefaultConfig) do
    if gcfg[k] == nil then gcfg[k] = v end
  end

  -- Visibility map (fallback defaults)
  local vis = (ui and ui.graphs and ui.graphs.visible) or { money = true, xp = true, rested = true, honor = true }

  -- Ensure SavedVariables container for series exists
  C.series = C.series or {}
  local series = C.series

  -- --------------------------------------------------------------------------
  -- Local helpers (self-contained) for session-window scoping
  -- --------------------------------------------------------------------------
  local function _sortedLastSessions(db, n)
    -- Accepts top-level WhoDatDB.sessions (global) or per-character sessions.
    -- Returns ascending-sorted array of {start_ts, end_ts} and slices to last n.
    if not db then return {} end

    local key = (U.GetPlayerKey and U.GetPlayerKey())
                or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
    local charBucket = db.characters and db.characters[key]
    local sessions = (charBucket and charBucket.sessions) or db.sessions or {}

    local buf = {}
    for _, s in pairs(sessions) do
      local start_ts = tonumber(s.start_ts or s.ts or 0) or 0
      local end_ts   = tonumber(s.end_ts   or s.te or start_ts) or start_ts
      if start_ts > 0 then
        buf[#buf + 1] = { start_ts = start_ts, end_ts = math.max(end_ts, start_ts) }
      end
    end

    table.sort(buf, function(a, b) return (a.start_ts or 0) < (b.start_ts or 0) end)

    if type(n) ~= "number" or n <= 0 then return buf end
    local take = math.min(n, #buf)
    local out = {}
    for i = (#buf - take + 1), #buf do
      if i >= 1 then out[#out + 1] = buf[i] end
    end
    return out
  end

  local function _filterPointsBySessions(points, sessions)
    if not points or #points == 0 then return {} end
    if not sessions or #sessions == 0 then return points end -- fallback: no scoping if no sessions
    local out = {}
    for i = 1, #points do
      local p  = points[i]
      local ts = p and tonumber(p.ts or 0) or 0
      if ts > 0 then
        for _, s in ipairs(sessions) do
          if ts >= (s.start_ts or 0) and ts <= (s.end_ts or ts) then
            out[#out + 1] = p
            break
          end
        end
      end
    end
    return out
  end

  -- --------------------------------------------------------------------------
  -- Per-series refresh (with session scoping)
  -- --------------------------------------------------------------------------
  local order = { "money", "xp", "rested", "honor", "power", "defense" }
  local idx = 0
  panel._seriesLastVal = panel._seriesLastVal or {}

  for _, key in ipairs(order) do
    if vis[key] then
      idx = idx + 1
      local g = panel._graphs[idx]
      if g then
        -----------------------------------------------------------------------
        -- Synthesize/append snapshots for "power" & "defense" before plotting
        -----------------------------------------------------------------------
        local arr
        if key == "power" or key == "defense" then
          series[key] = series[key] or {}
          local container = series[key]

          local curVal = (key == "power") and _computePowerSnapshot(C) or _computeDefenseSnapshot(C)
          local lastPoint = (#container > 0) and container[#container] or nil
          local lastVal = lastPoint and tonumber(lastPoint.value) or nil
          local epsilon = 0.001
          if (lastVal == nil) or (math.abs(curVal - lastVal) > epsilon) then
            table.insert(container, { ts = now(), value = curVal })
            local limit = (gcfg.max_points_per_series or 1000)
            if #container > limit then table.remove(container, 1) end
          end
          arr = container
        else
          -- Normal series
          arr = series[key] or {}
        end

        -----------------------------------------------------------------------
        -- NEW: Scope points to the last N sessions (N = gcfg.session_window)
        -----------------------------------------------------------------------
        local sessionWindow = (gcfg and gcfg.session_window) or nil
        if type(sessionWindow) == "number" and sessionWindow > 0 then
          local lastSessions = _sortedLastSessions(_G.WhoDatDB, sessionWindow)
          arr = _filterPointsBySessions(arr, lastSessions)
        end

        -----------------------------------------------------------------------
        -- Money compression, omit-zero filtering, smoothing decisions
        -----------------------------------------------------------------------
        if key == "money" and (gcfg.money_on_change_only ~= false) then
          arr = compressRuns(arr)
        end

        local omitGlobal = (gcfg.omit_zero_points == true)
        local perKey     = (gcfg.omit_zero_points_by_key and gcfg.omit_zero_points_by_key[key])
        local omitZeros  = (perKey ~= nil) and perKey or omitGlobal
        if omitZeros then arr = filterNonZero(arr) end

        -----------------------------------------------------------------------
        -- Plotting: empty series watermark vs. normal series with tooltips
        -----------------------------------------------------------------------
        local emptySeries = (#arr == 0)
        local baseLabel   = stripNoData(g.title:GetText())

        if emptySeries then
          g.plot:Show()
          if (gcfg.empty_title_suffix_enable ~= false) then
            g.title:SetText(baseLabel .. " (no non-zero data)")
          else
            g.title:SetText(baseLabel)
          end
          g.plot:SetSeries({}, {
            max_points       = gcfg.max_points_per_series or 1000,
            max_ui_columns   = gcfg.max_ui_columns or 256,
            enable_smoothing = (gcfg.enable_smoothing ~= false),
            tooltip_enable   = false,
            meta = { key = key, label = baseLabel },
          })
          g.plot:Render()
        else
          local last = lastValue(arr)
          local prev = panel._seriesLastVal[key]

          -- Disable smoothing for synthetic series or step-style money if desired
          local enableSmooth = (gcfg.enable_smoothing ~= false)
          if key == "power" or key == "defense" then
            enableSmooth = false
          elseif key == "money" and gcfg.money_step_style == true then
            enableSmooth = false
          end

          g.plot:SetSeries(arr, {
            max_points       = gcfg.max_points_per_series or 1000,
            max_ui_columns   = gcfg.max_ui_columns or 256,
            enable_smoothing = enableSmooth,
            gradient_enable  = (gcfg.gradient_enable ~= false),
            gradient_top_px  = gcfg.gradient_top_px or 2,
            gradient_bottom_px = gcfg.gradient_bottom_px or 3,
            tooltip_enable   = (gcfg.tooltip_enable ~= false),
            meta = { key = key, label = baseLabel },
          })
          g.plot:Show()

-- Always render if data exists (removed conditional check that caused stale graphs)
          g.plot:Render()
          panel._seriesLastVal[key] = last
        end
      end
    end
  end
end

-- ============================================================================
-- Force refresh (bypasses cache for immediate update)
-- ============================================================================
function NS.Graphs_ForceRefresh(panel)
  if not panel then return end
  
  -- Clear the lastValue cache to ensure full re-render
  panel._seriesLastVal = {}
  
  -- Trigger immediate refresh
  if panel:IsVisible() and NS.Graphs_Refresh then
    NS.Graphs_Refresh(panel)
  end
end

-- ============================================================================
-- Optional periodic refresh hook (throttled)
-- ============================================================================
function NS.Graphs_OnUpdate(panel, elapsed)
  panel._accum = (panel._accum or 0) + (elapsed or 0)
  if panel._accum > 0.1 then  -- Changed from 0.5 to 0.1 for faster updates
    if panel:IsVisible() then NS.Graphs_Refresh(panel) end
    panel._accum = 0
  end
end

-- ============================================================================
-- OPTIONAL: Series pruning helpers to bound saved history (reduces DB memory)
-- ============================================================================
function NS.Graphs_PruneSeries(db, caps)
  if not db or not db.characters then return end
  for _, C in pairs(db.characters) do
    if C.series then
      for k, arr in pairs(C.series) do
        local cap = caps and caps[k] or nil
        if type(arr) == "table" and type(cap) == "number" and cap > 0 then
          local n = #arr
          if n > cap then
            local start = n - cap + 1
            local pruned = {}
            for i = start, n do pruned[#pruned+1] = arr[i] end
            C.series[k] = pruned
          end
        end
      end
    end
  end
end

-- ============================================================================
-- Helper: Toggle graph visibility and rebuild + reflow immediately
-- ============================================================================
function NS.Graphs_SetVisibility(panel, key, visible)
  local ui = (WhoDAT_GetUI and WhoDAT_GetUI()) or (WhoDAT_Config and WhoDAT_Config.ui) or {}
  if _G.WhoDatDB and _G.WhoDatDB.ui then ui = _G.WhoDatDB.ui end
  ui.graphs = ui.graphs or {}
  ui.graphs.visible = ui.graphs.visible or { money=true, xp=true, rested=true, honor=true }
  ui.graphs.visible[key] = visible and true or false

  if panel then
    NS.Graphs_Init(panel) -- now safe: clears old rows first
    if panel.UpdateLayout then panel:UpdateLayout() end
    if NS.Graphs_Refresh then NS.Graphs_Refresh(panel) end
  end
end