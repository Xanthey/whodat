-- tracker_deaths.lua
-- WhoDAT - Death Tracking (Critical Missing Feature)
-- Tracks player deaths with killer info, location, and durability loss
-- Wrath 3.3.5a compatible

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Death State Tracking
-- ============================================================================

local deathState = {
  lastAttacker = nil,
  durabilityBeforeDeath = nil,
  deathTime = nil,
  combatStartTime = nil
}

-- ============================================================================
-- Durability Tracking
-- ============================================================================

local function GetAverageDurability()
  local total, count = 0, 0
  
  for slot = 1, 18 do
    local current, maximum = GetInventoryItemDurability(slot)
    if current and maximum and maximum > 0 then
      total = total + (current / maximum)
      count = count + 1
    end
  end
  
  if count == 0 then return 100 end
  return (total / count) * 100
end

local function GetDurabilityLoss(beforePct, afterPct)
  return beforePct - afterPct
end

-- ============================================================================
-- Combat Log Parsing for Killer Detection
-- ============================================================================

local function OnCombatLog(timestamp, event, _, sourceGUID, sourceName, sourceFlags, _, destGUID, destName, destFlags, ...)
  -- Only track damage to player
  if destGUID ~= UnitGUID("player") then return end
  
  -- Track any damage source
  if event == "SWING_DAMAGE" or 
     event:match("_DAMAGE$") or 
     event:match("_DAMAGE_LANDED$") then
    
    -- Determine source type
    local sourceType = "unknown"
    if bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_NPC) > 0 then
      sourceType = "npc"
    elseif bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_PLAYER) > 0 then
      sourceType = "player"
    elseif bit.band(sourceFlags, COMBATLOG_OBJECT_TYPE_PET) > 0 then
      sourceType = "pet"
    end
    
    -- Update last attacker
    deathState.lastAttacker = {
      name = sourceName or "Unknown",
      guid = sourceGUID,
      type = sourceType,
      timestamp = GetTime()
    }
  end
  
  -- Track when player enters combat
  if event == "SWING_DAMAGE" or event:match("_DAMAGE") then
    if not deathState.combatStartTime then
      deathState.combatStartTime = GetTime()
    end
  end
end

-- ============================================================================
-- Death Detection
-- ============================================================================

local function OnPlayerDead()
  -- Capture durability immediately (before any repair/rez)
  deathState.durabilityBeforeDeath = GetAverageDurability()
  deathState.deathTime = time()
  
  -- Get location
  local zone = GetRealZoneText() or GetZoneText() or "Unknown"
  local subzone = GetSubZoneText() or ""
  local x, y = GetPlayerMapPosition("player")
  
  -- Get instance info
  local inInstance, instanceType = IsInInstance()
  local instanceName, instanceType, difficulty = GetInstanceInfo()
  
  -- Get group info
  local groupSize = GetNumGroupMembers() or 0
  local groupType = IsInRaid() and "raid" or (IsInGroup() and "party" or "solo")
  
  -- Calculate time in combat before death
  local combatDuration = nil
  if deathState.combatStartTime then
    combatDuration = GetTime() - deathState.combatStartTime
  end
  
  -- Build death event
  local deathEvent = {
    ts = deathState.deathTime,
    zone = zone,
    subzone = subzone,
    x = x,
    y = y,
    level = UnitLevel("player"),
    
    -- Killer info
    killer_name = deathState.lastAttacker and deathState.lastAttacker.name or "Unknown",
    killer_type = deathState.lastAttacker and deathState.lastAttacker.type or "unknown",
    killer_guid = deathState.lastAttacker and deathState.lastAttacker.guid or nil,
    
    -- Instance info
    in_instance = inInstance,
    instance_name = instanceName,
    instance_type = instanceType,
    instance_difficulty = difficulty,
    
    -- Group info
    group_size = groupSize,
    group_type = groupType,
    
    -- Combat info
    combat_duration = combatDuration,
    durability_before = deathState.durabilityBeforeDeath,
    
    -- Will be filled in on resurrection
    durability_after = nil,
    durability_loss = nil,
    rez_type = nil,
    rez_time = nil,
  }
  
  -- Store temporarily until resurrection
  deathState.pendingDeath = deathEvent
  
  if NS.Log then
    NS.Log("WARN", "Death: %s in %s%s",
      deathEvent.killer_name,
      zone,
      subzone ~= "" and (" (" .. subzone .. ")") or "")
  end
