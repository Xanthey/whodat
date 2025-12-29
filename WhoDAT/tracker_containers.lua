-- WhoDAT - tracker_containers.lua (UNIFIED MODULE)
-- Replaces tracker_items.lua + tracker_inventory.lua
-- Single source of truth for all container tracking
-- Wrath 3.3.5a compatible

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

local U = NS.Utils

-- ============================================================================
-- Module State & Configuration
-- ============================================================================

NS.Containers = NS.Containers or {}
local Containers = NS.Containers

Containers._snapshots = {
  bags = {},
  bank = {},
  keyring = {},
  mailbox = {},
  equipment = {},
}

Containers._subscribers = {}
Containers._lastScan = {}

-- Throttle settings
local SCAN_THROTTLE = {
  bags = 2,      -- Max 1 scan per 2 seconds
  bank = 1,      -- Bank updates are rare
  keyring = 3,
  mailbox = 2,
  equipment = 1,
}

-- ============================================================================
-- Utility Functions
-- ============================================================================

local function now() return time() end

local function shouldThrottle(location)
  local last = Containers._lastScan[location] or 0
  local throttle = SCAN_THROTTLE[location] or 2
  if (now() - last) < throttle then return true end
  Containers._lastScan[location] = now()
  return false
end

local function safeGetItemMeta(link)
  if not link or not U or not U.GetItemMeta then return nil end
  local name, ilvl, _, _, _, _, _, _, _, icon, itemID = U.GetItemMeta(link)
  return name, ilvl, icon, itemID
end

local function normalizeIcon(icon, itemID, tex)
  if type(tex) == "string" and tex ~= "" then return tex end
  if itemID and type(GetItemIcon) == "function" then
    local path = GetItemIcon(itemID)
    if type(path) == "string" and path ~= "" then return path end
  end
  if type(icon) == "string" and icon ~= "" then return icon end
  return nil
end

local function getCharacterKey()
  return (U.GetPlayerKey and U.GetPlayerKey()) or (GetRealmName() .. ":" .. UnitName("player"))
end

local function ensureCharacter()
  local key = getCharacterKey()
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  
  -- Ensure character entry exists
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  local C = WhoDatDB.characters[key]
  
  -- ALWAYS ensure containers structure exists (migration-safe)
  C.containers = C.containers or {}
  C.containers.bags = C.containers.bags or {}
  C.containers.bank = C.containers.bank or {}
  C.containers.keyring = C.containers.keyring or {}
  C.containers.mailbox = C.containers.mailbox or {}
  
  -- Ensure other fields exist
  C.snapshots = C.snapshots or {}
  C.events = C.events or {}
  C.events.items = C.events.items or {}
  
  return key, C
end

-- ============================================================================
-- Subscriber Pattern (Event Bus Integration)
-- ============================================================================

function Containers:Subscribe(callback)
  if type(callback) == "function" then
    table.insert(self._subscribers, callback)
  end
end

function Containers:_emit(location, diffs)
  for _, subscriber in ipairs(self._subscribers) do
    local ok, err = pcall(subscriber, location, diffs)
    if not ok and NS.Log then
      NS.Log("ERROR", "Container subscriber error: %s", tostring(err))
    end
  end
end

-- ============================================================================
-- Diff Algorithm (itemID-based aggregation)
-- ============================================================================

local function indexByItemId(list)
  local map = {}
  for _, item in ipairs(list or {}) do
    local id = item.id and tonumber(item.id) or nil
    local count = tonumber(item.count) or 1
    if id then
      map[id] = (map[id] or 0) + count
    end
  end
  return map
end

function Containers:_diff(oldList, newList)
  local oldMap = indexByItemId(oldList)
  local newMap = indexByItemId(newList)
  local diffs = {}
  
  -- Added or increased
  for id, newCount in pairs(newMap) do
    local oldCount = oldMap[id] or 0
    if newCount ~= oldCount then
      table.insert(diffs, {
        item_id = id,
        delta = newCount - oldCount,
        action = (newCount > oldCount) and "added" or "removed"
      })
    end
  end
  
  -- Removed
  for id, oldCount in pairs(oldMap) do
    if not newMap[id] then
      table.insert(diffs, {
        item_id = id,
        delta = -oldCount,
        action = "removed"
      })
    end
  end
  
  return diffs
