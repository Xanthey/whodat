-- tracker_loot.lua
-- WhoDAT - Enhanced Loot History Tracking
-- Tracks loot with full context: source, rolls, instance, group
-- Wrath 3.3.5a compatible

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Loot State Tracking
-- ============================================================================

local lootState = {
  currentSource = nil,
  activeRolls = {},
  recentLoot = {},
}

-- ============================================================================
-- Source Detection
-- ============================================================================

local function DetermineSourceType()
  -- Check what we're looting
  if UnitExists("target") and UnitIsDead("target") then
    local classification = UnitClassification("target")
    
    return {
      type = "mob",
      name = UnitName("target"),
      guid = UnitGUID("target"),
      level = UnitLevel("target"),
      classification = classification,
      is_boss = (classification == "worldboss" or classification == "elite"),
    }
  end
  
  -- Check for container/chest
  -- Wrath doesn't have a reliable API for this, use heuristics
  local cursor = GetCursorInfo()
  if cursor == "item" then
    return {
      type = "chest",
      name = "Container",
    }
  end
  
  return {
    type = "unknown",
    name = "Unknown Source",
  }
end

-- ============================================================================
-- Loot Roll Tracking
-- ============================================================================

local function OnLootRollStarted(rollID)
  local texture, name, count, quality, bindType, canNeed, canGreed, canDisenchant = GetLootRollItemInfo(rollID)
  local link = GetLootRollItemLink(rollID)
  
  if not link then return end
  
  lootState.activeRolls[rollID] = {
    rollID = rollID,
    link = link,
    name = name,
    quality = quality,
    count = count,
    canNeed = canNeed,
    canGreed = canGreed,
    canDisenchant = canDisenchant,
    startTime = time(),
    competitors = {},
  }
  
  if NS.Log then
    NS.Log("DEBUG", "Loot roll started: %s (id: %d)", name, rollID)
  end
end

local function OnLootRoll(rollID, playerName, rollType, roll)
  local rollData = lootState.activeRolls[rollID]
  if not rollData then return end
  
  -- Track who rolled
  table.insert(rollData.competitors, {
    name = playerName,
    rollType = rollType,  -- 1=need, 2=greed, 3=disenchant, 0=pass
    roll = roll,
  })
end

local function OnLootRollWon(rollID, winner)
  local rollData = lootState.activeRolls[rollID]
  if not rollData then return end
  
  rollData.winner = winner
  rollData.won = (winner == UnitName("player"))
  rollData.endTime = time()
  
  -- If player won, log it
  if rollData.won then
    LogLootObtained(rollData.link, {
      source_type = "roll",
      roll_id = rollID,
      roll_type = rollData.yourRoll and rollData.yourRoll.type or nil,
      roll_value = rollData.yourRoll and rollData.yourRoll.value or nil,
      competitors = #rollData.competitors,
    })
  end
  
  -- Cleanup
  lootState.activeRolls[rollID] = nil
end

-- ============================================================================
-- Direct Loot (Auto-loot, Master Loot Given, etc.)
-- ============================================================================

local function OnLootOpened()
  lootState.currentSource = DetermineSourceType()
  
  -- Get instance context
  local inInstance, instanceType = IsInInstance()
  if inInstance then
    local name, type, difficulty = GetInstanceInfo()
    lootState.currentSource.instance = {
      name = name,
      type = type,
      difficulty = difficulty,
    }
  end
  
  -- Get group context (Wrath 3.3.5a compatible)
  local numRaid = GetNumRaidMembers()
  local numParty = GetNumPartyMembers()
  
  if numRaid > 0 then
    lootState.currentSource.group = {
      type = "raid",
      size = numRaid,
    }
  elseif numParty > 0 then
    lootState.currentSource.group = {
      type = "party",
      size = numParty + 1,  -- +1 to include player
    }
  else
    lootState.currentSource.group = {
      type = "solo",
      size = 1,
    }
  end
  
  -- Get zone context
  lootState.currentSource.zone = GetRealZoneText() or GetZoneText()
  lootState.currentSource.subzone = GetSubZoneText()
end

local function OnLootClosed()
  lootState.currentSource = nil
end

