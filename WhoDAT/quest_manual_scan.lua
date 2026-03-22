-- WhoDAT Quest Manual Scan Tool
-- This provides slash commands to manually trigger quest scans
-- Add this to your WhoDAT addon folder and include it in WhoDAT.toc

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- Manual scan command
SLASH_WDQUESTSCAN1 = "/wdquestscan"
SLASH_WDQUESTSCAN2 = "/wdqs"
SlashCmdList["WDQUESTSCAN"] = function(msg)
  print("|cff00ff00[WhoDAT]|r Manually triggering quest scan...")
  
  -- First, make sure quest log is visible (this ensures API is ready)
  if not QuestLogFrame or not QuestLogFrame:IsVisible() then
    print("|cffffaa00[WhoDAT]|r Opening quest log...")
    if ToggleQuestLog then
      ToggleQuestLog()
    elseif ShowUIPanel then
      ShowUIPanel(QuestLogFrame)
    end
    
    -- Give it a moment to populate (WotLK compatible timer)
    local waitFrame = CreateFrame("Frame")
    local elapsed = 0
    waitFrame:SetScript("OnUpdate", function(self, delta)
      elapsed = elapsed + delta
      if elapsed >= 0.5 then
        waitFrame:SetScript("OnUpdate", nil)
        DoQuestScan()
      end
    end)
  else
    DoQuestScan()
  end
end

function DoQuestScan()
  if type(NS.Quests_ScanLog) == "function" then
    -- Reset throttle to force scan
    if NS._questsFrame then
      NS._questsFrame._lastScan = 0
    end
    
    local ok, err = pcall(NS.Quests_ScanLog)
    if ok then
      print("|cff00ff00[WhoDAT]|r Quest scan completed")
      
      -- Report results
      if WhoDatDB and WhoDatDB.characters then
        for k, v in pairs(WhoDatDB.characters) do
          if v.snapshots and v.snapshots.quest_log and v.snapshots.quest_log.quests then
            local count = #v.snapshots.quest_log.quests
            print(string.format("|cff00ff00[WhoDAT]|r Found %d quests in snapshot", count))
            
            -- List them
            for i, quest in ipairs(v.snapshots.quest_log.quests) do
              print(string.format("  [%d] %s (ID: %s, Complete: %s)", 
                i, quest.title or "?", tostring(quest.id), tostring(quest.complete)))
            end
          end
          
          if v.events and v.events.quests then
            print(string.format("|cff00ff00[WhoDAT]|r Total quest events logged: %d", #v.events.quests))
          end
          
          break -- Just first character
        end
      end
    else
      print("|cffff0000[WhoDAT]|r Error during scan: " .. tostring(err))
    end
  else
    print("|cffff0000[WhoDAT]|r NS.Quests_ScanLog function not found!")
  end
end

-- Command to show current quest log state
SLASH_WDQUESTSHOW1 = "/wdquestshow"
SLASH_WDQUESTSHOW2 = "/wdqsh"
SlashCmdList["WDQUESTSHOW"] = function(msg)
  print("|cff00ff00[WhoDAT]|r Current Quest Log State:")
  
  -- Check WoW API
  if type(GetNumQuestLogEntries) == "function" then
    local num, numQuests = GetNumQuestLogEntries()
    print(string.format("  WoW API reports: %d total entries, %s actual quests", 
      num or 0, tostring(numQuests)))
    
    if num and num > 0 and type(GetQuestLogTitle) == "function" then
      print("  Quest list:")
      for i = 1, num do
        local title, level, _, isHeader, _, isComplete, questID = GetQuestLogTitle(i)
        if not isHeader and title then
          print(string.format("    [%d] %s (ID: %s, Complete: %s)", 
            i, title, tostring(questID), tostring(isComplete)))
        end
      end
    end
  end
  
  -- Check WhoDAT database
  print("\n|cff00ff00[WhoDAT]|r Database State:")
  if WhoDatDB and WhoDatDB.characters then
    for k, v in pairs(WhoDatDB.characters) do
      print("  Character: " .. k)
      
      if v.snapshots and v.snapshots.quest_log then
        local ql = v.snapshots.quest_log
        local qcount = (ql.quests and #ql.quests) or 0
        print(string.format("    Snapshot: %d quests (ts: %s)", qcount, tostring(ql.ts)))
        
        if qcount > 0 then
          for i, quest in ipairs(ql.quests) do
            print(string.format("      [%d] %s (ID: %s)", i, quest.title or "?", tostring(quest.id)))
          end
        end
      else
        print("    No quest log snapshot")
      end
      
      if v.events and v.events.quests then
        print(string.format("    Events: %d quest events", #v.events.quests))
      else
        print("    No quest events")
      end
      
      break -- Just first character
    end
  else
    print("  WhoDatDB not initialized")
  end
end

-- Auto-scan on quest log open
local f = CreateFrame("Frame")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:SetScript("OnEvent", function(self, event)
  if event == "QUEST_LOG_UPDATE" then
    -- Only scan if quest log is actually open
    if QuestLogFrame and QuestLogFrame:IsVisible() then
      print("|cff00ff00[WhoDAT]|r Quest log updated, triggering scan...")
      DoQuestScan()
    end
  end
end)

print("|cff00ff00[WhoDAT]|r Quest scan tools loaded:")
print("  /wdquestscan or /wdqs - Manually scan quest log")
print("  /wdquestshow or /wdqsh - Show current state")
print("  Quest log will also auto-scan when you open it")