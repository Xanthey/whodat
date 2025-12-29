-- tracker_item_lifecycle.lua
-- WhoDAT - Comprehensive Item Lifecycle Tracker
-- Tracks ALL item interactions: loot, vendor sales, mail, auctions, quest rewards, etc.
-- Provides complete item history for "what happened to my item" queries

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

local U = NS.Utils

-- ============================================================================
-- State
-- ============================================================================

local currentTarget = nil
local currentZone = nil
local currentSubzone = nil
local merchantName = nil
local merchantOpen = false
local lastSoldItems = {}
local mailTracked = {}

-- Track bag snapshots to detect item removal
local lastBagSnapshot = {}

-- ============================================================================
-- Helpers
-- ============================================================================

local function now() return time() end

local function getCurrentZone()
  return GetRealZoneText() or GetZoneText() or "Unknown"
end

local function getCurrentSubzone()
  return GetSubZoneText() or ""
end

local function getSessionId()
  if NS.Session and NS.Session.current then
    return NS.Session.current.session_id
  end
  return nil
end

local function getCharacterKey()
  return (U and U.GetPlayerKey and U.GetPlayerKey()) 
    or (GetRealmName() .. ":" .. UnitName("player") .. ":" .. select(2, UnitClass("player")))
end

-- ============================================================================
-- Event Emission
-- ============================================================================

local function emitItemEvent(action, itemData, context)
  if not itemData then return end
  
  local payload = {
    _ts = now(),
    _session_id = getSessionId(),
    action = action,
    source = itemData.source or "unknown",
    location = itemData.location or "bags",
    link = itemData.link,
    item_string = itemData.link,
    item_id = itemData.item_id,
    name = itemData.name,
    count = itemData.count or 1,
    ilvl = itemData.ilvl,
    icon = itemData.icon,
    sale_price = itemData.sale_price,
    context = context or {},
  }
  
  -- Emit to EventBus
  if NS.EventBus and NS.EventBus.Emit then
    NS.EventBus:Emit("items", action, payload)
  end
  
  -- Also write directly to SavedVariables (fallback)
  local key = getCharacterKey()
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  
  local C = WhoDatDB.characters[key]
  C.events = C.events or {}
  C.events.items = C.events.items or {}
  
  table.insert(C.events.items, payload)
end

local function parseItemInfo(itemLink)
  if not itemLink then return nil end
  
  local name, _, _, ilvl, _, _, _, _, _, icon = GetItemInfo(itemLink)
  local item_id = itemLink:match("|Hitem:(%d+):")
  item_id = item_id and tonumber(item_id) or nil
  
  return {
    link = itemLink,
    item_id = item_id,
    name = name,
    ilvl = ilvl,
    icon = icon,
  }
end

-- ============================================================================
-- 1. LOOT TRACKING
-- ============================================================================

local function onLootOpened()
  -- Capture current target (the mob being looted)
  if UnitExists("target") and UnitIsDead("target") then
    currentTarget = UnitName("target")
  else
    currentTarget = nil
  end
  
  currentZone = getCurrentZone()
  currentSubzone = getCurrentSubzone()
end

local function onLootClosed()
  currentTarget = nil
end

local function parseLootMessage(msg)
  -- Patterns for loot messages
  local link, count
  
  -- Pattern 1: "You receive item: [link]" or "You receive item: [link] x3"
  link, count = msg:match("You receive item: (.+)%.?%s*x?(%d*)")
  if link then
    count = tonumber(count) or 1
    return link, count
  end
  
  -- Pattern 2: "You receive loot: [link] x3"
  link, count = msg:match("You receive loot: (.+)%s*x(%d+)")
  if link then
    return link, tonumber(count) or 1
  end
  
  -- Pattern 3: "You receive loot: [link]"
  link = msg:match("You receive loot: (.+)")
  if link then
    return link, 1
  end
  
  -- Pattern 4: Any item link in the message
  link = msg:match("(|c%x+|Hitem:.+|r)")
  if link then
    count = msg:match("x(%d+)") or msg:match("×(%d+)")
    return link, tonumber(count) or 1
  end
  
  return nil, nil
end

local function onChatMsgLoot(msg)
  if not msg then return end
  
  -- Only track player's own loot
  if not msg:match("^You receive") and not msg:match("^You loot") then
    return
  end
  
  local itemLink, count = parseLootMessage(msg)
  if not itemLink then return end
  
  local itemData = parseItemInfo(itemLink)
  if not itemData then return end
  
  itemData.count = count
  itemData.source = "loot"
  itemData.location = "bags"
  
  local context = {
    zone = currentZone,
  }
  
  if currentSubzone and currentSubzone ~= "" then
    context.subzone = currentSubzone
  end
  
  if currentTarget then
    context.mob = currentTarget
  end
  
  emitItemEvent("obtained", itemData, context)
