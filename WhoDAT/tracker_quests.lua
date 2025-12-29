-- WhoDAT - tracker_quests.lua
-- Quests, reputation, skills, tradeskills, spellbook + glyphs, companions/pets
-- Wrath-safe; null checks for Warmane and defensive gating

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS
local U = NS.Utils or {}

--------------------------------------------------------------------------------
-- Helpers & DB guards
--------------------------------------------------------------------------------

-- === Simple diff + safe logger ===
local function _logEvent(category, action, payload)
  -- Prefer global WhoDAT_LogEvent if present; otherwise fall back to NS.Log
  if type(WhoDAT_LogEvent) == "function" then
    WhoDAT_LogEvent(category, action, payload)
  elseif NS.Log then
    NS.Log("EVENT", "%s:%s %s",
      tostring(category),
      tostring(action),
      tostring(
        (payload and payload.spell) or
        (payload and payload.glyph) or
        (payload and payload.skill) or
        (payload and payload.talent) or
        ""
      )
    )
  end
end

-- Build name->item map from { {name=..., ...}, ... } array
local function _indexByName(arr)
  local m = {}
  if type(arr) == "table" then
    for _, v in ipairs(arr) do
      if type(v) == "table" and v.name then m[v.name] = v end
    end
  end
  return m
end

-- Generic set diff: returns added[], removed[], common[name] = {old=..., new=...}
local function _setDiff(oldArr, newArr)
  local oldM, newM = _indexByName(oldArr), _indexByName(newArr)
  local added, removed, common = {}, {}, {}

  -- added
  for name, v in pairs(newM) do
    if not oldM[name] then
      table.insert(added, v)
    else
      common[name] = { old = oldM[name], new = v }
    end
  end

  -- removed
  for name, v in pairs(oldM) do
    if not newM[name] then
      table.insert(removed, v)
    end
  end

  return added, removed, common
end

-- Extract numeric progress ("3/10") from objective text; returns cur,total or nil
local function _parseProgress(text)
  if type(text) ~= "string" then return nil end
  -- Common WotLK pattern: "Collect Foo: 3/10" or "3/10 Foo slain"
  local cur, total = text:match("(%d+)%s*/%s*(%d+)")
  if cur and total then
    return tonumber(cur), tonumber(total)
  end
  return nil
end

-- Persist "previous snapshot" store per character safely
local function _ensurePrevStore(char)
  char.prev = char.prev or {}
  char.prev.snapshots = char.prev.snapshots or {}
  char.prev.series = char.prev.series or {}  -- in case you want series diffs later
  return char.prev
end

local function now() return time() end

local function EnsureCharacterBranches()
  -- Derive player key via Utils if present; otherwise fallback to name@realm
  local key
  if U and type(U.GetPlayerKey) == "function" then
    key = U.GetPlayerKey()
  else
    local name = (type(UnitName)=="function" and UnitName("player")) or "Player"
    local realm = (type(GetRealmName)=="function" and GetRealmName()) or "Realm"
    key = string.format("%s@%s", name or "Player", realm or "Realm")
  end

  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or { events = {}, series = {}, snapshots = {} }

  local c = WhoDatDB.characters[key]
  c.events  = c.events  or {}
  c.series  = c.series  or {}
  c.snapshots = c.snapshots or {}
  return key, c
end

