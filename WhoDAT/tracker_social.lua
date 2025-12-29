-- tracker_social.lua
-- WhoDAT - Enhanced Social Tracking
-- Tracks group composition, friend/ignore lists, and social interactions
-- Wrath 3.3.5a compatible

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Social State
-- ============================================================================

local socialState = {
  lastFriendsScan = 0,
  lastIgnoreScan = 0,
  lastGroupScan = 0,
  
  -- Cached lists
  friends = {},
  ignored = {},
}

-- ============================================================================
-- Forward Declarations
-- ============================================================================

local LogFriendListChange, LogIgnoreListChange, DetectListChanges

-- ============================================================================
-- Group Composition Tracking
-- ============================================================================

local function ScanGroupComposition()
  if not IsInRaid() and not IsInGroup() then return nil end
  
  local size = GetNumGroupMembers()
  local members = {}
  
  for i = 1, size do
    local unit = IsInRaid() and "raid"..i or (i == 1 and "player" or "party"..(i-1))
    
    if UnitExists(unit) then
      local name = UnitName(unit)
      local _, class = UnitClass(unit)
      local role = UnitGroupRolesAssigned(unit) or "NONE"  -- TANK, HEALER, DAMAGER, NONE
      local level = UnitLevel(unit)
      local guid = UnitGUID(unit)
      
      table.insert(members, {
        name = name,
        class = class,
        role = role,
        level = level,
        guid = guid,
      })
    end
  end
  
  -- Get instance info if applicable
  local instance = nil
  local inInstance, instanceType = IsInInstance()
  if inInstance then
    local name, type, difficulty, difficultyName = GetInstanceInfo()
    instance = {
      name = name,
      type = type,
      difficulty = difficulty,
      difficultyName = difficultyName,
    }
  end
  
  return {
    ts = time(),
    type = IsInRaid() and "raid" or "party",
    size = size,
    members = members,
    instance = instance,
    zone = GetRealZoneText() or GetZoneText(),
    subzone = GetSubZoneText(),
  }
end

local function OnGroupChanged()
  local composition = ScanGroupComposition()
  
  if not composition then return end
  
  -- Save to database
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or (GetRealmName() .. ":" .. UnitName("player"))
  
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  WhoDatDB.characters[key].events = WhoDatDB.characters[key].events or {}
  WhoDatDB.characters[key].events.groups = WhoDatDB.characters[key].events.groups or {}
  
  table.insert(WhoDatDB.characters[key].events.groups, composition)
  
  -- Limit storage
  local maxGroups = 500
  while #WhoDatDB.characters[key].events.groups > maxGroups do
    table.remove(WhoDatDB.characters[key].events.groups, 1)
  end
  
  -- Emit to EventBus
  if NS.EventBus and NS.EventBus.Emit then
    NS.EventBus:Emit("social", "group_formed", composition)
  end
  
  if NS.Log then
    NS.Log("INFO", "Group composition: %s (%d members)",
      composition.type, composition.size)
  end
end

-- ============================================================================
-- Friend List Tracking
-- ============================================================================

local function ScanFriendsList()
  local now = time()
  
  -- Don't scan too frequently
  if now - socialState.lastFriendsScan < 300 then  -- 5 minutes
    return
  end
  
  socialState.lastFriendsScan = now
  
  local friends = {}
  local numFriends = GetNumFriends()
  
  for i = 1, numFriends do
    local name, level, class, area, connected, status, note = GetFriendInfo(i)
    
    table.insert(friends, {
      name = name,
      level = level,
      class = class,
      zone = area,
      online = connected,
      note = note,
    })
  end
  
  -- Detect changes (additions/removals)
  local oldFriends = socialState.friends or {}
  local changes = DetectListChanges(oldFriends, friends, "name")
  
  -- Log changes
  if #changes.added > 0 or #changes.removed > 0 then
    LogFriendListChange(changes, friends)
  end
  
  -- Update cache
  socialState.friends = friends
  
  return friends
end