end

-- ============================================================================
-- Bag Scanning
-- ============================================================================

function Containers:ScanBags()
  if shouldThrottle("bags") then return end
  
  local key, C = ensureCharacter()
  local bags = C.containers.bags
  wipe(bags)
  
  local flatList = {}
  
  for bagID = 0, 4 do
    local name = (bagID == 0) and "Backpack" or ("Bag " .. bagID)
    local slots = (GetContainerNumSlots and GetContainerNumSlots(bagID)) or 0
    local bagEntry = { bag_id = bagID, name = name, slots = slots, contents = {} }
    
    for slot = 1, slots do
      local link = GetContainerItemLink and GetContainerItemLink(bagID, slot)
      if link then
        local tex, count = nil, 1
        if GetContainerItemInfo then
          tex, count = GetContainerItemInfo(bagID, slot)
        end
        
        local nameMeta, ilvl, iconMeta, itemID = safeGetItemMeta(link)
        local item = {
          link = link,
          id = itemID,
          name = nameMeta,
          ilvl = ilvl,
          icon = normalizeIcon(iconMeta, itemID, tex),
          count = count or 1,
          location = "bags"
        }
        
        table.insert(bagEntry.contents, item)
        table.insert(flatList, item)
      end
    end
    
    table.insert(bags, bagEntry)
  end
  
  -- Calculate diffs
  local diffs = self:_diff(self._snapshots.bags, flatList)
  self._snapshots.bags = flatList
  
  -- Emit to subscribers
  if #diffs > 0 then
    self:_emit("bags", diffs)
  end
end

-- ============================================================================
-- Bank Scanning
-- ============================================================================

function Containers:ScanBank()
  if shouldThrottle("bank") then return end
  
  local key, C = ensureCharacter()
  local bank = C.containers.bank
  wipe(bank)
  
  local flatList = {}
  
  -- Main bank container
  local main = { bag_id = -1, name = "Bank Main", slots = 28, contents = {} }
  table.insert(bank, main)
  
  -- Bank bags (5-11)
  for bagID = 5, 11 do
    local name = "Bank Bag " .. (bagID - 4)
    local slots = (GetContainerNumSlots and GetContainerNumSlots(bagID)) or 0
    local bagEntry = { bag_id = bagID, name = name, slots = slots, contents = {} }
    
    for slot = 1, slots do
      local link = GetContainerItemLink and GetContainerItemLink(bagID, slot)
      if link then
        local tex, count = nil, 1
        if GetContainerItemInfo then
          tex, count = GetContainerItemInfo(bagID, slot)
        end
        
        local nameMeta, ilvl, iconMeta, itemID = safeGetItemMeta(link)
        local item = {
          link = link,
          id = itemID,
          name = nameMeta,
          ilvl = ilvl,
          icon = normalizeIcon(iconMeta, itemID, tex),
          count = count or 1,
          location = "bank"
        }
        
        table.insert(bagEntry.contents, item)
        table.insert(flatList, item)
      end
    end
    
    table.insert(bank, bagEntry)
  end
  
  -- Calculate diffs
  local diffs = self:_diff(self._snapshots.bank, flatList)
  self._snapshots.bank = flatList
  
  -- Emit to subscribers
  if #diffs > 0 then
    self:_emit("bank", diffs)
  end
end

-- ============================================================================
-- Keyring Scanning
-- ============================================================================