local function OnLootReceived(msg)
  -- Parse loot message
  -- "You receive loot: [Item Link]"
  -- "You receive loot: [Item Link] x3"
  
  local link, count = msg:match("You receive loot: (.+)%s*x(%d+)")
  if not link then
    link = msg:match("You receive loot: (.+)")
    count = 1
  else
    count = tonumber(count) or 1
  end
  
  if not link then return end
  
  -- Log with current source context
  LogLootObtained(link, {
    source_type = lootState.currentSource and lootState.currentSource.type or "unknown",
    source_name = lootState.currentSource and lootState.currentSource.name or nil,
    source_level = lootState.currentSource and lootState.currentSource.level or nil,
    is_boss = lootState.currentSource and lootState.currentSource.is_boss or false,
    count = count,
  })
end

-- ============================================================================
-- Loot Logging
-- ============================================================================

function LogLootObtained(itemLink, context)
  context = context or {}
  
  -- Extract item info
  local name, _, quality, ilvl, _, _, _, _, _, icon = GetItemInfo(itemLink)
  local itemID = itemLink:match("|Hitem:(%d+):")
  itemID = itemID and tonumber(itemID) or nil
  
  -- Build loot event
  local lootEvent = {
    ts = time(),
    
    -- Item details
    link = itemLink,
    item_id = itemID,
    name = name,
    quality = quality,
    ilvl = ilvl,
    icon = icon,
    count = context.count or 1,
    
    -- Source details
    source_type = context.source_type or "unknown",
    source_name = context.source_name,
    source_level = context.source_level,
    is_boss = context.is_boss or false,
    
    -- Instance context
    instance = lootState.currentSource and lootState.currentSource.instance and lootState.currentSource.instance.name or nil,
    instance_difficulty = lootState.currentSource and lootState.currentSource.instance and lootState.currentSource.instance.difficulty or nil,
    
    -- Group context
    group_type = lootState.currentSource and lootState.currentSource.group and lootState.currentSource.group.type or "solo",
    group_size = lootState.currentSource and lootState.currentSource.group and lootState.currentSource.group.size or 1,
    
    -- Location
    zone = lootState.currentSource and lootState.currentSource.zone or GetRealZoneText() or GetZoneText(),
    subzone = lootState.currentSource and lootState.currentSource.subzone or GetSubZoneText(),
    
    -- Roll details (if applicable)
    roll_type = context.roll_type,
    roll_value = context.roll_value,
    competitors = context.competitors,
  }
  
  -- Save to database
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or (GetRealmName() .. ":" .. UnitName("player"))
  
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  WhoDatDB.characters[key].events = WhoDatDB.characters[key].events or {}
  WhoDatDB.characters[key].events.loot = WhoDatDB.characters[key].events.loot or {}
  
  table.insert(WhoDatDB.characters[key].events.loot, lootEvent)
  
  -- Limit storage
  local maxLoot = 1000
  while #WhoDatDB.characters[key].events.loot > maxLoot do
    table.remove(WhoDatDB.characters[key].events.loot, 1)
  end
  
  -- Emit to EventBus
  if NS.EventBus and NS.EventBus.Emit then
    NS.EventBus:Emit("loot", "obtained", lootEvent)
  end
  
  if NS.Log then
    NS.Log("INFO", "Loot: %s x%d from %s",
      name,
      lootEvent.count,
      lootEvent.source_name or lootEvent.source_type)
  end
end

-- ============================================================================
-- Event Registration
-- ============================================================================

local frame = CreateFrame("Frame")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("CHAT_MSG_LOOT")
frame:RegisterEvent("START_LOOT_ROLL")
frame:RegisterEvent("LOOT_HISTORY_ROLL_CHANGED")
frame:RegisterEvent("LOOT_HISTORY_ROLL_COMPLETE")

frame:SetScript("OnEvent", function(self, event, ...)
  if event == "LOOT_OPENED" then
    OnLootOpened()
    
  elseif event == "LOOT_CLOSED" then
    OnLootClosed()
    
  elseif event == "CHAT_MSG_LOOT" then
    local msg = ...
    if msg and msg:match("^You receive") then
      OnLootReceived(msg)
    end
    
  elseif event == "START_LOOT_ROLL" then
    local rollID = ...
    OnLootRollStarted(rollID)
    
  elseif event == "LOOT_HISTORY_ROLL_CHANGED" then
    local rollID, playerName, rollType, roll = ...
    OnLootRoll(rollID, playerName, rollType, roll)
    
  elseif event == "LOOT_HISTORY_ROLL_COMPLETE" then
    local rollID, winner = ...
    OnLootRollWon(rollID, winner)
  end
end)

-- ============================================================================
-- SQL Schema
-- ============================================================================

