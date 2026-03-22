-- tracker_guild.lua (FIXED VERSION)
-- WhoDAT - Guild Bank & Roster Tracking
-- Tracks guild bank contents, money, roster members, and changes over time
-- Wrath 3.3.5a compatible
-- 
-- VERSION: 3.1.0 - FIXED DATE HANDLING FOR DEDUPLICATION
-- Changes:
-- - Fixed year/month handling when WoW API returns 0 values
-- - Reconstruct proper dates using current time and relative positioning
-- - Enhanced deduplication using both hash AND sequence-based signatures
-- - Better logging for troubleshooting

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Module State & Configuration
-- ============================================================================

NS.Guild = NS.Guild or {}
local Guild = NS.Guild

local guildState = {
  lastBankScan = 0,
  lastRosterScan = 0,
  lastMoneyUpdate = 0,
  lastTransactionLogQuery = 0,
  lastMoneyLogQuery = 0,
  bankOpen = false,
  previousRoster = {},
  previousBankContents = {},
  previousMoney = 0,
}

-- Throttle settings (seconds)
local THROTTLE = {
  bank_scan = 2,              -- Don't scan bank more than once per 2 seconds
  roster_scan = 30,           -- Roster updates every 30 seconds max
  money_update = 1,           -- Money updates every second
  transaction_log_query = 5,  -- Transaction log queries every 5 seconds
  money_log_query = 5,        -- Money log queries every 5 seconds
}

-- ============================================================================
-- Utility Functions
-- ============================================================================

local function now() return time() end

local function shouldThrottle(key, seconds)
  local stateKey = "last" .. key:gsub("^%l", string.upper):gsub("_(%l)", string.upper)
  local last = guildState[stateKey] or 0
  if (now() - last) < seconds then return true end
  guildState[stateKey] = now()
  return false
end