LogFriendListChange = function(changes, currentList)
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or (GetRealmName() .. ":" .. UnitName("player"))
  
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  WhoDatDB.characters[key].events = WhoDatDB.characters[key].events or {}
  WhoDatDB.characters[key].events.friends = WhoDatDB.characters[key].events.friends or {}
  
  for _, friend in ipairs(changes.added) do
    table.insert(WhoDatDB.characters[key].events.friends, {
      ts = time(),
      action = "added",
      name = friend.name,
      level = friend.level,
      class = friend.class,
      note = friend.note,
    })
  end
  
  for _, friend in ipairs(changes.removed) do
    table.insert(WhoDatDB.characters[key].events.friends, {
      ts = time(),
      action = "removed",
      name = friend.name,
    })
  end
  
  -- Also update snapshot
  WhoDatDB.characters[key].snapshots = WhoDatDB.characters[key].snapshots or {}
  WhoDatDB.characters[key].snapshots.friends = {
    ts = time(),
    count = #currentList,
    friends = currentList,
  }
  
  if NS.Log then
    NS.Log("INFO", "Friend list: +%d -%d (total: %d)",
      #changes.added, #changes.removed, #currentList)
  end
end

-- ============================================================================
-- Ignore List Tracking
-- ============================================================================

local function ScanIgnoreList()
  local now = time()
  
  -- Don't scan too frequently
  if now - socialState.lastIgnoreScan < 300 then  -- 5 minutes
    return
  end
  
  socialState.lastIgnoreScan = now
  
  local ignored = {}
  local numIgnored = GetNumIgnores()
  
  for i = 1, numIgnored do
    local name = GetIgnoreName(i)
    
    table.insert(ignored, {
      name = name,
    })
  end
  
  -- Detect changes
  local oldIgnored = socialState.ignored or {}
  local changes = DetectListChanges(oldIgnored, ignored, "name")
  
  -- Log changes
  if #changes.added > 0 or #changes.removed > 0 then
    LogIgnoreListChange(changes, ignored)
  end
  
  -- Update cache
  socialState.ignored = ignored
  
  return ignored
end

LogIgnoreListChange = function(changes, currentList)
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or (GetRealmName() .. ":" .. UnitName("player"))
  
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  WhoDatDB.characters[key].events = WhoDatDB.characters[key].events or {}
  WhoDatDB.characters[key].events.ignored = WhoDatDB.characters[key].events.ignored or {}
  
  for _, player in ipairs(changes.added) do
    table.insert(WhoDatDB.characters[key].events.ignored, {
      ts = time(),
      action = "added",
      name = player.name,
    })
  end
  
  for _, player in ipairs(changes.removed) do
    table.insert(WhoDatDB.characters[key].events.ignored, {
      ts = time(),
      action = "removed",
      name = player.name,
    })
  end
  
  -- Also update snapshot
  WhoDatDB.characters[key].snapshots = WhoDatDB.characters[key].snapshots or {}
  WhoDatDB.characters[key].snapshots.ignored = {
    ts = time(),
    count = #currentList,
    ignored = currentList,
  }
  
  if NS.Log then
    NS.Log("INFO", "Ignore list: +%d -%d (total: %d)",
      #changes.added, #changes.removed, #currentList)
  end
end

-- ============================================================================
-- Helper: Detect List Changes
-- ============================================================================

DetectListChanges = function(oldList, newList, keyField)
  local added = {}
  local removed = {}
  
  -- Safety checks
  if not oldList then oldList = {} end
  if not newList then newList = {} end
  if not keyField then keyField = "name" end
  
  -- Build lookup tables
  local oldMap = {}
  for _, item in ipairs(oldList) do
    if item and item[keyField] then  -- Safety check for nil
      oldMap[item[keyField]] = item
    end
  end
  
  local newMap = {}
  for _, item in ipairs(newList) do
    if item and item[keyField] then  -- Safety check for nil
      newMap[item[keyField]] = item
    end
  end
  
  -- Find added
  for key, item in pairs(newMap) do
    if not oldMap[key] then
      table.insert(added, item)
    end
  end
  
  -- Find removed
  for key, item in pairs(oldMap) do
    if not newMap[key] then
      table.insert(removed, item)
    end
  end
  
  return {
    added = added,
    removed = removed,
  }
end

-- ============================================================================
-- Event Registration
-- ============================================================================

local frame = CreateFrame("Frame")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("FRIENDLIST_UPDATE")
frame:RegisterEvent("IGNORELIST_UPDATE")

-- Periodic scan timer
local scanTimer = 0
frame:SetScript("OnUpdate", function(self, elapsed)
  scanTimer = scanTimer + elapsed
  
  if scanTimer >= 300 then  -- Every 5 minutes
    scanTimer = 0
    ScanFriendsList()
    ScanIgnoreList()
  end
end)

frame:SetScript("OnEvent", function(self, event, ...)
  if event == "GROUP_ROSTER_UPDATE" then
    OnGroupChanged()
    
  elseif event == "PLAYER_LOGIN" then
    ScanFriendsList()
    ScanIgnoreList()
    
  elseif event == "FRIENDLIST_UPDATE" then
    ScanFriendsList()
    
  elseif event == "IGNORELIST_UPDATE" then
    ScanIgnoreList()
  end
end)

-- ============================================================================
-- Public API
-- ============================================================================

function NS.Social_ScanFriends()
  return ScanFriendsList()
end

function NS.Social_ScanIgnored()
  return ScanIgnoreList()
end

function NS.Social_ScanGroup()
  return ScanGroupComposition()
end

-- ============================================================================
-- SQL Schema
-- ============================================================================

--[[
CREATE TABLE group_compositions (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  character_id BIGINT UNSIGNED NOT NULL,
  ts INT UNSIGNED NOT NULL,
  
  type ENUM('party', 'raid'),
  size TINYINT UNSIGNED,
  
  instance VARCHAR(128),
  instance_difficulty VARCHAR(64),
  
  zone VARCHAR(128),
  subzone VARCHAR(128),
  
  -- Members stored as JSON array
  members JSON,
  
  KEY idx_char_ts (character_id, ts),
  KEY idx_instance (instance),
  CONSTRAINT fk_group_char FOREIGN KEY (character_id)
    REFERENCES characters(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE friend_list_changes (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  character_id BIGINT UNSIGNED NOT NULL,
  ts INT UNSIGNED NOT NULL,
  
  action ENUM('added', 'removed'),
  friend_name VARCHAR(64),
  friend_level TINYINT UNSIGNED,
  friend_class VARCHAR(32),
  note TEXT,
  
  KEY idx_char_ts (character_id, ts),
  KEY idx_friend (friend_name),
  CONSTRAINT fk_friend_char FOREIGN KEY (character_id)
    REFERENCES characters(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE ignore_list_changes (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  character_id BIGINT UNSIGNED NOT NULL,
  ts INT UNSIGNED NOT NULL,
  
  action ENUM('added', 'removed'),
  ignored_name VARCHAR(64),
  
  KEY idx_char_ts (character_id, ts),
  CONSTRAINT fk_ignore_char FOREIGN KEY (character_id)
    REFERENCES characters(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
]]

-- ============================================================================
-- Analytics Queries
-- ============================================================================

--[[
-- Most frequent group members
SELECT 
  JSON_UNQUOTE(JSON_EXTRACT(member.value, '$.name')) as player_name,
  JSON_UNQUOTE(JSON_EXTRACT(member.value, '$.class')) as class,
  COUNT(*) as times_grouped
FROM group_compositions,
  JSON_TABLE(members, '$[*]' COLUMNS(
    value JSON PATH '$'
  )) as member
WHERE character_id = ?
GROUP BY player_name, class
ORDER BY times_grouped DESC
LIMIT 20;

-- Friend list growth over time
SELECT 
  DATE(FROM_UNIXTIME(ts)) as date,
  SUM(CASE WHEN action = 'added' THEN 1 ELSE 0 END) as added,
  SUM(CASE WHEN action = 'removed' THEN 1 ELSE 0 END) as removed
FROM friend_list_changes
WHERE character_id = ?
GROUP BY DATE(FROM_UNIXTIME(ts))
ORDER BY date;
]]

-- ============================================================================
-- Debug Commands
-- ============================================================================

SLASH_WDSOCIAL1 = "/wdsocial"
SlashCmdList["WDSOCIAL"] = function(msg)
  msg = (msg or ""):lower()
  
  if msg == "friends" then
    local friends = NS.Social_ScanFriends()
    print(string.format("=== Friends List (%d) ===", #friends))
    
    for _, friend in ipairs(friends) do
      print(string.format("%s (%d %s) - %s",
        friend.name,
        friend.level,
        friend.class,
        friend.online and "Online" or "Offline"))
    end
    
  elseif msg == "group" then
    local group = NS.Social_ScanGroup()
    
    if group then
      print(string.format("=== Group (%s, %d members) ===", group.type, group.size))
      
      for _, member in ipairs(group.members) do
        print(string.format("%s (%s, %s)",
          member.name,
          member.class,
          member.role))
      end
    else
      print("[WhoDAT] Not in a group")
    end
    
  elseif msg == "stats" then
    local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
      or (GetRealmName() .. ":" .. UnitName("player"))
    
    local char = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
    local groups = char and char.events and char.events.groups or {}
    
    print("=== Social Statistics ===")
    print(string.format("Groups recorded: %d", #groups))
    
    -- Count unique players
    local uniquePlayers = {}
    for _, group in ipairs(groups) do
      for _, member in ipairs(group.members or {}) do
        uniquePlayers[member.name] = true
      end
    end
    
    local playerCount = 0
    for _ in pairs(uniquePlayers) do
      playerCount = playerCount + 1
    end
    
    print(string.format("Unique players grouped with: %d", playerCount))
    
  else
    print("=== WhoDAT Social Tracker ===")
    print("/wdsocial friends - Scan and show friend list")
    print("/wdsocial group   - Show current group composition")
    print("/wdsocial stats   - Show social statistics")
  end
end

return NS