end

-- ============================================================================
-- 2. VENDOR TRACKING (Sales)
-- ============================================================================

local function onMerchantShow()
  merchantOpen = true
  merchantName = UnitName("npc") or UnitName("target") or "Unknown Merchant"
  currentZone = getCurrentZone()
  lastSoldItems = {}
end

local function onMerchantClosed()
  merchantOpen = false
  merchantName = nil
  lastSoldItems = {}
end

-- Track item sales via chat message
local function onChatMsgMoney(msg)
  if not merchantOpen then return end
  
  -- "You sell [Item Link] for 5g 50s 25c"
  -- "You sell [Item Link]"
  
  local itemLink = msg:match("You sell (.+) for")
  if not itemLink then
    itemLink = msg:match("You sell (.+)")
  end
  
  if not itemLink then return end
  
  -- Extract price
  local gold = msg:match("(%d+)g") or "0"
  local silver = msg:match("(%d+)s") or "0"
  local copper = msg:match("(%d+)c") or "0"
  
  local totalCopper = (tonumber(gold) * 10000) + (tonumber(silver) * 100) + tonumber(copper)
  
  local itemData = parseItemInfo(itemLink)
  if not itemData then return end
  
  itemData.source = "vendor"
  itemData.location = "vendor"
  itemData.count = 1
  itemData.sale_price = totalCopper
  
  local context = {
    npc = merchantName,
    zone = currentZone,
    price_copper = totalCopper,
  }
  
  emitItemEvent("sold", itemData, context)
end

-- ============================================================================
-- 3. MAIL TRACKING
-- ============================================================================

local function onMailShow()
  mailTracked = {}
  
  local numItems = GetInboxNumItems()
  
  for i = 1, numItems do
    local packageIcon, stationeryIcon, sender, subject, money, CODAmount, 
          daysLeft, hasItem, wasRead, wasReturned, textCreated, canReply, 
          isGM = GetInboxHeaderInfo(i)
    
    if hasItem then
      for j = 1, ATTACHMENTS_MAX_RECEIVE do
        local name, itemTexture, count, quality, canUse = GetInboxItem(i, j)
        
        if name then
          local link = GetInboxItemLink(i, j)
          
          if link and not mailTracked[link] then
            mailTracked[link] = true
            
            local itemData = parseItemInfo(link)
            if itemData then
              itemData.count = count or 1
              itemData.location = "mail"
              
              -- Determine source type
              local source = "mail"
              if subject then
                if subject:match("Auction") then
                  if subject:match("won") or subject:match("outbid") then
                    source = "auction"
                  elseif subject:match("expired") or subject:match("cancelled") then
                    source = "mail"
                  elseif subject:match("sold") then
                    source = "auction"
                  end
                end
              end
              
              if sender == UnitName("player") then
                source = "self_mail"
              end
              
              itemData.source = source
              
              local context = {
                subject = subject,
                from = sender,
              }
              
              -- Determine action
              local action = "mailed_received"
              if subject and subject:match("won") then
                action = "auction_won"
              elseif subject and subject:match("sold") then
                action = "auction_sold"
              elseif subject and subject:match("expired") then
                action = "auction_expired"
              end
              
              emitItemEvent(action, itemData, context)
            end
          end
        end
      end
    end
  end
end

-- ============================================================================
-- 4. AUCTION HOUSE TRACKING
-- ============================================================================

local function onChatMsgSystem(msg)
  if not msg then return end
  
  -- "A buyer has been found for your auction of [Item Link]"
  -- "Your auction of [Item Link] sold"
  local itemLink = msg:match("auction of (.+) sold") or msg:match("auction of (.+)%.")
  
  if itemLink then
    local itemData = parseItemInfo(itemLink)
    if itemData then
      itemData.source = "auction"
      itemData.location = "auction_house"
      itemData.count = 1
      
      local context = {
        system = true,
      }
      
      emitItemEvent("auction_sold", itemData, context)
    end
    return
  end
  
  -- "You won an auction for [Item Link]"
  itemLink = msg:match("You won an auction for (.+)")
  
  if itemLink then
    local itemData = parseItemInfo(itemLink)
    if itemData then
      itemData.source = "auction"
      itemData.location = "auction_house"
      itemData.count = 1
      
      local context = {
        system = true,
      }
      
      emitItemEvent("auction_won", itemData, context)
    end
  end