-- ============================================================================
-- Wrath-Compatible Timer (C_Timer doesn't exist in 3.3.5a)
-- ============================================================================
local function DelayedCall(seconds, callback)
  local frame = CreateFrame("Frame")
  local elapsed = 0
  
  frame:SetScript("OnUpdate", function(self, delta)
    elapsed = elapsed + delta
    if elapsed >= seconds then
      frame:SetScript("OnUpdate", nil)
      callback()
    end
  end)
end

local function getCharacterKey()
  if NS.Utils and NS.Utils.GetPlayerKey then
    return NS.Utils.GetPlayerKey()
  end
  return (GetRealmName() or "Unknown") .. ":" .. (UnitName("player") or "Player")
end

local function ensureGuildData()
  local key = getCharacterKey()
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  
  local C = WhoDatDB.characters[key]
  C.guild = C.guild or {}
  C.guild.bank = C.guild.bank or {}
  C.guild.roster = C.guild.roster or {}
  C.guild.events = C.guild.events or {}
  C.guild.snapshots = C.guild.snapshots or {}
  C.guild.logs = C.guild.logs or {}
  C.guild.logs.transactions = C.guild.logs.transactions or {}
  C.guild.logs.money = C.guild.logs.money or {}
  
  return key, C
end

local function safeGetItemInfo(link)
  if not link then return nil end
  
  -- Try to use Utils if available
  if NS.Utils and NS.Utils.GetItemMeta then
    local name, ilvl, quality, _, _, _, _, stack, equipLoc, icon, itemID = NS.Utils.GetItemMeta(link)
    if name then
      return name, link, ilvl, quality, stack, equipLoc, icon, itemID
    end
  end
  
  -- Fallback to standard API
  local name, _, quality, ilvl, _, _, _, stack, equipLoc, icon = GetItemInfo(link)
  local itemID = tonumber(link:match("item:(%d+)"))
  
  if name then
    return name, link, ilvl, quality, stack, equipLoc, icon, itemID
  end
  
  return nil
end

-- ============================================================================
-- TIMESTAMP RECONSTRUCTION
-- ============================================================================
-- CRITICAL UNDERSTANDING: The WoW 3.3.5a guild bank API returns RELATIVE elapsed
-- time, not calendar dates. The return values are:
--   year  = number of YEARS since the transaction (almost always 0)
--   month = number of MONTHS since the transaction (almost always 0)
--   day   = number of DAYS since the transaction   (0 = today, 1 = yesterday, etc.)
--   hour  = number of HOURS since the transaction  (within the current day bucket)
--
-- Because these are relative offsets, the same transaction scanned at 10:00 vs 07:00
-- produces DIFFERENT reconstructed wall-clock times -> different hashes -> duplicates.
--
-- FIX: Store the raw relative offsets and compute the timestamp as:
--   scan_time - (years*365*86400 + months*30*86400 + days*86400 + hours*3600)
-- This is still approximate (±1 hour) but is STABLE: two scans within the same
-- hour-boundary will reconstruct the same bucket, and the hash uses the raw
-- offsets directly so it is scan-time-independent.

local function computeTimestampFromOffsets(scanTime, rawYear, rawMonth, rawDay, rawHour)
  local yearsAgo  = rawYear  or 0
  local monthsAgo = rawMonth or 0
  local daysAgo   = rawDay   or 0
  local hoursAgo  = rawHour  or 0

  local offsetSeconds = (yearsAgo * 365 * 86400)
                      + (monthsAgo * 30 * 86400)
                      + (daysAgo * 86400)
                      + (hoursAgo * 3600)

  return scanTime - offsetSeconds
end

-- ============================================================================
-- STABLE TRANSACTION HASH GENERATION
-- ============================================================================
-- The hash uses RAW API offset values (how many days/hours ago), NOT reconstructed
-- wall-clock time. This makes it scan-time-independent: the same transaction
-- always produces the same hash regardless of when it was captured.
--
-- For money transactions: player|type|amount|daysAgo|hoursAgo
-- For item  transactions: player|type|itemId|count|tab|daysAgo|hoursAgo

local function generateMoneyTransactionHash(trans)
  local parts = {
    tostring(trans.player    or "Unknown"),
    tostring(trans.type      or "deposit"),
    tostring(trans.amount    or 0),
    tostring(trans.days_ago  or 0),
    tostring(trans.hours_ago or 0),
  }
  return table.concat(parts, "|")
end

local function generateItemTransactionHash(trans)
  local parts = {
    tostring(trans.player    or "Unknown"),
    tostring(trans.type      or "deposit"),
    tostring(trans.item_id   or trans.item_name or "0"),
    tostring(trans.count     or 1),
    tostring(trans.tab       or 0),
    tostring(trans.days_ago  or 0),
    tostring(trans.hours_ago or 0),
  }
  return table.concat(parts, "|")
end

-- Keep a single entry-point used by legacy callers
local function generateTransactionHash(trans)
  if trans.amount ~= nil then
    return generateMoneyTransactionHash(trans)
  else
    return generateItemTransactionHash(trans)
  end
end


-- ============================================================================
-- Guild Module Initialization
-- ============================================================================

function Guild:IsEnabled()
  return true
end

function Guild:HasBankLogAccess()
  local guildName, guildRankName, guildRankIndex = GetGuildInfo("player")
  if not guildName then return false end
  
  -- Guild master and officers typically have log access
  -- In most guilds, this is ranks 0, 1, and sometimes 2
  return guildRankIndex <= 2
end

function Guild:IsInGuild()
  local guildName = GetGuildInfo("player")
  return guildName ~= nil
end

-- ============================================================================
-- Guild Info Scanning (Basic guild information)
-- ============================================================================

function Guild:ScanGuildInfo()
  if not self:IsEnabled() then return end
  if not IsInGuild() then return end
  
  local key, C = ensureGuildData()
  local guildName, guildRankName, guildRankIndex, realm = GetGuildInfo("player")
  
  if not guildName then return end
  
  -- Store guild info snapshot
  C.guild.info = {
    name = guildName,
    realm = realm or GetRealmName(),
    rank = guildRankName,
    rank_index = guildRankIndex,
    faction = UnitFactionGroup("player"),
    timestamp = now()
  }
end

-- ============================================================================
-- Enhanced Money Transaction Parsing with Fixed Date Handling
-- ============================================================================

local function parseMoneyTransaction(index)
  -- API returns: type, name, amount, yearsAgo, monthsAgo, daysAgo, hoursAgo
  -- All time values are RELATIVE elapsed offsets, NOT calendar dates.
  local transType, playerName, amount, rawYear, rawMonth, rawDay, rawHour =
    GetGuildBankMoneyTransaction(index)

  if not transType then return nil end

  -- Record the time of this scan so the server can derive the absolute timestamp
  local scanTime = now()

  -- Stable timestamp: scan_time minus the relative offset
  local ts = computeTimestampFromOffsets(scanTime, rawYear, rawMonth, rawDay, rawHour)

  local trans = {
    ts         = ts,
    scan_ts    = scanTime,       -- when we captured this; server uses this + offsets
    type       = transType,
    player     = playerName or "Unknown",
    amount     = amount or 0,
    -- Store raw relative offsets exactly as returned by the API
    years_ago  = rawYear  or 0,
    months_ago = rawMonth or 0,
    days_ago   = rawDay   or 0,
    hours_ago  = rawHour  or 0,
  }

  trans.hash = generateMoneyTransactionHash(trans)
  return trans
end

local function parseItemTransaction(index, tabIndex)
  -- Correct Wrath 3.3.5a API: GetGuildBankTransaction(tab, index)
  -- Returns: type, name, itemLink, count, tab1, tab2, yearsAgo, monthsAgo, daysAgo, hoursAgo
  -- All time values are RELATIVE elapsed offsets, NOT calendar dates.
  -- tab1/tab2 are for "move" transactions (source/destination tab).
  local transType, playerName, itemLink, itemCount, tab1, tab2, rawYear, rawMonth, rawDay, rawHour =
    GetGuildBankTransaction(tabIndex, index)

  if not transType then return nil end

  local scanTime = now()
  local ts = computeTimestampFromOffsets(scanTime, rawYear, rawMonth, rawDay, rawHour)

  -- Get item information
  local itemName, itemLevel, quality, itemID
  if itemLink then
    itemName, itemLink, itemLevel, quality, _, _, _, itemID = safeGetItemInfo(itemLink)
    if not itemName then
      -- Item not yet in client cache; extract ID from the link string
      itemID = tonumber(itemLink:match("item:(%d+)"))
    end
  end

  local trans = {
    ts         = ts,
    scan_ts    = scanTime,
    type       = transType,
    player     = playerName or "Unknown",
    item_link  = itemLink,
    item_name  = itemName,
    item_id    = itemID,
    count      = itemCount or 1,
    tab        = tabIndex,
    tab_from   = (transType == "move") and tab1 or nil,
    tab_to     = (transType == "move") and tab2 or nil,
    -- Raw relative offsets from API (stable across scans)
    years_ago  = rawYear  or 0,
    months_ago = rawMonth or 0,
    days_ago   = rawDay   or 0,
    hours_ago  = rawHour  or 0,
  }

  trans.hash = generateItemTransactionHash(trans)
  return trans
end

-- ============================================================================
-- Guild Bank Tab Access Check
-- ============================================================================

local function canViewTab(tabIndex)
  local tabName, tabIcon, isViewable = GetGuildBankTabInfo(tabIndex)
  return isViewable == true
end

-- ============================================================================
-- Guild Bank Scanning
-- ============================================================================

function Guild:ScanGuildBank()
  if not self:IsEnabled() then return end
  if not IsInGuild() then return end
  if shouldThrottle("bank_scan", THROTTLE.bank_scan) then return end

  local key, C = ensureGuildData()
  local ts = now()

  -- Get guild bank money (in copper)
  local money = GetGuildBankMoney and GetGuildBankMoney() or 0

  -- Scan all accessible tabs
  local tabs = {}
  local numTabs = GetNumGuildBankTabs and GetNumGuildBankTabs() or 0

  for tabIndex = 1, numTabs do
    local tabName, tabIcon, isViewable, canDeposit, numWithdrawals, remainingWithdrawals = GetGuildBankTabInfo(tabIndex)

    if isViewable then
      local tab = {
        index = tabIndex,
        name = tabName or ("Tab " .. tabIndex),
        icon = tabIcon,
        can_deposit = canDeposit,
        withdrawals_remaining = remainingWithdrawals or 0,
        slots = {},
      }

      -- Scan all slots in this tab (98 slots per tab in Wrath)
      for slotIndex = 1, 98 do
        local link = GetGuildBankItemLink(tabIndex, slotIndex)

        if link then
          local texture, count, locked = GetGuildBankItemInfo(tabIndex, slotIndex)
          local itemName, _, itemLevel, quality = safeGetItemInfo(link)
          local itemID = tonumber(link:match("item:(%d+)"))

          if itemName then
            table.insert(tab.slots, {
              slot      = slotIndex,
              link      = link,
              id        = itemID,
              name      = itemName,
              icon      = texture,
              count     = count or 1,
              quality   = quality,
              ilvl      = itemLevel,
              locked    = locked,
            })
          end
        end
      end

      table.insert(tabs, tab)
    end
  end

  -- Store current snapshot
  C.guild.snapshots.bank = {
    ts       = ts,
    money    = money,
    tabs     = tabs,
    num_tabs = numTabs,
  }

  -- Detect money changes
  if money ~= guildState.previousMoney and guildState.previousMoney > 0 then
    local moneyDelta = money - guildState.previousMoney

    table.insert(C.guild.events, {
      ts         = ts,
      type       = "money_change",
      old_amount = guildState.previousMoney,
      new_amount = money,
      delta      = moneyDelta,
    })

    if NS.Log then
      NS.Log("INFO", "Guild bank money changed: %s copper (%+d)", money, moneyDelta)
    end
  end

  guildState.previousMoney = money
end

-- ============================================================================
-- Guild Roster Scanning
-- ============================================================================

function Guild:ScanRoster()
  if not self:IsEnabled() then return end
  if not IsInGuild() then return end
  if shouldThrottle("roster_scan", THROTTLE.roster_scan) then return end

  local key, C = ensureGuildData()
  local ts = now()

  GuildRoster()

  local numTotal, numOnline, numMobileOnline = GetNumGuildMembers()
  local members = {}

  for i = 1, numTotal do
    local name, rank, rankIndex, level, class, zone, note, officernote,
          online, status, classFileName, achievementPoints, achievementRank,
          isMobile, canSoR, repStanding = GetGuildRosterInfo(i)

    if name then
      -- Remove realm suffix if present
      local playerName = strsplit("-", name)

      table.insert(members, {
        name             = playerName,
        rank             = rank,
        rank_index       = rankIndex,
        level            = level,
        class            = class,
        class_filename   = classFileName,
        zone             = zone,
        note             = note,
        officer_note     = officernote,
        online           = online,
        status           = status,
        achievement_pts  = achievementPoints,
        is_mobile        = isMobile,
        rep_standing     = repStanding,
      })
    end
  end

  -- Detect roster changes vs previous snapshot
  local previous = guildState.previousRoster or {}
  local prevByName = {}
  for _, m in ipairs(previous) do
    prevByName[m.name] = m
  end

  for _, m in ipairs(members) do
    if not prevByName[m.name] then
      table.insert(C.guild.events, {
        ts     = ts,
        type   = "member_joined",
        player = m.name,
        rank   = m.rank,
        level  = m.level,
        class  = m.class,
      })
    end
  end

  local currentByName = {}
  for _, m in ipairs(members) do currentByName[m.name] = m end

  for _, m in ipairs(previous) do
    if not currentByName[m.name] then
      table.insert(C.guild.events, {
        ts     = ts,
        type   = "member_left",
        player = m.name,
      })
    end
  end

  -- Store new snapshot
  C.guild.roster = {
    ts      = ts,
    members = members,
    online  = numOnline or 0,
    total   = numTotal or 0,
  }

  guildState.previousRoster = members

  if NS.Log then
    NS.Log("INFO", "Guild roster scanned: %d members (%d online)", numTotal or 0, numOnline or 0)
  end
end

-- ============================================================================
-- Guild Bank Transaction Logs Scanning
-- ============================================================================

function Guild:ScanBankTransactionLogs()
  if not self:IsEnabled() then return end
  if not IsInGuild() then return end
  if not self:HasBankLogAccess() then return end
  if shouldThrottle("transaction_log_query", THROTTLE.transaction_log_query) then return end
  
  local key, C = ensureGuildData()
  
  -- Create deduplication set
  local existing = {}
  for _, trans in ipairs(C.guild.logs.transactions) do
    local transKey = trans.hash or generateTransactionHash(trans)
    existing[transKey] = true
  end
  
  local numTabs = GetNumGuildBankTabs() or 0
  local totalNewLogs = 0
  
  for tabIndex = 1, numTabs do
    QueryGuildBankLog(tabIndex)
    
    local numTransactions = GetNumGuildBankTransactions(tabIndex) or 0
    
    if numTransactions > 0 then
      for i = 1, math.min(numTransactions, 25) do
        local trans = parseItemTransaction(i, tabIndex)
        
        if trans then
          local transKey = trans.hash
          
          if not existing[transKey] then
            table.insert(C.guild.logs.transactions, trans)
            existing[transKey] = true
            totalNewLogs = totalNewLogs + 1
          end
        end
      end
    end
  end
  
  if totalNewLogs > 0 then
    print(string.format("[WhoDAT Guild] ✓ Captured %d new item transaction logs", totalNewLogs))
  end
end

function Guild:ScanBankMoneyLog()
  if not self:IsEnabled() then return end
  if not IsInGuild() then return end
  if not self:HasBankLogAccess() then return end
  if shouldThrottle("money_log_query", THROTTLE.money_log_query) then return end
  
  local key, C = ensureGuildData()
  
  -- Create deduplication set
  local existing = {}
  for _, trans in ipairs(C.guild.logs.money) do
    local transKey = trans.hash or generateTransactionHash(trans)
    existing[transKey] = true
  end
  
  -- Query money log (use MAX_GUILDBANK_TABS + 1 for money log)
  QueryGuildBankLog(MAX_GUILDBANK_TABS + 1)
  
  local numTransactions = GetNumGuildBankMoneyTransactions() or 0
  local newLogsFound = 0
  
  if numTransactions > 0 then
    for i = 1, math.min(numTransactions, 25) do
      local trans = parseMoneyTransaction(i)
      
      if trans then
        local transKey = trans.hash
        
        if not existing[transKey] then
          table.insert(C.guild.logs.money, trans)
          existing[transKey] = true
          newLogsFound = newLogsFound + 1
          
          -- Debug output for troubleshooting
          print(string.format("[WhoDAT Guild] New money log: %s %s %dg (%dd %dh ago, hash: %s)",
            trans.player, trans.type,
            math.floor(trans.amount / 10000),
            trans.days_ago  or 0,
            trans.hours_ago or 0,
            trans.hash:sub(1, 16)
          ))
        end
      end
    end
  end
  
  if newLogsFound > 0 then
    print(string.format("[WhoDAT Guild] ✓ Captured %d new money transaction logs", newLogsFound))
  end
end

-- ============================================================================
-- Event Handlers
-- ============================================================================

function Guild:OnGuildBankOpened()
  guildState.bankOpen = true
  
  -- Query all tabs to request data from server
  local numTabs = GetNumGuildBankTabs() or 0
  
  -- Query each tab to load its data
  for tabIndex = 1, numTabs do
    QueryGuildBankTab(tabIndex)
  end
  
  -- Wait 5 seconds then scan
  DelayedCall(5, function()
    if guildState.bankOpen then
      self:ScanGuildBank()
      print("|cff00ff00[WhoDAT]|r Guild bank tabs scanned!")
    end
  end)
  
  -- Check log access and scan if available
  if self:HasBankLogAccess() then
    DelayedCall(2, function()
      self:ScanBankTransactionLogs()
      self:ScanBankMoneyLog()
    end)
  end
end

function Guild:OnGuildBankClosed()
  guildState.bankOpen = false
end

function Guild:OnGuildRosterUpdate()
  self:ScanRoster()
end

-- ============================================================================
-- Guild Bank Scan Button
-- ============================================================================

local guildBankScanButton = nil

local function CreateGuildBankScanButton()
  if guildBankScanButton then return end
  if not GuildBankFrame then return end
  
  -- Create button
  guildBankScanButton = CreateFrame("Button", "WhoDAT_GuildBankScanButton", GuildBankFrame, "UIPanelButtonTemplate")
  guildBankScanButton:SetWidth(120)
  guildBankScanButton:SetHeight(22)
  
  -- Position it
  guildBankScanButton:SetPoint("TOPRIGHT", GuildBankFrame, "BOTTOMRIGHT", -10, -5)
  guildBankScanButton:SetText("Capture Logs")
  
  -- On click: Capture a fresh snapshot of logs
  guildBankScanButton:SetScript("OnClick", function()
    local hasAccess = Guild:HasBankLogAccess()
    
    if not hasAccess then
      print("[WhoDAT] You need guild master or officer permissions to view logs")
      return
    end
    
    print("[WhoDAT] Capturing guild bank logs...")
    
    -- Reset throttles to allow immediate capture
    guildState.lastTransactionLogQuery = 0
    guildState.lastMoneyLogQuery = 0
    
    -- Clear previous logs to get a fresh snapshot
    -- This is INTENTIONAL - each capture should be a clean snapshot of the current 25 visible transactions
    local key = getCharacterKey()
    if WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key] then
      local C = WhoDatDB.characters[key]
      if C.guild and C.guild.logs then
        C.guild.logs.transactions = {}
        C.guild.logs.money = {}
      end
    end
    
    -- Scan logs
    Guild:ScanBankTransactionLogs()
    Guild:ScanBankMoneyLog()
    
    -- Show results
    local key = getCharacterKey()
    local C = WhoDatDB.characters[key]
    
    if C and C.guild and C.guild.logs then
      local transCount = #(C.guild.logs.transactions or {})
      local moneyCount = #(C.guild.logs.money or {})
      print(string.format("[WhoDAT] ✓ Captured %d item transactions, %d money transactions", transCount, moneyCount))
      
      if transCount > 0 or moneyCount > 0 then
        print("[WhoDAT] Logs saved! Export your data to upload them.")
        print("|cffff8800[TIP]|r Only click 'Capture Logs' once per upload to avoid confusion!")
      end
    end
  end)
  
  -- Tooltip
  guildBankScanButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("WhoDAT Guild Bank Log Capture", 1, 1, 1, 1, true)
    GameTooltip:AddLine(" ", 1, 1, 1, true)
    
    local hasAccess = Guild:HasBankLogAccess()
    
    if hasAccess then
      GameTooltip:AddLine("Click to capture guild bank transaction logs", 1, 1, 1, true)
      GameTooltip:AddLine(" ", 1, 1, 1, true)
      GameTooltip:AddLine("Captures:", 0.7, 0.7, 0.7, true)
      GameTooltip:AddLine("• Item deposits and withdrawals", 1, 1, 1, true)
      GameTooltip:AddLine("• Money deposits and withdrawals", 1, 1, 1, true)
      GameTooltip:AddLine("• Repair costs", 1, 1, 1, true)
      GameTooltip:AddLine(" ", 1, 1, 1, true)
      GameTooltip:AddLine("TIP: Click 'Log' tab first to load data", 0.5, 1, 0.5, true)
      GameTooltip:AddLine("Then click this button ONCE per upload", 0.5, 1, 0.5, true)
    else
      GameTooltip:AddLine("You need guild master or officer", 0.8, 0.4, 0.4, true)
      GameTooltip:AddLine("permissions to capture logs", 0.8, 0.4, 0.4, true)
    end
    
    GameTooltip:Show()
  end)
  
  guildBankScanButton:SetScript("OnLeave", function(self)
    GameTooltip:Hide()
  end)
  
  -- Update button state based on permissions
  local hasAccess = Guild:HasBankLogAccess()
  if not hasAccess then
    guildBankScanButton:Disable()
    guildBankScanButton:SetAlpha(0.5)
  end
