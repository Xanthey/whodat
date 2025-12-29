-- tracker_lockouts.lua
-- WhoDAT - Instance Lockout Tracking
-- Tracks raid/dungeon lockouts and boss kills
-- Wrath 3.3.5a compatible

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Lockout State
-- ============================================================================

local lockoutState = {
  lastScan = 0,
  activeLockouts = {},
}

-- ============================================================================
-- Scan Instance Lockouts
-- ============================================================================

local function ScanLockouts()
  local now = time()
  
  -- Don't scan too frequently
  if now - lockoutState.lastScan < 300 then  -- 5 minutes
    return
  end
  
  lockoutState.lastScan = now
  
  local lockouts = {}
  local numSaved = GetNumSavedInstances()
  
  for i = 1, numSaved do
    local name, id, reset, difficulty, locked, extended, instanceIDMostSig, isRaid, maxPlayers, difficultyName = GetSavedInstanceInfo(i)
    
    if locked then
      local lockout = {
        ts = now,
        instance_name = name,
        instance_id = id,
        difficulty = difficulty,
        difficulty_name = difficultyName,
        is_raid = isRaid,
        max_players = maxPlayers,
        reset_time = now + reset,
        extended = extended,
        
        -- Track boss kills
        bosses = {},
      }
      
      -- Get boss kill info
      local numEncounters, numCompleted = GetSavedInstanceEncounterInfo(i)
      lockout.total_bosses = numEncounters
      lockout.bosses_killed = numCompleted
      
      -- Get individual boss info
      for j = 1, numEncounters do
        local bossName, _, isKilled = GetSavedInstanceEncounterInfo(i, j)
        
        if bossName then
          table.insert(lockout.bosses, {
            name = bossName,
            killed = isKilled,
          })
        end
      end
      
      table.insert(lockouts, lockout)
    end
  end
  
  -- Save to database
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or (GetRealmName() .. ":" .. UnitName("player"))
  
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  WhoDatDB.characters[key].snapshots = WhoDatDB.characters[key].snapshots or {}
  WhoDatDB.characters[key].snapshots.lockouts = {
    ts = now,
    lockouts = lockouts,
  }
  
  -- Also keep history
  WhoDatDB.characters[key].events = WhoDatDB.characters[key].events or {}
  WhoDatDB.characters[key].events.lockouts = WhoDatDB.characters[key].events.lockouts or {}
  
  for _, lockout in ipairs(lockouts) do
    -- Only log NEW lockouts or boss kills
    local existing = FindExistingLockout(lockout)
    
    if not existing or lockout.bosses_killed > (existing.bosses_killed or 0) then
      table.insert(WhoDatDB.characters[key].events.lockouts, lockout)
    end
  end
  
  -- Limit history
  local maxHistory = 100
  while #WhoDatDB.characters[key].events.lockouts > maxHistory do
    table.remove(WhoDatDB.characters[key].events.lockouts, 1)
  end
  
  if NS.Log then
    NS.Log("INFO", "Scanned %d active lockouts", #lockouts)
  end
  
  return lockouts
end

function FindExistingLockout(lockout)
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or (GetRealmName() .. ":" .. UnitName("player"))
  
  local char = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  local history = char and char.events and char.events.lockouts or {}
  
  -- Find most recent matching lockout (same instance + difficulty)
  for i = #history, 1, -1 do
    local existing = history[i]
    
    if existing.instance_name == lockout.instance_name and
       existing.difficulty == lockout.difficulty then
      return existing
    end
  end
  
  return nil
end

-- ============================================================================
-- Boss Kill Tracking
-- ============================================================================

local function OnBossKill(bossName, bossGUID)
  -- Get current instance
  local inInstance, instanceType = IsInInstance()
  if not inInstance then return end
  
  local name, type, difficulty, difficultyName = GetInstanceInfo()
  
  local killEvent = {
    ts = time(),
    boss_name = bossName,
    boss_guid = bossGUID,
    instance = name,
    instance_type = type,
    difficulty = difficulty,
    difficulty_name = difficultyName,
    
    -- Group info
    group_type = IsInRaid() and "raid" or (IsInGroup() and "party" or "solo"),
    group_size = GetNumGroupMembers() or 1,
  }
  
  -- Save to database
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or (GetRealmName() .. ":" .. UnitName("player"))
  
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  WhoDatDB.characters[key].events = WhoDatDB.characters[key].events or {}
  WhoDatDB.characters[key].events.boss_kills = WhoDatDB.characters[key].events.boss_kills or {}
  
  table.insert(WhoDatDB.characters[key].events.boss_kills, killEvent)
  
  -- Emit to EventBus
  if NS.EventBus and NS.EventBus.Emit then
    NS.EventBus:Emit("raid", "boss_killed", killEvent)
  end
  
  if NS.Log then
    NS.Log("INFO", "Boss killed: %s in %s (%s)",
      bossName, name, difficultyName)
  end
  
  -- Trigger lockout rescan
  ScanLockouts()
end

-- ============================================================================
-- Event Registration
-- ============================================================================

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("UPDATE_INSTANCE_INFO")
frame:RegisterEvent("BOSS_KILL")
frame:RegisterEvent("ENCOUNTER_END")

-- Periodic scan timer
local scanTimer = 0
frame:SetScript("OnUpdate", function(self, elapsed)
  scanTimer = scanTimer + elapsed
  
  if scanTimer >= 300 then  -- Every 5 minutes
    scanTimer = 0
    ScanLockouts()
  end
end)

frame:SetScript("OnEvent", function(self, event, ...)
  if event == "PLAYER_LOGIN" or event == "UPDATE_INSTANCE_INFO" then
    ScanLockouts()
    
  elseif event == "BOSS_KILL" then
    local encounterID, name = ...
    -- BOSS_KILL provides encounter ID and name
    OnBossKill(name, nil)
    
  elseif event == "ENCOUNTER_END" then
    local encounterID, encounterName, difficultyID, raidSize, endStatus = ...
    
    -- endStatus: 0 = wipe, 1 = kill
    if endStatus == 1 then
      OnBossKill(encounterName, nil)
    end
  end
end)

-- ============================================================================
-- Public API
-- ============================================================================

function NS.Lockouts_Scan()
  return ScanLockouts()
end

-- ============================================================================
-- SQL Schema
-- ============================================================================

--[[
CREATE TABLE instance_lockouts (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  character_id BIGINT UNSIGNED NOT NULL,
  ts INT UNSIGNED NOT NULL,
  
  instance_name VARCHAR(128),
  instance_id INT UNSIGNED,
  difficulty TINYINT UNSIGNED,
  difficulty_name VARCHAR(64),
  is_raid BOOLEAN,
  max_players TINYINT UNSIGNED,
  
  total_bosses TINYINT UNSIGNED,
  bosses_killed TINYINT UNSIGNED,
  
  reset_time INT UNSIGNED,
  extended BOOLEAN,
  
  KEY idx_char_ts (character_id, ts),
  KEY idx_instance (instance_name, difficulty),
  KEY idx_reset (reset_time),
  CONSTRAINT fk_lockout_char FOREIGN KEY (character_id)
    REFERENCES characters(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE boss_kills (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  character_id BIGINT UNSIGNED NOT NULL,
  ts INT UNSIGNED NOT NULL,
  
  boss_name VARCHAR(128),
  boss_guid VARCHAR(64),
  
  instance VARCHAR(128),
  instance_type VARCHAR(32),
  difficulty TINYINT UNSIGNED,
  difficulty_name VARCHAR(64),
  
  group_type ENUM('solo', 'party', 'raid'),
  group_size TINYINT UNSIGNED,
  
  KEY idx_char_ts (character_id, ts),
  KEY idx_boss (boss_name),
  KEY idx_instance (instance, difficulty),
  CONSTRAINT fk_kill_char FOREIGN KEY (character_id)
    REFERENCES characters(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
]]

-- ============================================================================
-- Debug Commands
-- ============================================================================

SLASH_WDLOCKOUTS1 = "/wdlockouts"
SlashCmdList["WDLOCKOUTS"] = function(msg)
  msg = (msg or ""):lower()
  
  if msg == "scan" then
    local lockouts = ScanLockouts()
    print(string.format("[WhoDAT] Scanned %d active lockouts", #lockouts))
    
  elseif msg == "list" then
    local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
      or (GetRealmName() .. ":" .. UnitName("player"))
    
    local char = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
    local snapshot = char and char.snapshots and char.snapshots.lockouts
    
    if snapshot and snapshot.lockouts then
      print("=== Active Lockouts ===")
      
      for _, lockout in ipairs(snapshot.lockouts) do
        local resetIn = lockout.reset_time - time()
        local resetHours = math.floor(resetIn / 3600)
        
        print(string.format("%s (%s): %d/%d bosses, resets in %dh",
          lockout.instance_name,
          lockout.difficulty_name or "Normal",
          lockout.bosses_killed,
          lockout.total_bosses,
          resetHours))
      end
    else
      print("[WhoDAT] No active lockouts")
    end
    
  else
    print("=== WhoDAT Lockout Tracker ===")
    print("/wdlockouts scan - Scan current lockouts")
    print("/wdlockouts list - List active lockouts")
  end
end

return NS