function Containers:ScanKeyring()
  if shouldThrottle("keyring") then return end
  
  local hasKeyring = (type(HasKey) == "function" and HasKey()) or false
  if not hasKeyring or not KeyRingButtonIDToInvSlotID then return end
  
  local key, C = ensureCharacter()
  local keyring = C.containers.keyring
  wipe(keyring)
  
  local flatList = {}
  local ringEntry = { bag_id = -2, name = "Keyring", slots = 32, contents = {} }
  
  for btn = 1, 32 do
    local slot = KeyRingButtonIDToInvSlotID(btn)
    if slot then
      local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
      if link then
        local tex = GetInventoryItemTexture and GetInventoryItemTexture("player", slot)
        local count = GetInventoryItemCount and GetInventoryItemCount("player", slot)
        
        local nameMeta, ilvl, iconMeta, itemID = safeGetItemMeta(link)
        local item = {
          link = link,
          id = itemID,
          name = nameMeta,
          ilvl = ilvl,
          icon = normalizeIcon(iconMeta, itemID, tex),
          count = count or 1,
          location = "keyring"
        }
        
        table.insert(ringEntry.contents, item)
        table.insert(flatList, item)
      end
    end
  end
  
  table.insert(keyring, ringEntry)
  
  -- Calculate diffs
  local diffs = self:_diff(self._snapshots.keyring, flatList)
  self._snapshots.keyring = flatList
  
  -- Emit to subscribers
  if #diffs > 0 then
    self:_emit("keyring", diffs)
  end
end

-- ============================================================================
-- Mailbox Scanning
-- ============================================================================

local function isIconPath(s)
  return type(s) == "string" and s:find("Interface\\Icons\\", 1, true) ~= nil
end

local function unpackInboxHeader(i)
  local r1, r2, r3, r4, r5, r6, r7, r8, r9 = GetInboxHeaderInfo(i)
  
  local icon1 = isIconPath(r1)
  local icon2 = isIconPath(r2)
  
  local packageIcon, stationeryIcon, sender, subject, money, COD, daysLeft, hasItem, wasRead
  
  if icon1 or icon2 then
    packageIcon = icon1 and r1 or nil
    stationeryIcon = icon2 and r2 or nil
    sender, subject, money, COD, daysLeft, hasItem, wasRead = r3, r4, r5, r6, r7, r8, r9
  else
    packageIcon, stationeryIcon = nil, nil
    sender, subject, money, COD, daysLeft, hasItem, wasRead = r1, r2, r3, r4, r5, r6, r7
  end
  
  if isIconPath(sender) then sender = "" end
  if isIconPath(subject) then subject = "" end
  
  money = tonumber(money) or 0
  COD = tonumber(COD) or 0
  daysLeft = tonumber(daysLeft) or 0
  local wasReadBool = (wasRead == 1 or wasRead == true)
  
  return packageIcon, stationeryIcon, sender or "", subject or "", money, COD, daysLeft, hasItem, wasReadBool
end

function Containers:ScanMailbox()
  if shouldThrottle("mailbox") then return end
  if type(GetInboxNumItems) ~= "function" then return end
  
  local key, C = ensureCharacter()
  local mailbox = C.containers.mailbox
  wipe(mailbox)
  
  local flatList = {}
  local numMail = GetInboxNumItems() or 0
  
  for i = 1, numMail do
    local packageIcon, stationeryIcon, sender, subject, money, COD, daysLeft, hasItem, wasRead = 
      unpackInboxHeader(i)
    
    local entry = {
      mail_index = i,
      package_icon = packageIcon,
      stationery_icon = stationeryIcon,
      sender = sender,
      subject = subject,
      money = money,
      cod = COD,
      days_left = daysLeft,
      was_read = wasRead,
      attachments = {}
    }
    
    -- Scan attachments
    for a = 1, 12 do
      local link = GetInboxItemLink and GetInboxItemLink(i, a)
      if not link or link == "" then break end
      
      local ai_name, ai_tex, ai_count = nil, nil, 1
      if GetInboxItem then
        ai_name, ai_tex, ai_count = GetInboxItem(i, a)
      end
      
      local nameMeta, ilvl, iconMeta, itemID = safeGetItemMeta(link)
      local item = {
        link = link,
        id = itemID,
        name = nameMeta or ai_name,
        ilvl = ilvl,
        icon = normalizeIcon(iconMeta, itemID, ai_tex),
        count = ai_count or 1,
        location = "mailbox"
      }
      
      table.insert(entry.attachments, item)
      table.insert(flatList, item)
    end
    
    table.insert(mailbox, entry)
  end
  
  -- Calculate diffs
  local diffs = self:_diff(self._snapshots.mailbox, flatList)
  self._snapshots.mailbox = flatList
  
  -- Emit to subscribers
  if #diffs > 0 then
    self:_emit("mailbox", diffs)
  end