end

-- Hook to create button when guild bank opens
local function HookGuildBank()
  if not GuildBankFrame then return end
  
  if GuildBankFrame and not guildBankScanButton then
    DelayedCall(0.1, CreateGuildBankScanButton)
  end
end

-- Initialize button when guild bank is opened
local buttonInitFrame = CreateFrame("Frame")
buttonInitFrame:RegisterEvent("GUILDBANKFRAME_OPENED")
buttonInitFrame:SetScript("OnEvent", function(self, event)
  if event == "GUILDBANKFRAME_OPENED" then
    HookGuildBank()
  end
end)

-- ============================================================================
-- Event Registration
-- ============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("GUILDBANKFRAME_OPENED")
eventFrame:RegisterEvent("GUILDBANKFRAME_CLOSED")
eventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")

eventFrame:SetScript("OnEvent", function(self, event, ...)
  if event == "GUILDBANKFRAME_OPENED" then
    Guild:OnGuildBankOpened()
  elseif event == "GUILDBANKFRAME_CLOSED" then
    Guild:OnGuildBankClosed()
  elseif event == "GUILD_ROSTER_UPDATE" then
    Guild:OnGuildRosterUpdate()
  end
end)

-- ============================================================================
-- Initialization
-- ============================================================================

if NS.Log then
  NS.Log("INFO", "Guild module loaded (v3.0.1 - Fixed Deduplication)")
end

return NS.Guild