--[[
CREATE TABLE loot_history (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  character_id BIGINT UNSIGNED NOT NULL,
  ts INT UNSIGNED NOT NULL,
  
  -- Item details
  item_id INT UNSIGNED,
  item_link TEXT,
  item_name VARCHAR(128),
  quality TINYINT UNSIGNED,
  ilvl SMALLINT UNSIGNED,
  icon VARCHAR(128),
  count SMALLINT UNSIGNED,
  
  -- Source details
  source_type ENUM('mob', 'boss', 'chest', 'quest', 'vendor', 'craft', 'roll', 'unknown'),
  source_name VARCHAR(128),
  source_level TINYINT UNSIGNED,
  is_boss BOOLEAN,
  
  -- Instance context
  instance VARCHAR(128),
  instance_difficulty VARCHAR(64),
  
  -- Group context
  group_type ENUM('solo', 'party', 'raid'),
  group_size TINYINT UNSIGNED,
  
  -- Location
  zone VARCHAR(128),
  subzone VARCHAR(128),
  
  -- Roll details (if applicable)
  roll_type TINYINT,  -- 1=need, 2=greed, 3=DE
  roll_value TINYINT,
  competitors TINYINT UNSIGNED,
  
  KEY idx_char_ts (character_id, ts),
  KEY idx_item (item_id),
  KEY idx_source (source_name),
  KEY idx_boss (is_boss, quality DESC),
  KEY idx_instance (instance),
  CONSTRAINT fk_loot_char FOREIGN KEY (character_id)
    REFERENCES characters(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
]]

-- ============================================================================
-- Analytics Queries
-- ============================================================================

--[[
-- Best loot from bosses
SELECT 
  source_name as boss,
  item_name,
  quality,
  ilvl,
  COUNT(*) as times_looted,
  instance
FROM loot_history
WHERE character_id = ?
  AND is_boss = TRUE
  AND quality >= 4  -- Epic+
GROUP BY source_name, item_name
ORDER BY quality DESC, ilvl DESC;

-- Loot by instance
SELECT 
  instance,
  COUNT(*) as items_looted,
  AVG(ilvl) as avg_ilvl,
  MAX(ilvl) as best_ilvl
FROM loot_history
WHERE character_id = ?
  AND instance IS NOT NULL
GROUP BY instance
ORDER BY avg_ilvl DESC;

-- Roll statistics
SELECT 
  roll_type,
  COUNT(*) as total_rolls,
  AVG(roll_value) as avg_roll,
  SUM(CASE WHEN roll_value >= 90 THEN 1 ELSE 0 END) as high_rolls
FROM loot_history
WHERE character_id = ?
  AND roll_type IS NOT NULL
GROUP BY roll_type;
]]

-- ============================================================================
-- Debug Commands
-- ============================================================================

SLASH_WDLOOT1 = "/wdloot"
SlashCmdList["WDLOOT"] = function(msg)
  msg = (msg or ""):lower()
  
  if msg == "stats" then
    local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
      or (GetRealmName() .. ":" .. UnitName("player"))
    
    local char = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
    local loot = char and char.events and char.events.loot or {}
    
    print("=== Loot Statistics ===")
    print(string.format("Total items looted: %d", #loot))
    
    if #loot > 0 then
      local byQuality = {}
      local fromBosses = 0
      
      for _, item in ipairs(loot) do
        local q = item.quality or 0
        byQuality[q] = (byQuality[q] or 0) + 1
        
        if item.is_boss then
          fromBosses = fromBosses + 1
        end
      end
      
      print("\nBy quality:")
      local qualities = {"Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary"}
      for q = 0, 5 do
        if byQuality[q] then
          print(string.format("  %s: %d", qualities[q+1] or "Unknown", byQuality[q]))
        end
      end
      
      print(string.format("\nFrom bosses: %d", fromBosses))
    end
    
  elseif msg == "recent" then
    local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
      or (GetRealmName() .. ":" .. UnitName("player"))
    
    local char = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
    local loot = char and char.events and char.events.loot or {}
    
    print("=== Recent Loot ===")
    
    local start = math.max(1, #loot - 9)
    for i = start, #loot do
      local item = loot[i]
      print(string.format("[%s] %s from %s",
        date("%H:%M", item.ts),
        item.name,
        item.source_name or item.source_type))
    end
    
  else
    print("=== WhoDAT Loot Tracker ===")
    print("/wdloot stats  - Show loot statistics")
    print("/wdloot recent - Show recent loot")
  end
end

return NS