end

-- ============================================================================
-- 5. QUEST REWARDS
-- ============================================================================

-- Track quest rewards when player actually receives them
-- Note: QUEST_COMPLETE fires when dialog opens, not when reward is chosen
-- We need to track via QUEST_FINISHED or chat messages instead

local questRewardPending = nil

local function onQuestComplete()
  -- When quest complete dialog opens, store available rewards for later
  -- Don't try to get the chosen reward yet - player hasn't chosen!
  
  local questTitle = GetTitleText()
  
  -- Store info about available rewards
  questRewardPending = {
    title = questTitle,
    ts = time(),
  }
end

local function onQuestFinished()
  -- This fires after player clicks "Complete Quest" button
  -- At this point the reward has been chosen and given
  
  -- Quest rewards are typically tracked by tracker_quests.lua in quest_rewards events
  -- This tracker focuses on the item lifecycle aspect
  
  questRewardPending = nil
end

-- Alternative: Track via chat message when quest reward is received
local function onChatMsgLootQuest(msg)
  -- "You receive item: [Item Link]" from quest
  local itemLink = msg:match("|c%x+|Hitem:.+|r")
  
  if itemLink and questRewardPending then
    local itemData = parseItemInfo(itemLink)
    if itemData then
      itemData.count = 1
      itemData.source = "quest"
      itemData.location = "bags"
      
      local context = {
        quest = questRewardPending.title,
        reward_type = "choice",
      }
      
      emitItemEvent("obtained", itemData, context)
    end
  end
end

-- ============================================================================
-- 6. ITEM DELETION/DESTRUCTION
-- ============================================================================

-- Note: WoW doesn't provide a direct event for item deletion
-- We'd need to track bag changes and compare snapshots
-- This is complex and may be handled by tracker_containers.lua instead

-- ============================================================================
-- Event Registration
-- ============================================================================

function NS.ItemLifecycle_RegisterEvents(frame)
  if not frame or not frame.RegisterEvent then return end
  
  -- Loot events
  frame:RegisterEvent("LOOT_OPENED")
  frame:RegisterEvent("LOOT_CLOSED")
  frame:RegisterEvent("CHAT_MSG_LOOT")
  
  -- Vendor events
  frame:RegisterEvent("MERCHANT_SHOW")
  frame:RegisterEvent("MERCHANT_CLOSED")
  frame:RegisterEvent("CHAT_MSG_MONEY")
  
  -- Mail events
  frame:RegisterEvent("MAIL_SHOW")
  frame:RegisterEvent("MAIL_INBOX_UPDATE")
  
  -- System messages (auctions, etc.)
  frame:RegisterEvent("CHAT_MSG_SYSTEM")
  
  -- Quest events
  frame:RegisterEvent("QUEST_COMPLETE")
  frame:RegisterEvent("QUEST_FINISHED")
  
  frame:HookScript("OnEvent", function(self, event, ...)
    if event == "LOOT_OPENED" then
      onLootOpened()
      
    elseif event == "LOOT_CLOSED" then
      onLootClosed()
      
    elseif event == "CHAT_MSG_LOOT" then
      local msg = ...
      -- Check if this is quest loot
      if msg and msg:match("You receive item") then
        onChatMsgLootQuest(msg)
      end
      onChatMsgLoot(msg)
      
    elseif event == "MERCHANT_SHOW" then
      onMerchantShow()
      
    elseif event == "MERCHANT_CLOSED" then
      onMerchantClosed()
      
    elseif event == "CHAT_MSG_MONEY" then
      local msg = ...
      onChatMsgMoney(msg)
      
    elseif event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE" then
      onMailShow()
      
    elseif event == "CHAT_MSG_SYSTEM" then
      local msg = ...
      onChatMsgSystem(msg)
      
    elseif event == "QUEST_COMPLETE" then
      onQuestComplete()
      
    elseif event == "QUEST_FINISHED" then
      onQuestFinished()
    end
  end)
  
  if NS.Log then
    NS.Log("INFO", "Item lifecycle tracking initialized")
  end
end

-- ============================================================================
-- Zone Change Tracking
-- ============================================================================

function NS.ItemLifecycle_OnZoneChanged()
  currentZone = getCurrentZone()
  currentSubzone = getCurrentSubzone()
end

return NS