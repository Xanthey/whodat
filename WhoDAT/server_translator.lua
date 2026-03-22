-- server_translator.lua
-- WhoDAT - WotLK 3.3.5 Combat Log Translation System
-- With intelligent server detection via chat messages

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- Server detection patterns from advertising/system messages
local SERVER_PATTERNS = {
  Warmane = {
    "Warmane",
    "warmane%.com",
    "Donate and be rewarded with coins",
    "Icecrown",
  },
  Dalaran = {
    "Dalaran%-WoW",
    "dalaran%-wow%.com",
  },
  ChromieCraft = {
    "ChromieCraft",
    "chromiecraft%.com",
  },
  TurtleWoW = {
    "Turtle WoW",
    "turtle%-wow%.org",
  },
  -- Add more servers as needed
}

local detectedServer = nil
local detectionConfidence = "unknown"
local chatListenerActive = false

local function CheckChatForServer(message)
  if not message then return end
  
  message = message:lower()
  
  for serverName, patterns in pairs(SERVER_PATTERNS) do
    for _, pattern in ipairs(patterns) do
      if message:match(pattern:lower()) then
        if not detectedServer then
          detectedServer = serverName
          detectionConfidence = "chat_message"
          print(string.format("|cff00ff00[WhoDAT]|r %s server detected via chat message", serverName))
          print("|cff888888[WhoDAT]|r Detection method: server advertising")
          return serverName
        elseif detectedServer ~= serverName then
          print(string.format("|cffff8800[WhoDAT]|r Warning: Conflicting server detection! Was %s, now seeing %s", 
            detectedServer, serverName))
        end
        return serverName
      end
    end
  end
  
  return nil
end

local function StartChatListener()
  if chatListenerActive then return end
  chatListenerActive = true
  
  local frame = CreateFrame("Frame")
  
  -- Listen to common channels where server ads appear
  frame:RegisterEvent("CHAT_MSG_SYSTEM")
  frame:RegisterEvent("CHAT_MSG_CHANNEL")
  frame:RegisterEvent("PLAYER_ENTERING_WORLD")
  
  frame:SetScript("OnEvent", function(self, event, msg)
    if event == "PLAYER_ENTERING_WORLD" then
      -- Server ads often appear shortly after login
      -- Check realm name as fallback
      local realmName = GetRealmName()
      if realmName then
        CheckChatForServer(realmName)
      end
    elseif msg then
      CheckChatForServer(msg)
    end
  end)
end

-- Start listening immediately when this module loads
StartChatListener()

local function TranslateCombatLog(...)
  local args = {...}
  
  -- WotLK 3.3.5 COMBAT_LOG_EVENT_UNFILTERED passes:
  -- args[1] = event handler table (skip this!)
  -- args[2] = timestamp
  -- args[3] = event
  -- args[4] = srcGUID
  -- args[5] = srcName  
  -- args[6] = srcFlags
  -- args[7] = destGUID
  -- args[8] = destName
  -- args[9] = destFlags
  -- args[10+] = event-specific params
  
  local timestamp = args[2]
  local event = args[3]
  local srcGUID = args[4]
  local srcName = args[5]
  local srcFlags = args[6]
  local destGUID = args[7]
  local destName = args[8]
  local destFlags = args[9]
  
  -- WotLK doesn't have hideCaster or raidFlags params, so insert defaults
  local hideCaster = false
  local srcRaidFlags = 0
  local destRaidFlags = 0
  
  -- Get event-specific params (everything after destFlags)
  local extraParams = {}
  for i = 10, #args do
    extraParams[#extraParams + 1] = args[i]
  end
  
  -- Return in WhoDAT's expected format
  return timestamp, event, hideCaster,
         srcGUID, srcName, srcFlags, srcRaidFlags,
         destGUID, destName, destFlags, destRaidFlags,
         unpack(extraParams)
end

local function ExtractCreatureIDFromGUID(guid)
  if not guid or guid == "" then return nil end
  
  -- WotLK 3.3.5 hex GUID format: 0xF130XXXXXYYYYYYY
  -- Creature ID is in the middle portion
  if type(guid) == "string" and guid:match("^0x") then
    local hex = guid:gsub("^0x", "")
    if #hex >= 16 then
      -- For creature GUIDs like 0xF1300064A503AEFF
      -- The creature ID is typically in positions 5-10 or 7-12
      -- Try extracting from position 5-10 first (6 hex digits)
      local creatureIDHex = hex:sub(5, 10)
      local creatureID = tonumber(creatureIDHex, 16)
      
      -- Sanity check - creature IDs are usually < 100000
      if creatureID and creatureID > 0 and creatureID < 100000 then
        return creatureID
      end
      
      -- Try alternate position
      creatureIDHex = hex:sub(7, 12)
      creatureID = tonumber(creatureIDHex, 16)
      if creatureID and creatureID > 0 and creatureID < 100000 then
        return creatureID
      end
    end
  end
  
  return nil
end

local function TranslateGUID(guid, unitName)
  -- In WotLK, GUIDs are already in the correct format
  return guid
end

-- Manual server override (for testing or if detection fails)
local function SetServer(serverName)
  if SERVER_PATTERNS[serverName] then
    detectedServer = serverName
    detectionConfidence = "manual_override"
    print(string.format("|cff00ff00[WhoDAT]|r Server manually set to %s", serverName))
  else
    print(string.format("|cffff0000[WhoDAT]|r Unknown server name: %s", serverName))
    print("Available servers: " .. table.concat((function()
      local names = {}
      for name in pairs(SERVER_PATTERNS) do
        table.insert(names, name)
      end
      return names
    end)(), ", "))
  end
end

NS.ServerTranslator = {
  TranslateCombatLog = TranslateCombatLog,
  TranslateGUID = TranslateGUID,
  ExtractCreatureIDFromGUID = ExtractCreatureIDFromGUID,
  ExtractCreatureID = ExtractCreatureIDFromGUID,
  GetDetectedServerType = function() 
    return detectedServer or "WotLK"
  end,
  GetDetectionConfidence = function()
    return detectionConfidence
  end,
  SetServer = SetServer,
  ResetDetection = function() 
    detectedServer = nil
    detectionConfidence = "unknown"
  end,
}

-- Also create a slash command for manual override
SLASH_WHODAT_SERVER1 = "/whodatserver"
SlashCmdList.WHODAT_SERVER = function(msg)
  msg = msg:trim()
  if msg == "" then
    if detectedServer then
      print(string.format("|cff00ff00[WhoDAT]|r Current server: %s (confidence: %s)", 
        detectedServer, detectionConfidence))
    else
      print("|cff888888[WhoDAT]|r No server detected yet")
    end
  else
    SetServer(msg)
  end
end

print("|cff00ff00[WhoDAT]|r Server translator loaded - listening for server ads")
print("|cff888888[WhoDAT]|r Use /whodatserver to check or manually set server")