end

-- ============================================================================
-- Resurrection Detection
-- ============================================================================

local function OnPlayerAlive()
  if not deathState.pendingDeath then return end
  
  -- Calculate death duration
  local deathDuration = time() - deathState.deathTime
  
  -- Get durability after resurrection
  local durabilityAfter = GetAverageDurability()
  local durabilityLoss = GetDurabilityLoss(
    deathState.durabilityBeforeDeath or 100,
    durabilityAfter
  )
  
  -- Determine resurrection type
  local rezType = "spirit"  -- Default assumption
  
  -- Check for soulstone buff (warlock rez)
  if UnitBuff("player", "Soulstone Resurrection") then
    rezType = "soulstone"
  -- Check for other class rezzes
  elseif durabilityLoss == 0 then
    -- No durability loss = likely class rez or soulstone
    rezType = "class_rez"
  elseif deathDuration < 10 then
    -- Very fast rez = probably at corpse
    rezType = "corpse"
  end
  
  -- Complete the death event
  deathState.pendingDeath.durability_after = durabilityAfter
  deathState.pendingDeath.durability_loss = durabilityLoss
  deathState.pendingDeath.rez_type = rezType
  deathState.pendingDeath.rez_time = deathDuration
  deathState.pendingDeath.rez_ts = time()
  
  -- Save to database
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or (GetRealmName() .. ":" .. UnitName("player"))
  
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  WhoDatDB.characters[key].events = WhoDatDB.characters[key].events or {}
  WhoDatDB.characters[key].events.deaths = WhoDatDB.characters[key].events.deaths or {}
  
  table.insert(WhoDatDB.characters[key].events.deaths, deathState.pendingDeath)
  
  -- Emit to EventBus
  if NS.EventBus and NS.EventBus.Emit then
    NS.EventBus:Emit("player", "death", deathState.pendingDeath)
  end
  
  if NS.Log then
    NS.Log("INFO", "Death logged: %s (dur loss: %.1f%%, rez: %s, time: %ds)",
      deathState.pendingDeath.killer_name,
      durabilityLoss,
      rezType,
      deathDuration)
  end
  
  -- Clear state
  deathState.pendingDeath = nil
  deathState.combatStartTime = nil
end

-- ============================================================================
-- Event Registration
-- ============================================================================

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_ALIVE")
frame:RegisterEvent("PLAYER_UNGHOST")
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")  -- Entering combat
frame:RegisterEvent("PLAYER_REGEN_ENABLED")   -- Leaving combat

frame:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_DEAD" then
    OnPlayerDead()
    
  elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
    OnPlayerAlive()
    
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    OnCombatLog(...)
    
  elseif event == "PLAYER_REGEN_DISABLED" then
    -- Track combat start
    deathState.combatStartTime = GetTime()
    
  elseif event == "PLAYER_REGEN_ENABLED" then
    -- Reset combat timer when leaving combat safely
    if not deathState.pendingDeath then
      deathState.combatStartTime = nil
      deathState.lastAttacker = nil
    end
  end
end)

-- ============================================================================
-- SQL Schema
-- ============================================================================