local function push(t, v) t[#t+1] = v end

-- Track quests seen as completed in this session, to disambiguate removal vs abandonment
local _recentlyCompleted = {} -- [questID or title] = ts
local function markCompleted(id, title) 
  if id then _recentlyCompleted[tostring(id)] = now() end
  if title then _recentlyCompleted[title] = now() end
end
local function wasRecentlyCompleted(id, title, withinSeconds)
  local t1 = id and _recentlyCompleted[tostring(id)]
  local t2 = title and _recentlyCompleted[title]
  local t = t1 or t2
  return t and (now() - t) <= (withinSeconds or 10)
end

-- Simple throttle map so repeated events don't spam scans
local _lastRun = {}
local function throttled(tag, seconds)
  local t = _lastRun[tag] or 0
  local nowTs = now()
  if nowTs - t >= seconds then
    _lastRun[tag] = nowTs
    return true
  end
  return false
end

-- Safe pcall wrapper
local function safe(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok and DEFAULT_CHAT_FRAME then
    DEFAULT_CHAT_FRAME:AddMessage("|cffff7f7f[WhoDAT]|r tracker_quests error: " .. tostring(err))
  end
  return ok
end

-- ============================================================================
-- Quest Reward Tracking State
-- ============================================================================
local questRewardPending = nil

-- ============================================================================
-- Quest Reward Capture (QUEST_COMPLETE)
-- ============================================================================
local function OnQuestCompleteDialog()
  local questTitle = GetTitleText()
  local numChoices = GetNumQuestChoices()
  local numRewards = GetNumQuestRewards()
  
  -- Try to find quest ID from quest log
  local questID = nil
  local questLevel = nil
  local numEntries = GetNumQuestLogEntries()
  for i = 1, numEntries do
    local title, level, _, isHeader, _, isComplete, qID = GetQuestLogTitle(i)
    if title == questTitle and not isHeader and qID then
      questID = qID
      questLevel = level
      break
    end
  end
  
  -- Build reward_choices array
  local rewardChoices = {}
  for i = 1, numChoices do
    local name, texture, numItems, quality, isUsable = GetQuestItemInfo("choice", i)
    local link = GetQuestItemLink("choice", i)
    if name then
      table.insert(rewardChoices, {
        name = name,
        link = link,
        quantity = numItems or 1,
        quality = quality or 0,
        texture = texture,
      })
    end
  end
  
  -- Build reward_required array (always given, not a choice)
  local rewardRequired = {}
  for i = 1, numRewards do
    local name, texture, numItems, quality, isUsable = GetQuestItemInfo("reward", i)
    local link = GetQuestItemLink("reward", i)
    if name then
      table.insert(rewardRequired, {
        name = name,
        link = link,
        quantity = numItems or 1,
        quality = quality or 0,
        texture = texture,
      })
    end
  end
  
  questRewardPending = {
    quest_id = questID,
    quest_title = questTitle,
    quest_level = questLevel,
    money = GetRewardMoney(),
    xp = GetRewardXP(),
    honor = (type(GetRewardHonor) == "function") and GetRewardHonor() or 0,
    arena = (type(GetRewardArenaPoints) == "function") and GetRewardArenaPoints() or 0,
    reward_choices = rewardChoices,
    reward_required = rewardRequired,
    ts = time(),
  }
end

-- ============================================================================
-- Quest Turn-In Handler (QUEST_FINISHED)
-- ============================================================================
local function OnQuestTurnedIn()
  if not questRewardPending then return end
  
  -- Add zone context
  questRewardPending.zone = GetRealZoneText() or GetZoneText()
  questRewardPending.subzone = GetSubZoneText()
  
  -- Save to database
  local key, char = EnsureCharacterBranches()
  char.events = char.events or {}
  char.events.quest_rewards = char.events.quest_rewards or {}
  
  table.insert(char.events.quest_rewards, questRewardPending)
  
  if NS.Log then
    NS.Log("INFO", "Quest reward tracked: %s (money: %dg, xp: %d)",
      questRewardPending.quest_title or "Unknown",
      math.floor((questRewardPending.money or 0) / 10000),
      questRewardPending.xp or 0)
  end
  
  questRewardPending = nil
end

--------------------------------------------------------------------------------
-- Public: Scan orchestrator
--------------------------------------------------------------------------------
function NS.Quests_ScanAll()
  if throttled("Quests_ScanAll", 3) then -- avoid running too frequently
    safe(NS.Quests_ScanLog)
    safe(NS.Quests_ScanReputation)
    safe(NS.Quests_ScanSkills)
    safe(NS.Quests_ScanSpellbook)
    safe(NS.Quests_ScanGlyphs)
    safe(NS.Quests_ScanCompanions)
    safe(NS.Quests_ScanPetStable)
    safe(NS.Quests_ScanPetInfo)
    safe(NS.Quests_ScanPetSpellbook)
    safe(NS.Quests_ScanTradeSkills)
  end
end

--------------------------------------------------------------------------------
-- Quests log (append-only event entries)
--------------------------------------------------------------------------------
function NS.Quests_ScanLog()
  if not throttled("Quests_ScanLog", 1) then return end

  local key, char = EnsureCharacterBranches()
  char.events.quests = char.events.quests or {}
  local prev = _ensurePrevStore(char)

  -- Build current compact quest snapshot for diffing
  local current = {} -- array of { id, title, complete, objectives = { {text, cur, total, complete}, ... } }
  local indexById = {} -- map for quick lookup by id

  local num = (type(GetNumQuestLogEntries)=="function" and GetNumQuestLogEntries()) or 0
  for i = 1, num do
    local title, level, _, isHeader, _, isComplete, questID = GetQuestLogTitle(i)
    if title then  -- Server may not return questID
      SelectQuestLogEntry(i)
      -- Objectives (with parsed numeric progress if available)
      local objectives = {}
      local ocount = (type(GetNumQuestLeaderBoards)=="function" and GetNumQuestLeaderBoards(i)) or 0
      
      -- Skip real headers (marked as header AND have no objectives)
      local isRealHeader = isHeader and (ocount == 0)
      
      if not isRealHeader then
        for oi = 1, ocount do
          local otext, objType, finished = GetQuestLogLeaderBoard(oi, i)
          local cur, total = _parseProgress(otext)
          push(objectives, { text = otext, type = objType, complete = finished and true or false, cur = cur, total = total })
        end

        -- Use questID if available, otherwise use quest log index
        local questId = questID or i
        
        -- Record normalized row
        local row = {
          id = questId, 
          title = title, 
          complete = isComplete and true or false, 
          objectives = objectives,
        }
        push(current, row)
        indexById[questId] = row

        -- (Optional) keep your rich append-only detail as-is
        -- ... your existing push(char.events.quests, {...}) block remains unchanged ...
      end
    end
  end

  -- Previous snapshot (compact) for diffing
  prev.snapshots = prev.snapshots or {}
  local old = prev.snapshots.quest_log or {}

  -- === Diff: added/removed/common (by quest id preferred) ===
  local function _asNameArray(arr)
    local out = {}
    for _, q in ipairs(arr or {}) do
      -- Normalize 'name' field for _setDiff to compare: prefer unique id as string
      table.insert(out, { name = tostring(q.title or q.id), _q = q })
    end
    return out
  end

  local added, removed, common = _setDiff(_asNameArray(old), _asNameArray(current))

  -- === Emit ACCEPTED for newly added quests ===
  for _, v in ipairs(added) do
    local q = v._q
    _logEvent("quests", "accepted", { id = q.id, title = q.title })
  end

  -- === Emit COMPLETED for status change old.complete=false -> new.complete=true ===
  for _, pair in pairs(common) do
    local oldQ = pair.old._q
    local newQ = pair.new._q
    if (not oldQ.complete) and newQ.complete then
      _logEvent("quests", "completed", { id = newQ.id, title = newQ.title })
      markCompleted(newQ.id, newQ.title)
    end
  end

  -- === Emit ABANDONED for removed quests that were not just completed ===
  for _, v in ipairs(removed) do
    local oldQ = v._q
    local id = oldQ.id
    if not wasRecentlyCompleted(id, oldQ.title, 30) then
      _logEvent("quests", "abandoned", { id = id, title = oldQ.title })
    end
  end

  -- === Objective progress events (diff each objective entry by text) ===
  -- Build lookup table for previous objectives by quest id+objective text
  local prevObj = {} -- key "id\ntext" -> {cur,total,complete}
  for _, oq in ipairs(old or {}) do
    local q = oq._q
    if q and q.objectives then
      for _, o in ipairs(q.objectives) do
        prevObj[(tostring(q.title) .. "\n" .. tostring(o.text))] = { cur = o.cur, total = o.total, complete = o.complete }
      end
    end
  end

  for _, cq in ipairs(current or {}) do
    if cq.objectives then
      for _, o in ipairs(cq.objectives) do
        local keyObj = (tostring(cq.title) .. "\n" .. tostring(o.text))
        local prevO = prevObj[keyObj]
        -- Emit only when we see numeric progress change or completion flips
        local curChanged = prevO and o.cur and prevO.cur ~= o.cur
        local completionFlipped = (prevO and prevO.complete ~= o.complete) or (not prevO and o.complete)
        local totalKnown = o.total
        if curChanged or completionFlipped then
          _logEvent("quests", "objective", {
            id = cq.id,
            title = cq.title,
            objective = o.text,
            progress = o.cur,     -- may be nil if the line didn't include numbers
            total    = totalKnown, -- may be nil
            complete = o.complete,
          })
        end
      end
    end
  end

  -- === Persist current snapshot for export AND next diff ===
  char.snapshots = char.snapshots or {}
  char.snapshots.quest_log = { ts = now(), quests = current }
  prev.snapshots.quest_log = current
end

--------------------------------------------------------------------------------
-- Reputation (series snapshot per faction)
--------------------------------------------------------------------------------
function NS.Quests_ScanReputation()
  local key, char = EnsureCharacterBranches()
  char.series.reputation = char.series.reputation or {}

  local num = (type(GetNumFactions)=="function" and GetNumFactions()) or 0
  for i = 1, num do
    local name, _, standingId, barMin, barMax, barValue, _, _, isHeader = GetFactionInfo(i)
    if name and not isHeader then
      push(char.series.reputation, {
        ts = now(), name = name, standing_id = standingId,
        value = barValue, min = barMin, max = barMax
      })
    end
  end
end

--------------------------------------------------------------------------------
-- Skills (snapshot of ranks) + tradeskill learned/changed events
--------------------------------------------------------------------------------
function NS.Quests_ScanSkills()
  local key, char = EnsureCharacterBranches()
  char.series.skills = {}

  local num = (type(GetNumSkillLines)=="function" and GetNumSkillLines()) or 0
  for i = 1, num do
    local name, isHeader, _, rank, _, maxRank = GetSkillLineInfo(i)
    if not isHeader and name then
      table.insert(char.series.skills, { name = name, rank = rank or 0, max = maxRank or 0 })
    end
  end

  -- === DIFF for professions ===
  local prev = _ensurePrevStore(char)
  local oldSkills = (prev.snapshots and prev.snapshots.skills) or {}
  local newSkills = char.series.skills

  -- Consider only profession-like lines.
  local PROF = {
    ["Alchemy"]=true, ["Blacksmithing"]=true, ["Enchanting"]=true, ["Engineering"]=true,
    ["Herbalism"]=true, ["Inscription"]=true, ["Jewelcrafting"]=true, ["Leatherworking"]=true,
    ["Mining"]=true, ["Skinning"]=true, ["Tailoring"]=true, ["Cooking"]=true, ["First Aid"]=true,
    ["Fishing"]=true, ["Riding"]=true,
  }

  local function _filterProf(arr)
    local out = {}
    for _, v in ipairs(arr or {}) do if PROF[v.name] then table.insert(out, v) end end
    return out
  end

  local added, removed, common = _setDiff(_filterProf(oldSkills), _filterProf(newSkills))

  for _, s in ipairs(added) do
    _logEvent("tradeskill", "learned", { skill = s.name, rank = s.rank })
  end

  -- Rank changes
  for name, pair in pairs(common) do
    local oldR = pair.old.rank or 0
    local newR = pair.new.rank or 0
    if newR ~= oldR then
      _logEvent("tradeskill", "changed", { skill = name, rank = newR, from = oldR, max = pair.new.max or pair.old.max })
    end
  end

  -- Persist snapshot for future diffs (kept in prev.snapshots to avoid bloating char.series)
  prev.snapshots.skills = newSkills
end

--------------------------------------------------------------------------------
-- Spellbook (snapshot + learned/unlearned + rank_changed)
--------------------------------------------------------------------------------
function NS.Quests_ScanSpellbook()
  local tabs = {}
  local numTabs = (type(GetNumSpellTabs)=="function" and GetNumSpellTabs()) or 0
  for t = 1, numTabs do
    local name, _, offset, numSpells = GetSpellTabInfo(t)
    local tab = { name = name, spells = {} }
    local count = numSpells or 0
    for i = 1, count do
      local spellName, spellRank = GetSpellName(offset + i, BOOKTYPE_SPELL)
      if spellName then table.insert(tab.spells, { name = spellName, rank = spellRank }) end
    end
    table.insert(tabs, tab)
  end

  local key, char = EnsureCharacterBranches()
  local prev = _ensurePrevStore(char)

  -- DIFF: flatten all spells across tabs by name to avoid double-counting
  local newAll = {}
  for _, tab in ipairs(tabs) do
    for _, s in ipairs(tab.spells or {}) do newAll[#newAll+1] = s end
  end

  local oldAll = {}
  do
    local oldSnap = char.snapshots and char.snapshots.spellbook or nil
    if oldSnap and type(oldSnap.tabs) == "table" then
      for _, tab in ipairs(oldSnap.tabs) do
        for _, s in ipairs(tab.spells or {}) do oldAll[#oldAll+1] = s end
      end
    end
  end

  local added, removed, common = _setDiff(oldAll, newAll)

  for _, s in ipairs(added)   do _logEvent("spellbook", "learned",   { spell = s.name, rank = s.rank }) end
  for _, s in ipairs(removed) do _logEvent("spellbook", "unlearned", { spell = s.name, rank = s.rank }) end

  -- Optional: rank changes
  for name, pair in pairs(common) do
    local oldR = pair.old.rank or ""
    local newR = pair.new.rank or ""
    if oldR ~= newR then
      _logEvent("spellbook", "rank_changed", { spell = name, from = oldR, to = newR })
    end
  end

  -- Save current snapshot
  char.snapshots.spellbook = { ts = now(), tabs = tabs }
  prev.snapshots.spellbook = char.snapshots.spellbook
end

--------------------------------------------------------------------------------
-- Glyphs (snapshot + added/removed/changed)
--------------------------------------------------------------------------------
function NS.Quests_ScanGlyphs()
  local glyphs = {}
  local numSockets = (type(GetNumGlyphSockets)=="function" and GetNumGlyphSockets()) or 0
  for i = 1, numSockets do
    local enabled, gtype, spellID = GetGlyphSocketInfo(i)
    if enabled and spellID then
      local name, _, icon = GetSpellInfo(spellID)
      table.insert(glyphs, { name = name, type = gtype, icon = icon, spell_id = spellID, socket = i })
    end
  end

  local key, char = EnsureCharacterBranches()
  local prev = _ensurePrevStore(char)

  local oldGlyphs = (char.snapshots and char.snapshots.glyphs and char.snapshots.glyphs.glyphs) or {}
  local added, removed, common = _setDiff(oldGlyphs, glyphs)

  for _, g in ipairs(added)   do _logEvent("glyph", "added",   { glyph = g.name, type = g.type, socket = g.socket }) end
  for _, g in ipairs(removed) do _logEvent("glyph", "removed", { glyph = g.name, type = g.type, socket = g.socket }) end

  for name, pair in pairs(common) do
    -- socket/type changes count as "changed"
    if (pair.old.type ~= pair.new.type) or (pair.old.socket ~= pair.new.socket) then
      _logEvent("glyph", "changed", { glyph = name, from = {type=pair.old.type, socket=pair.old.socket}, to = {type=pair.new.type, socket=pair.new.socket} })
    end
  end

  char.snapshots.glyphs = { ts = now(), glyphs = glyphs }
  prev.snapshots.glyphs = char.snapshots.glyphs
end

--------------------------------------------------------------------------------
-- Companions (mounts + critters snapshot)
--------------------------------------------------------------------------------
function NS.Quests_ScanCompanions()
  local mounts, critters = {}, {}

  local function scanType(t, store)
    local n = (type(GetNumCompanions)=="function" and GetNumCompanions(t)) or 0
    for i = 1, n do
      local creatureID, creatureName, spellID, icon, isActive = GetCompanionInfo(t, i)
      push(store, { name = creatureName, icon = icon, creature_id = creatureID, spell_id = spellID, active = isActive, type = t })
    end
  end

  scanType("MOUNT", mounts)
  scanType("CRITTER", critters)

  local key, char = EnsureCharacterBranches()
  char.snapshots.companions = { ts = now(), mount = mounts, critter = critters }
end

--------------------------------------------------------------------------------
-- Stable snapshot
--------------------------------------------------------------------------------
function NS.Quests_ScanPetStable()
  local num = (type(GetNumStableSlots)=="function" and GetNumStableSlots()) or 0
  local stable = {}
  for i = 1, num do
    local hasPet, level, name, icon, family = GetStablePetInfo(i)
    if hasPet then push(stable, { name = name, level = level, icon = icon, family = family, slot = i }) end
  end

  local key, char = EnsureCharacterBranches()
  char.snapshots.pet_stable = { ts = now(), pets = stable }
end

--------------------------------------------------------------------------------
-- Pet info snapshot
--------------------------------------------------------------------------------
function NS.Quests_ScanPetInfo()
  if type(HasPetUI) ~= "function" or not HasPetUI() then return end
  local name   = UnitName("pet")
  local family = UnitCreatureFamily("pet")
  local curXP, nextXP = GetPetExperience()

  local key, char = EnsureCharacterBranches()
  char.snapshots.pet = { ts = now(), name = name, family = family, xp = curXP, next = nextXP }
end

--------------------------------------------------------------------------------
-- Pet spellbook snapshot
--------------------------------------------------------------------------------
function NS.Quests_ScanPetSpellbook()
  if type(HasPetSpells) ~= "function" or not HasPetSpells() then return end
  local spells = {}
  for i = 1, 200 do
    local name = GetSpellName(i, BOOKTYPE_PET)
    if not name then break end
    push(spells, { name = name })
  end

  local key, char = EnsureCharacterBranches()
  char.snapshots.pet_spells = { ts = now(), spells = spells }
end

--------------------------------------------------------------------------------
-- Trade skills (snapshot) + recipe learned events
--------------------------------------------------------------------------------
function NS.Quests_ScanTradeSkills()
  -- Warmane/private cores: full data typically requires the TradeSkill UI open; handle partial gracefully
  local count = (type(GetNumTradeSkills) == "function" and GetNumTradeSkills()) or 0
  local key, char = EnsureCharacterBranches()

  -- If the TradeSkill UI is open, we can also capture the profession header (optional context for events)
  local profName, profRank, profMaxRank = nil, nil, nil
  if type(GetTradeSkillLine) == "function" then
    -- WotLK signature: name, currentRank, maxRank
    profName, profRank, profMaxRank = GetTradeSkillLine()
  end

  -- Build the current snapshot
  char.snapshots.tradeskills = {}
  for i = 1, count do
    local skillName, skillType = GetTradeSkillInfo(i)
    local link  = (type(GetTradeSkillItemLink) == "function" and GetTradeSkillItemLink(i)) or nil
    local icon  = (type(GetTradeSkillIcon) == "function" and GetTradeSkillIcon(i)) or nil

    local numMadeMin, numMadeMax = nil, nil
    if type(GetTradeSkillNumMade) == "function" then
      numMadeMin, numMadeMax = GetTradeSkillNumMade(i)
    end

    local reagents = {}
    local nReagents = (type(GetTradeSkillNumReagents) == "function" and GetTradeSkillNumReagents(i)) or 0
    for r = 1, nReagents do
      local rName, rTexture, rCount, rHave = GetTradeSkillReagentInfo(i, r)
      local rLink = (type(GetTradeSkillReagentItemLink) == "function" and GetTradeSkillReagentItemLink(i, r)) or nil
      push(reagents, { name = rName, count = rCount or 0, have = rHave or 0, icon = rTexture, link = rLink })
    end

    local cooldown = (type(GetTradeSkillCooldown) == "function" and GetTradeSkillCooldown(i)) or 0
    local cooldownText = (type(SecondsToTime) == "function" and cooldown > 0 and SecondsToTime(cooldown)) or nil

    -- Each entry corresponds to a recipe row
push(char.snapshots.tradeskills, {
      profession = profName,  -- NEW: add profession context
      name = skillName, type = skillType, link = link, icon = icon,
      num_made_min = numMadeMin, num_made_max = numMadeMax,
      reagents = reagents, cooldown = cooldown, cooldown_text = cooldownText
    })
  end

  -- Emit events for newly learned recipes by diffing previous vs current snapshot
  do
    local prev = _ensurePrevStore(char) -- persistent "previous" store for diffing
    prev.snapshots = prev.snapshots or {}

    local oldRows = prev.snapshots.tradeskills or {} -- previous recipe rows
    local newRows = char.snapshots.tradeskills or {} -- current recipe rows (just built)

    -- _setDiff compares by 'name' field; name+link typically sufficient in WotLK
    local added, removed = _setDiff(oldRows, newRows)

    -- Emit "recipe learned" events for each newly added recipe
    for _, row in ipairs(added) do
      _logEvent("tradeskill", "recipe_learned", {
        recipe = row.name,
        link = row.link,
        icon = row.icon,
        profession      = profName,
        profession_rank = profRank,
        profession_max  = profMaxRank,
      })
    end

    -- If you want "recipe_unlearned" (rare), emit events for `removed` here.
    -- for _, row in ipairs(removed) do
    --   _logEvent("tradeskill", "recipe_unlearned", { recipe = row.name, link = row.link, profession = profName })
    -- end

    -- Update the previous snapshot to the current one for future diffs
    prev.snapshots.tradeskills = newRows
  end

  -- Stamp
  char.snapshots.tradeskills_ts = now()
end

--------------------------------------------------------------------------------
-- Optional: event registration for modules that prefer self-wiring
-- Safe to call multiple times.
--------------------------------------------------------------------------------
function NS.Quests_RegisterEvents()
  if NS._questsFrame then return end
  local f = CreateFrame("Frame")
  NS._questsFrame = f

  f:SetScript("OnEvent", function(self, event)
    if event == "UPDATE_FACTION" then
      safe(NS.Quests_ScanReputation)

    elseif event == "GLYPH_ADDED" or event == "GLYPH_REMOVED" or event == "GLYPH_UPDATED" then
      safe(NS.Quests_ScanGlyphs)

    elseif event == "COMPANION_UPDATE" or event == "COMPANION_LEARNED" then
      safe(NS.Quests_ScanCompanions)

    elseif event == "QUEST_LOG_UPDATE" then
      safe(NS.Quests_ScanLog)

    -- Fast-path emit on QUEST_COMPLETE
    -- QUEST_COMPLETE fires after turning in; the quest may soon disappear from the log.
    elseif event == "QUEST_COMPLETE" then
      safe(function()
        -- Ensure character branch + prev store
        local key, char = EnsureCharacterBranches()
        char.prev = _ensurePrevStore(char)

        -- If available, use the current selection to read the completed quest
        local sel = type(GetQuestLogSelection) == "function" and GetQuestLogSelection() or nil
        if sel and type(GetQuestLogTitle) == "function" then
          local title, level, _, isHeader, _, isComplete, questID = GetQuestLogTitle(sel)
          
          -- FIXED: Use index as ID if questID is nil (for servers that don't return questID)
          local useID = questID or sel
          
          -- Emit immediately if we have identifiers (don't require questID anymore)
          if title and not isHeader and useID then
            markCompleted(useID, questRewardPending.quest_title)
            _logEvent("quests", "completed", { id = useID, title = title })
          end
        end
      end)

      -- Capture quest reward info
      safe(OnQuestCompleteDialog)

      -- Refresh the log after completion (may remove the quest or update state)
      safe(NS.Quests_ScanLog)

    elseif event == "QUEST_FINISHED" then
      -- NEW: Mark quest as completed using reward data as backup
      -- (in case QUEST_COMPLETE doesn't fire on this server)
      safe(function()
        if questRewardPending and (questRewardPending.quest_id or questRewardPending.quest_title) then
          local key, char = EnsureCharacterBranches()
          char.prev = _ensurePrevStore(char)
          
          local useID = questRewardPending.quest_id
          
          -- If no quest_id, try to find in log by title before it disappears
          if not useID and type(GetNumQuestLogEntries) == "function" and type(GetQuestLogTitle) == "function" then
            local numEntries = GetNumQuestLogEntries()
            for i = 1, numEntries do
              local title, _, _, isHeader, _, _, questID = GetQuestLogTitle(i)
              if not isHeader and title == questRewardPending.quest_title then
                useID = questID or i
                break
              end
            end
          end
          
          -- Fallback: use title hash as ID
          if not useID and questRewardPending.quest_title then
            local hash = 0
            for i = 1, #questRewardPending.quest_title do
              hash = hash + string.byte(questRewardPending.quest_title, i)
            end
            useID = hash
          end
          
          if useID then
            markCompleted(useID, questRewardPending.quest_title)
            _logEvent("quests", "completed", { id = useID, title = questRewardPending.quest_title })
            
            if NS.Log then
              NS.Log("INFO", "Quest marked COMPLETED via QUEST_FINISHED: %s (ID: %s)", 
                questRewardPending.quest_title, tostring(useID))
            end
          end
        end
      end)
      
      -- Original: Save quest reward data
      safe(OnQuestTurnedIn)

    elseif event == "TRADE_SKILL_UPDATE" then
      safe(NS.Quests_ScanTradeSkills)

    elseif event == "PLAYER_ENTERING_WORLD" then
      safe(NS.Quests_ScanAll)
    end
  end)

  -- Event subscriptions
  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:RegisterEvent("UPDATE_FACTION")
  f:RegisterEvent("GLYPH_ADDED")
  f:RegisterEvent("GLYPH_REMOVED")
  f:RegisterEvent("GLYPH_UPDATED")
  f:RegisterEvent("COMPANION_UPDATE")
  f:RegisterEvent("COMPANION_LEARNED")
  f:RegisterEvent("QUEST_LOG_UPDATE")
  f:RegisterEvent("QUEST_COMPLETE") -- required for fast-path emit
  f:RegisterEvent("QUEST_FINISHED") -- quest actually turned in
  f:RegisterEvent("TRADE_SKILL_UPDATE")
end

-- Auto-wire on load (safe: function guards against double-registration)
NS.Quests_RegisterEvents()