end

-- ============================================================================
-- Equipment Scanning
-- ============================================================================

local INV_SLOTS = {
  "HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot", "ShirtSlot", "TabardSlot",
  "WristSlot", "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot",
  "Finger0Slot", "Finger1Slot", "Trinket0Slot", "Trinket1Slot",
  "MainHandSlot", "SecondaryHandSlot", "RangedSlot",
}

function Containers:ScanEquipment()
  if shouldThrottle("equipment") then return end
  
  local key, C = ensureCharacter()
  local slots = {}
  
  for _, slotName in ipairs(INV_SLOTS) do
    local slotId = GetInventorySlotInfo and GetInventorySlotInfo(slotName)
    if slotId then
      local link = GetInventoryItemLink and GetInventoryItemLink("player", slotId)
      if link then
        local count = GetInventoryItemCount and GetInventoryItemCount("player", slotId)
        local tex = GetInventoryItemTexture and GetInventoryItemTexture("player", slotId)
        
        local nameMeta, ilvl, iconMeta, itemID = safeGetItemMeta(link)
        slots[slotName:gsub("Slot", "")] = {
          link = link,
          id = itemID,
          icon = normalizeIcon(iconMeta, itemID, tex),
          ilvl = ilvl,
          count = count or 1,
          name = nameMeta
        }
      else
        slots[slotName:gsub("Slot", "")] = nil
      end
    end
  end
  
  -- Save snapshot
  C.snapshots.equipment = {
    ts = now(),
    slots = slots
  }
  
  -- Emit equipment changes (simplified - could add detailed slot diffs)
  local diffs = {}
  for slotName, item in pairs(slots) do
    local oldItem = self._snapshots.equipment[slotName]
    if not oldItem or (oldItem.id ~= item.id) then
      table.insert(diffs, {
        slot = slotName,
        item_id = item.id,
        action = "equipped"
      })
    end
  end
  
  self._snapshots.equipment = slots
  
  if #diffs > 0 then
    self:_emit("equipment", diffs)
  end
end

-- ============================================================================
-- Event Registration
-- ============================================================================

function Containers:RegisterEvents(frame)
  frame:RegisterEvent("BAG_UPDATE")
  frame:RegisterEvent("BANKFRAME_OPENED")
  frame:RegisterEvent("MAIL_INBOX_UPDATE")
  frame:RegisterEvent("UNIT_INVENTORY_CHANGED")
  
  frame:HookScript("OnEvent", function(_, event, ...)
    if event == "BAG_UPDATE" then
      Containers:ScanBags()
    elseif event == "BANKFRAME_OPENED" then
      Containers:ScanBank()
    elseif event == "MAIL_INBOX_UPDATE" then
      Containers:ScanMailbox()
    elseif event == "UNIT_INVENTORY_CHANGED" and (...) == "player" then
      Containers:ScanEquipment()
    end
  end)
end

-- ============================================================================
-- Public API
-- ============================================================================

function NS.Containers_ScanAll()
  Containers:ScanBags()
  Containers:ScanEquipment()
  Containers:ScanKeyring()
  Containers:ScanMailbox()
end

-- Subscribe to container events
Containers:Subscribe(function(location, diffs)
  -- Log events via global event bus
  for _, diff in ipairs(diffs) do
    if type(WhoDAT_LogEvent) == "function" then
      WhoDAT_LogEvent("container", diff.action, {
        location = location,
        item_id = diff.item_id,
        delta = diff.delta
      })
    end
  end
end)

return Containers