--[[
CREATE TABLE deaths (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  character_id BIGINT UNSIGNED NOT NULL,
  ts INT UNSIGNED NOT NULL,
  
  -- Location
  zone VARCHAR(128),
  subzone VARCHAR(128),
  x FLOAT,
  y FLOAT,
  level TINYINT UNSIGNED,
  
  -- Killer
  killer_name VARCHAR(128),
  killer_type ENUM('npc', 'player', 'pet', 'unknown'),
  killer_guid VARCHAR(64),
  
  -- Instance
  in_instance BOOLEAN,
  instance_name VARCHAR(128),
  instance_type VARCHAR(32),
  instance_difficulty VARCHAR(32),
  
  -- Group
  group_size TINYINT UNSIGNED,
  group_type ENUM('solo', 'party', 'raid'),
  
  -- Combat
  combat_duration FLOAT,
  
  -- Durability
  durability_before FLOAT,
  durability_after FLOAT,
  durability_loss FLOAT,
  
  -- Resurrection
  rez_type ENUM('spirit', 'corpse', 'soulstone', 'class_rez', 'unknown'),
  rez_time INT UNSIGNED,
  rez_ts INT UNSIGNED,
  
  KEY idx_char_ts (character_id, ts),
  KEY idx_zone (zone),
  KEY idx_killer (killer_name),
  KEY idx_instance (instance_name),
  CONSTRAINT fk_death_char FOREIGN KEY (character_id)
    REFERENCES characters(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
]]

-- ============================================================================
-- Analytics Queries (Examples)
-- ============================================================================

--[[
-- Death heatmap by zone
SELECT 
  zone,
  COUNT(*) as death_count,
  AVG(durability_loss) as avg_dur_loss
FROM deaths
WHERE character_id = ?
GROUP BY zone
ORDER BY death_count DESC;

-- Most lethal bosses/mobs
SELECT 
  killer_name,
  COUNT(*) as times_killed_you,
  zone,
  instance_name
FROM deaths
WHERE character_id = ?
  AND killer_type = 'npc'
GROUP BY killer_name, zone, instance_name
ORDER BY times_killed_you DESC
LIMIT 10;

-- Deaths over time (by day)
SELECT 
  DATE(FROM_UNIXTIME(ts)) as date,
  COUNT(*) as deaths,
  AVG(combat_duration) as avg_combat_time,
  SUM(durability_loss) as total_dur_loss
FROM deaths
WHERE character_id = ?
GROUP BY DATE(FROM_UNIXTIME(ts))
ORDER BY date;

-- Resurrection type distribution
SELECT 
  rez_type,
  COUNT(*) as count,
  AVG(rez_time) as avg_time_to_rez
FROM deaths
WHERE character_id = ?
GROUP BY rez_type;
]]

-- ============================================================================
-- Debug Commands
-- ============================================================================

SLASH_WDDEATHS1 = "/wddeaths"
SlashCmdList["WDDEATHS"] = function(msg)
  msg = (msg or ""):lower()
  
  if msg == "stats" then
    local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
      or (GetRealmName() .. ":" .. UnitName("player"))
    
    local char = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
    local deaths = char and char.events and char.events.deaths or {}
    
    print(string.format("=== Death Statistics ==="))
    print(string.format("Total deaths: %d", #deaths))
    
    if #deaths > 0 then
      -- Count by killer type
      local byType = {}
      local byZone = {}
      local totalDurLoss = 0
      
      for _, death in ipairs(deaths) do
        local ktype = death.killer_type or "unknown"
        byType[ktype] = (byType[ktype] or 0) + 1
        
        local zone = death.zone or "Unknown"
        byZone[zone] = (byZone[zone] or 0) + 1
        
        totalDurLoss = totalDurLoss + (death.durability_loss or 0)
      end
      
      print("\nBy killer type:")
      for ktype, count in pairs(byType) do
        print(string.format("  %s: %d", ktype, count))
      end
      
      print("\nTop zones:")
      local zoneList = {}
      for zone, count in pairs(byZone) do
        table.insert(zoneList, {zone = zone, count = count})
      end
      table.sort(zoneList, function(a, b) return a.count > b.count end)
      
      for i = 1, math.min(5, #zoneList) do
        print(string.format("  %s: %d", zoneList[i].zone, zoneList[i].count))
      end
      
      print(string.format("\nTotal durability loss: %.1f%%", totalDurLoss))
      print(string.format("Average per death: %.1f%%", totalDurLoss / #deaths))
    end
    
  elseif msg == "recent" then
    local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
      or (GetRealmName() .. ":" .. UnitName("player"))
    
    local char = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
    local deaths = char and char.events and char.events.deaths or {}
    
    print("=== Recent Deaths ===")
    
    local start = math.max(1, #deaths - 9)
    for i = start, #deaths do
      local death = deaths[i]
      local timestamp = date("%Y-%m-%d %H:%M", death.ts)
      print(string.format("[%s] %s in %s (dur: %.1f%%)",
        timestamp,
        death.killer_name,
        death.zone,
        death.durability_loss or 0))
    end
    
  else
    print("=== WhoDAT Death Tracker ===")
    print("/wddeaths stats  - Show death statistics")
    print("/wddeaths recent - Show recent deaths")
  end
end

return NS