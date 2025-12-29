
--[[========================================================================================
 WhoDAT - tracker_auction.lua (Wrath 3.3.5a, PRODUCTION v2.6 – Dedupe & TS Compaction)
 Auction House scanner + market micro-snapshots + time series
==========================================================================================]]--
local TrackerAuction = {}
TrackerAuction.__index = TrackerAuction
_G.TrackerAuction = TrackerAuction

-- ===== Lifecycle chat (colored) =====
local SCAN_LIFECYCLE = { active = false }
local function TA_Chat(msg)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(msg)
  else
    print(msg)
  end
end
local function TA_AnnounceScanStartedOnce()
  if SCAN_LIFECYCLE.active then return end
  SCAN_LIFECYCLE.active = true
  
local msg = "|cff0070dd[WhoDAT]|r|cffffffff-|r|cff1eff00Auction Scan Started.|r - "
    .. "|cffff69b4Y|r|cffff0000o|r|cffff69b4u|r|cffff0000r|r "
    .. "|cffff69b4p|r|cffff0000a|r|cffff69b4t|r|cffff0000i|r|cffff69b4e|r|cffff0000n|r|cffff69b4c|r|cffff0000e|r "
    .. "|cffff69b4i|r|cffff0000s|r "
    .. "|cffff69b4a|r|cffff0000p|r|cffff69b4p|r|cffff0000r|r|cffff69b4e|r|cffff0000c|r|cffff69b4i|r|cffff0000a|r|cffff69b4t|r|cffff0000e|r|cffff69b4d|r|cffff0000!   <3|r"

  TA_Chat(msg)
end
local function TA_AnnounceScanCompletedOnce()
  if not SCAN_LIFECYCLE.active then return end
  SCAN_LIFECYCLE.active = false
  local msg = "|cff0070dd[WhoDAT]|r|cffffffff-|r|cff1eff00Auction Scan Completed!|r"
  TA_Chat(msg)
end

-- ===== Readiness (Blizzard AH API) =====
local function TA_EnsureAuctionReady()
  -- Ensure Blizzard Auction UI is loaded (BrowseButton..Seller fontstrings live here)
  if type(LoadAddOn) == "function" then pcall(function() LoadAddOn("Blizzard_AuctionUI") end) end
  local canQuery = false
  local ok, cq = pcall(function() return CanSendAuctionQuery() end)
  if ok then canQuery = cq end
  if canQuery then return true end
  if AuctionFrame and AuctionFrame:IsShown() then return true end
  return false
end

-- ===== Seller column reader (no tooltip, AH stays visible) =====
local function TA_ReadSellerFromBrowseRow(index)
  -- Blizzard creates BrowseButtonN Seller fontstrings when the browse list is rendered.
  -- Works on WotLK 3.3.5a (including Warmane/Icecrown).
  -- NOTE: Only the visible batch is available (<= 50); align with numBatch for current page.
  local fs = _G["BrowseButton"..index.."Seller"]
  if fs and fs.GetText then
    local s = fs:GetText()
    if s and s ~= "" then return s end
  end
  return nil
end

-- ===== Lightweight timer =====
local function TA_After(delay, fn)
  local f = CreateFrame("Frame")
  local acc = 0
  f:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc >= (delay or 0) then
      f:SetScript("OnUpdate", nil)
      pcall(fn)
    end
  end)
end

-- ===== Wait until CanSendAuctionQuery() is true (with deadline), then invoke =====
local function TA_WaitForCanQuery(maxWaitSec, onReady)
  local deadline = time() + (maxWaitSec or 5)
  local function poll()
    local ok, can = pcall(function() return CanSendAuctionQuery() end)
    if ok and can then pcall(onReady); return end
    if time() >= deadline then
      -- still proceed; some realms return false too aggressively
      pcall(onReady); return
    end
    TA_After(0.25, poll)
  end
  poll()
end

-- === Listing identity & upsert helpers ===
local function TA_RowKeyPartsFromLink(link)
  local itemString = link and link:match("item:[^\n]+")
  local fields = {}
  if itemString then
    for v in itemString:gmatch("([^:]+)") do table.insert(fields, v) end
  end
  local itemId   = tonumber(fields[2]) or 0
  local enchant  = tonumber(fields[3]) or 0
  local suffix   = tonumber(fields[7]) or 0
  local uniqueId = tonumber(fields[8]) or 0
  return itemId, enchant, suffix, uniqueId
end

-- NEW: normalize seller (case/whitespace)
local function TA_NormalizeSeller(s)
  if not s or s == "" then return "" end
  s = s:gsub("%s+", " "):gsub("%s+$", ""):gsub("^%s+", ""):lower()
  return s
end

-- NEW: canonical listing key (no uniqueId; price-aware; seller normalized)
local function TA_MakeListingKey(rowLike)
  local itemId, _, suffix, _ = TA_RowKeyPartsFromLink(rowLike.link)
  local stackSize = rowLike.stackSize or 1
  local sellerNorm = TA_NormalizeSeller(rowLike.seller or rowLike.sellerName)
  local priceStack = rowLike.price
    or ((rowLike.buyoutPrice and rowLike.buyoutPrice > 0) and rowLike.buyoutPrice)
    or (rowLike.nextBid or 0) or 0
  return string.format("%d:%d:%d:%s:%d", itemId, suffix, stackSize, sellerNorm, priceStack)
end

local function TA_UpsertRow(bucket, rowLike)
  local newKey = TA_MakeListingKey(rowLike)
  for i = #bucket, 1, -1 do
    local oldKey = TA_MakeListingKey(bucket[i])
    if oldKey == newKey then
      local b = bucket[i]
      b.ts = time()
      b.duration = rowLike.duration or rowLike.timeLeft or b.duration
      b.price = rowLike.price
        or ((rowLike.buyoutPrice and rowLike.buyoutPrice > 0) and rowLike.buyoutPrice)
        or (rowLike.nextBid or b.price)
      b.link = rowLike.link or b.link
      b.name = rowLike.name or b.name
      b.stackSize = rowLike.stackSize or b.stackSize
      b.seller = (rowLike.seller or rowLike.sellerName or b.seller)
      return
    end
  end
  table.insert(bucket, {
    ts = time(),
    itemId = rowLike.itemId,
    link = rowLike.link,
    name = rowLike.name,
    stackSize = rowLike.stackSize or 1,
    price = rowLike.price
      or ((rowLike.buyoutPrice and rowLike.buyoutPrice > 0) and rowLike.buyoutPrice)
      or (rowLike.nextBid or 0),
    duration = rowLike.duration or rowLike.timeLeft,
    seller = rowLike.seller or rowLike.sellerName,
    sold = false,
  })
end

-- NEW: session-level dedupe guard
local SESSION_SEEN = {}
local SESSION_TTL  = 15 -- seconds

local function TA_SessionMark(key)
  SESSION_SEEN[key] = time()
end
local function TA_SessionRecentlySeen(key)
  local t = SESSION_SEEN[key]
  return t and (time() - t) < SESSION_TTL
end
local function TA_SessionGC()
  local now = time()
  for k, ts in pairs(SESSION_SEEN) do
    if (now - ts) > (SESSION_TTL * 4) then SESSION_SEEN[k] = nil end
  end
end
-- PUBLIC: Expose GC for external callers (memory management)
function TrackerAuction.SessionGC()
  TA_SessionGC()
end
-- NEW: wrapped upsert that honors session dedupe
local function TA_UpsertRow_Dedup(bucket, rowLike)
  local key = TA_MakeListingKey(rowLike)
  if TA_SessionRecentlySeen(key) then
    -- Refresh ts if the row already exists; otherwise skip append
    for i = #bucket, 1, -1 do
      if TA_MakeListingKey(bucket[i]) == key then
        bucket[i].ts = time()
        return
      end
    end
    return
  end
  TA_UpsertRow(bucket, rowLike)
  TA_SessionMark(key)
end

-- ===== Duration buckets =====
local TIME_BUCKET_SECONDS = {
  [1] = 1800,  -- ~30 minutes
  [2] = 7200,  -- ~2 hours
  [3] = 43200, -- ~12 hours
  [4] = 172800,-- ~48 hours
}
function TrackerAuction.TimeBucketToSeconds(bucket)
  return TIME_BUCKET_SECONDS[bucket or 1] or 0
end
function TrackerAuction.TimeBucketToHours(bucket)
  local s = TrackerAuction.TimeBucketToSeconds(bucket)
  if s >= 172800 then return 48
  elseif s >= 43200 then return 12
  elseif s >= 7200 then return 2
  else return 0.5 end
end

-- ===== Row normalizer (with seller backfill from Browse UI) =====
function TrackerAuction.NormalizeAuctionRow(list, index)
  local link = GetAuctionItemLink(list, index)
  if not link then return nil end
  local name, texture, count, quality, canUse, level,
        minBid, minIncrement, buyoutPrice, bidAmount,
        isHighBidder, owner, saleStatus = GetAuctionItemInfo(list, index)
  local timeLeft = GetAuctionItemTimeLeft(list, index)

  count = (count and count > 0) and count or 1
  minBid, minIncrement, buyoutPrice = minBid or 0, minIncrement or 0, buyoutPrice or 0
  bidAmount, owner = bidAmount or 0, owner or ""
  isHighBidder = not not isHighBidder

  local nextBid
  if bidAmount > 0 then
    nextBid = bidAmount + minIncrement
    if buyoutPrice > 0 and nextBid > buyoutPrice then nextBid = buyoutPrice end
  elseif minBid > 0 then
    nextBid = minBid
  else
    nextBid = 1
  end

  local _, _, _, itemLevel, itemType, itemSubType, _, itemEquipLoc = GetItemInfo(link)

  local timeSeen = time()

  local itemString = link:match("item:[^\n]+")
  local itemId, suffix, uniqueId, enchant = 0, 0, 0, 0
  if itemString then
    local fields = {}
    for v in itemString:gmatch("([^:]+)") do table.insert(fields, v) end
    itemId   = tonumber(fields[2]) or 0
    enchant  = tonumber(fields[3]) or 0
    suffix   = tonumber(fields[7]) or 0
    uniqueId = tonumber(fields[8]) or 0
  end

  -- Resilient seller name:
  local sellerName = owner
  if (not sellerName or sellerName == "") and list == "list" then
    -- Read seller from the visible browse row seller column (no tooltip, AH stays visible)
    local s = TA_ReadSellerFromBrowseRow(index)
    if s then sellerName = s end
  end

return {
    link = link, name = name, itemId = itemId, suffix = suffix, uniqueId = uniqueId, enchant = enchant,
    texture = texture, quality = quality, itemType = itemType, subType = itemSubType, equipLoc = itemEquipLoc,
    stackSize = count, minBid = minBid, increment = minIncrement, buyoutPrice = buyoutPrice,
    curBid = bidAmount, nextBid = nextBid, isHighBidder = isHighBidder, sellerName = sellerName,
    timeLeft = timeLeft, timeSeen = timeSeen,
    -- NEW FIELDS for sold/expired tracking
    ts = timeSeen,           -- Timestamp (alias of timeSeen for consistency)
    duration = timeLeft,     -- Duration code (1-4) for expiry calculation
    seller = sellerName,     -- Seller name (alias for consistency)
    price = buyoutPrice,     -- Price (alias for consistency)
    sold = false,            -- Not sold yet
    sold_ts = nil,           -- Will be set when sold
    sold_price = nil,        -- Will be set from mail
    expired = false,         -- Not expired yet
    expired_ts = nil,        -- Will be set when expired
  }
end

-- ===== Client-side filter =====
function TrackerAuction._passes(rec, params)
  if not params then return true end
  if params.sellerIsMe and rec.sellerName ~= UnitName("player") then return false end
  if params.name then
    local needle = TrackerAuction.QuerySafeName(params.name)
    if needle then
      local rn = rec.name and rec.name:lower() or ""
      if not rn:find(needle, 1, true) then return false end
    end
  end
  if params.itemIdExact and rec.itemId ~= params.itemIdExact then return false end
  if params.minStack and rec.stackSize < params.minStack then return false end
  if params.maxStack and rec.stackSize > params.maxStack then return false end
  local price = (rec.buyoutPrice > 0) and rec.buyoutPrice or rec.nextBid
  if params.perItem then
    local ppi = (price > 0) and math.floor(price / rec.stackSize + 0.5) or 0
    if params.minPrice and ppi < params.minPrice then return false end
    if params.maxPrice and ppi > params.maxPrice then return false end
  else
    if params.minPrice and price < params.minPrice then return false end
    if params.maxPrice and price > params.maxPrice then return false end
  end
  return true
end

-- ===== Visible page quick read (with seller backfill per index) =====
function TrackerAuction.QueryVisiblePage(params)
  local list = "list"
  local numBatch, total = GetNumAuctionItems(list)
  local rows = {}
  for i = 1, numBatch do
    local rec = TrackerAuction.NormalizeAuctionRow(list, i)
    if rec and TrackerAuction._passes(rec, params) then
      -- If seller still blank, attempt UI seller column read
      if (not rec.sellerName or rec.sellerName == "") then
        local s = TA_ReadSellerFromBrowseRow(i)
        if s then rec.sellerName = s end
      end
      table.insert(rows, rec)
    end
  end
  local stats = { source="visiblePage", totalFound=#rows, numBatch=numBatch, totalAuctions=total, when=time() }
  return rows, stats
end

-- ===== Owner fast path =====
local function TA_ReadOwnerRows()
  local list = "owner"
  local numOwner = GetNumAuctionItems(list)
  local rows = {}
  for i = 1, numOwner do
    local rec = TrackerAuction.NormalizeAuctionRow(list, i)
    if rec then table.insert(rows, rec) end
  end
  return rows, numOwner
end

-- ===== Market helpers =====
function TrackerAuction.MakeItemKey(rec)
  return string.format("%d:%d", rec.itemId or 0, rec.stackSize or 1)
end

function TrackerAuction.ComputeLowHigh(rows, take)
  take = take or 3
  local filtered = {}
  for i = 1, #rows do
    local r = rows[i]
    if r.buyoutPrice and r.buyoutPrice > 0 and r.sellerName ~= UnitName("player") then
      table.insert(filtered, r)
    end
  end
  table.sort(filtered, function(a,b) return a.buyoutPrice < b.buyoutPrice end)
  local outLow, outHigh = {}, {}
  for i = 1, math.min(take, #filtered) do
    local r = filtered[i]
    table.insert(outLow, {
      priceStack = r.buyoutPrice,
      priceItem  = math.floor(r.buyoutPrice / (r.stackSize > 0 and r.stackSize or 1) + 0.5),
      seller = r.sellerName,
      link = r.link,
    })
  end
  for i = math.max(1, #filtered - take + 1), #filtered do
    local r = filtered[i]
    table.insert(outHigh, 1, {
      priceStack = r.buyoutPrice,
      priceItem  = math.floor(r.buyoutPrice / (r.stackSize > 0 and r.stackSize or 1) + 0.5),
      seller = r.sellerName,
      link = r.link,
    })
  end
  return { low = outLow, high = outHigh }
end

-- ===== Market query (async) - Wrath signature + gating + timeout fallback =====
do
  local QUERY = { active=false, params=nil, rows={}, page=0, total=0, onComplete=nil, waiting=false }
  local PER_PAGE = 50
  local FALLBACK_AFTER = 2.0 -- seconds without AUCTION_ITEM_LIST_UPDATE

  -- Wrath 3.3.5: QueryAuctionItems(name, minLevel, maxLevel, page, isUsable, qualityIndex, getAll, exactMatch, filterData)
  local function callQueryAuctionItems(name, page, exactMatch, getAll)
    local minLevel, maxLevel = 0, 0
    local isUsable, qualityIndex = false, nil
    local filterData = nil
    pcall(function()
      QueryAuctionItems(name, minLevel, maxLevel, page or 0, isUsable, qualityIndex, getAll or false, exactMatch or false, filterData)
    end)
  end

  local function issueQuery(page)
    if not TA_EnsureAuctionReady() then return end
    local p = QUERY.params or {}
    local nameExact = p.name
    if ((not nameExact or nameExact == "") and p.itemIdExact) then
      local itemName = GetItemInfo(p.itemIdExact)
      if itemName then nameExact = itemName end
    end
    local exactMatch = nameExact and nameExact ~= ""
    callQueryAuctionItems(exactMatch and nameExact or nil, page or 0, exactMatch, false)
    -- start timeout
    QUERY.waiting = true
    local expectedPage = page or 0
    TA_After(FALLBACK_AFTER, function()
      if QUERY.active and QUERY.waiting and QUERY.page == expectedPage then
        local function fallbackVisiblePageRead()
          local rows,_ = TrackerAuction.QueryVisiblePage({
            name = nameExact,
            itemIdExact = p.itemIdExact,
            minStack = p.minStack,
            maxStack = p.maxStack,
          })
          rows = rows or {}
          local added = 0
          for i = 1, #rows do
            local rec = rows[i]
            if rec and rec.sellerName ~= UnitName("player") then
              table.insert(QUERY.rows, rec); added = added + 1
            end
          end
          if added == 0 then
            TA_After(0.5, function()
              local rows2,_ = TrackerAuction.QueryVisiblePage({
                name = nameExact,
                itemIdExact = p.itemIdExact,
                minStack = p.minStack,
                maxStack = p.maxStack,
              })
              rows2 = rows2 or {}
              for i = 1, #rows2 do
                local rec = rows2[i]
                if rec and rec.sellerName ~= UnitName("player") then
                  table.insert(QUERY.rows, rec)
                end
              end
              TrackerAuction._ContinueAfterPageTimeout()
            end)
          else
            TrackerAuction._ContinueAfterPageTimeout()
          end
        end
        fallbackVisiblePageRead()
      end
    end)
  end

  function TrackerAuction._ContinueAfterPageTimeout()
    local takeNeeded = (QUERY.params and QUERY.params._take) or 3
    local haveEnough = #QUERY.rows >= (2 * takeNeeded)
    if haveEnough then
      local cb = QUERY.onComplete
      local outRows = QUERY.rows
      QUERY.active, QUERY.params, QUERY.rows, QUERY.page, QUERY.total, QUERY.onComplete, QUERY.waiting =
        false, nil, {}, 0, 0, nil, false
      if type(cb) == "function" then cb(outRows) end
    else
      QUERY.page = QUERY.page + 1
      TA_WaitForCanQuery(5, function() TA_After(0.1, function() issueQuery(QUERY.page) end) end)
    end
  end

  local f = CreateFrame("Frame")
  f:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
  f:SetScript("OnEvent", function(_, event)
    if not QUERY.active then return end
    local list = "list"
    local numBatch, total = GetNumAuctionItems(list)
    QUERY.total = total or 0
    QUERY.waiting = false
    for i = 1, (numBatch or 0) do
      local rec = TrackerAuction.NormalizeAuctionRow(list, i)
      if rec and TrackerAuction._passes(rec, QUERY.params) then
        -- If seller blank, backfill from Browse UI while AH is visible
        if (not rec.sellerName or rec.sellerName == "") then
          local s = TA_ReadSellerFromBrowseRow(i)
          if s then rec.sellerName = s end
        end
        if rec.sellerName ~= UnitName("player") then
          table.insert(QUERY.rows, rec)
        end
      end
    end
    local takeNeeded = (QUERY.params and QUERY.params._take) or 3
    local haveEnough = #QUERY.rows >= (2 * takeNeeded)
    local pagesTotal = math.floor(math.max(0, QUERY.total - 1) / PER_PAGE)
    if haveEnough or QUERY.page >= pagesTotal then
      local cb = QUERY.onComplete
      local rows = QUERY.rows
      QUERY.active, QUERY.params, QUERY.rows, QUERY.page, QUERY.total, QUERY.onComplete =
        false, nil, {}, 0, 0, nil
      if type(cb) == "function" then cb(rows) end
      return
    end
    QUERY.page = QUERY.page + 1
    TA_WaitForCanQuery(5, function() TA_After(0.1, function() issueQuery(QUERY.page) end) end)
  end)

  function TrackerAuction.ScanMarketAsync(params, onComplete)
    if not TA_EnsureAuctionReady() then
      if type(onComplete) == "function" then onComplete({}, { error = "AuctionHouseNotReady" }) end
      return nil, "AuctionHouseNotReady"
    end
    local pRoot = params or {}
    -- Enforce same stack size comparisons
    if pRoot.minStack == nil and pRoot.maxStack == nil and pRoot.stackSize then
      pRoot.minStack = pRoot.stackSize
      pRoot.maxStack = pRoot.stackSize
    end
    -- Carry 'take' through for early stop
    local ACfgRoot = _G.WhoDAT_GetAuctionCfg and _G.WhoDAT_GetAuctionCfg() or (_G.WhoDAT_Config or {})
    local ACfg = ACfgRoot.auction or ACfgRoot
    local marketTake = (type(pRoot.marketTake) == "number" and pRoot.marketTake > 0) and pRoot.marketTake or (ACfg.market_take or 3)
    pRoot._take = marketTake

    QUERY.active = true
    QUERY.params = pRoot
    QUERY.rows = {}
    QUERY.page = 0
    QUERY.total = 0
    QUERY.onComplete = onComplete
    TA_WaitForCanQuery(5, function() issueQuery(0) end)
    return true
  end
end

-- ===== Market scan =====
function TrackerAuction.ScanMyAuctionsWithMarket(options, onComplete)
  options = options or {}
  local ACfgRoot = _G.WhoDAT_GetAuctionCfg and _G.WhoDAT_GetAuctionCfg() or (_G.WhoDAT_Config or {})
  local ACfg = ACfgRoot.auction or ACfgRoot
  local persistTS = (options.persistTS ~= nil) and options.persistTS or (ACfg.persist_market_ts ~= false)
  local marketTake = (type(options.marketTake) == "number" and options.marketTake > 0) and options.marketTake or (ACfg.market_take or 3)
  local persistRows = (ACfg.persist_rows_to_sv ~= false)

  if not TA_EnsureAuctionReady() then
    if type(onComplete) == "function" then onComplete({}, { error = "AuctionHouseNotReady" }) end
    return nil, "AuctionHouseNotReady"
  end

  -- Announce start once per scan lifecycle
  TA_AnnounceScanStartedOnce()

  -- 1) Owner list first
  local myRows, numOwner = TA_ReadOwnerRows()

  -- 2) Worklist (distinct itemId + stackSize)
  local worklist, seen = {}, {}
  for i = 1, #myRows do
    local r = myRows[i]
    local stack = (r and r.stackSize) or 0
    if stack > 0 then
      local key = TrackerAuction.MakeItemKey(r)
      if key and not seen[key] then
        seen[key] = true
        local nm = r.name
        if (not nm or nm == "") and r.link then nm = r.link:match("%[(.-)%]") or r.link end
        table.insert(worklist, { key = key, itemId = r.itemId, stackSize = stack, name = nm })
      end
    end
  end

  if #worklist == 0 then
    -- No market items; persist owner rows only
    if persistRows then
      local realm  = GetRealmName() or "UNKNOWN"
      local faction= UnitFactionGroup("player") or "Neutral"
      local char   = UnitName("player") or "UNKNOWN"
      local svKey  = string.format("%s-%s:%s", realm, faction, char)
      WhoDAT_AuctionDB = WhoDAT_AuctionDB or {}
      local bucket = WhoDAT_AuctionDB[svKey] or {}
      for i = 1, #myRows do TA_UpsertRow_Dedup(bucket, myRows[i]) end
      WhoDAT_AuctionDB[svKey] = bucket
    end
    if type(onComplete) == "function" then
      onComplete(myRows, { source = "owner-or-fallback", totalFound = #myRows, finishedAt = time() })
    end
    TA_SessionGC()
    TA_AnnounceScanCompletedOnce()
    return true
  end

  -- 3) Market fetch (sequential)
  local Q = { items = worklist, idx = 0, onDone = nil, rowsByKey = {} }
  local function startItemScan(item)
    local attempts, maxAttempts = 0, 30
    local function tryOnce()
      if TA_EnsureAuctionReady() then
        TrackerAuction.ScanMarketAsync({
          name = item.name,
          itemIdExact = item.itemId,
          stackSize = item.stackSize,
          marketTake = marketTake,
        }, function(rows)
          Q.rowsByKey[item.key] = rows or {}
          TrackerAuction._MarketQueueNext()
        end)
        return
      end
      attempts = attempts + 1
      if attempts <= maxAttempts then
        TA_After(0.5, tryOnce)
      else
        Q.rowsByKey[item.key] = {}
        TrackerAuction._MarketQueueNext()
      end
    end
    tryOnce()
  end
  function TrackerAuction._MarketQueueNext()
    Q.idx = Q.idx + 1
    local item = Q.items and Q.items[Q.idx]
    if not item then
      local cb = Q.onDone
      local result = Q.rowsByKey
      Q.items, Q.idx, Q.onDone, Q.rowsByKey = nil, 0, nil, nil
      if type(cb) == "function" then cb(result) end
      return
    end
    startItemScan(item)
  end
  function TrackerAuction._MarketQueueFetch(items, onDone)
    Q.items = items or {}
    Q.idx = 0
    Q.onDone = onDone
    Q.rowsByKey = {}
    TrackerAuction._MarketQueueNext()
  end

  -- NEW: TS compaction helper
  local function TA_TS_AppendOrUpdate(tsKey, snap, priceStack, stackSize)
    WhoDAT_AuctionMarketTS = WhoDAT_AuctionMarketTS or {}
    local bucket = WhoDAT_AuctionMarketTS[tsKey] or {}
    local priceItem = (priceStack > 0) and math.floor((priceStack / (stackSize > 0 and stackSize or 1)) + 0.5) or 0
    local now = time()
    local shouldAppend = true
    local APPEND_MIN_DELTA = 30 -- seconds

    local last = bucket[#bucket]
    if last then
      local function pricesEqual(a, b)
        if (not a and not b) then return true end
        if (not a or not b) then return false end
        if #a ~= #b then return false end
        -- Compare the first and last stack prices as a cheap stability check
        local function firstPrice(tbl) return tbl[1] and tbl[1].priceStack or 0 end
        local function lastPrice(tbl)  return tbl[#tbl] and tbl[#tbl].priceStack or 0 end
        return (firstPrice(a) == firstPrice(b)) and (lastPrice(a) == lastPrice(b))
      end
      local lowSame  = pricesEqual(last.low,  snap.low)
      local highSame = pricesEqual(last.high, snap.high)
      if lowSame and highSame and (now - (last.ts or 0) < APPEND_MIN_DELTA) then
        -- update in place
        last.ts = now
        last.my = { priceStack = priceStack, priceItem = priceItem }
        shouldAppend = false
      end
    end

    if shouldAppend then
      table.insert(bucket, { ts = now, low = snap.low, high = snap.high, my = { priceStack = priceStack, priceItem = priceItem } })
    end
    WhoDAT_AuctionMarketTS[tsKey] = bucket
  end

  TrackerAuction._MarketQueueFetch(worklist, function(rowsByKey)
    local tsNow = time()
    local rf = (GetRealmName() or "UNKNOWN") .. "-" .. (UnitFactionGroup("player") or "Neutral")
    for i = 1, #myRows do
      local r = myRows[i]
      local key = TrackerAuction.MakeItemKey(r)
      local mrows = rowsByKey[key] or {}
      local snap = TrackerAuction.ComputeLowHigh(mrows, marketTake)
      r.marketSnapshot = { ts = tsNow, low = snap.low, high = snap.high }
      if persistRows then
        local realm  = GetRealmName() or "UNKNOWN"
        local faction= UnitFactionGroup("player") or "Neutral"
        local char   = UnitName("player") or "UNKNOWN"
        local svKey  = string.format("%s-%s:%s", realm, faction, char)
        WhoDAT_AuctionDB = WhoDAT_AuctionDB or {}
        local bucket = WhoDAT_AuctionDB[svKey] or {}
        TA_UpsertRow_Dedup(bucket, r)
        WhoDAT_AuctionDB[svKey] = bucket
      end
      if persistTS then
        local tsKey = rf .. "\n" .. TA_MakeListingKey({
          link = r.link,
          stackSize = r.stackSize,
          seller = r.seller or r.sellerName,
          buyoutPrice = r.buyoutPrice,
          nextBid = r.nextBid,
          price = r.price,
        })
        local priceStack = (r.buyoutPrice and r.buyoutPrice > 0) and r.buyoutPrice or (r.nextBid or 0)
        local stackSize  = (r.stackSize and r.stackSize > 0) and r.stackSize or 1
        TA_TS_AppendOrUpdate(tsKey, snap, priceStack, stackSize)
      end
    end
    if type(onComplete) == "function" then
      onComplete(myRows, {
        source = (numOwner and numOwner > 0) and "owner+market" or "fallback+market",
        totalFound = #myRows,
        finishedAt = time(),
      })
    end
    TA_SessionGC()
    -- Announce completion once when the entire scan ends
    TA_AnnounceScanCompletedOnce()
  end)

  return true
end

-- ===== Public API: MarkSoldFromSystem =====
local function TA_MarkSoldFromSystem(namePlain)
  if not namePlain or namePlain == "" then return end
  local realm  = GetRealmName() or "UNKNOWN"
  local faction= UnitFactionGroup("player") or "Neutral"
  local char   = UnitName("player") or "UNKNOWN"
  local key = string.format("%s-%s:%s", realm, faction, char)
  local bucket = WhoDAT_AuctionDB and WhoDAT_AuctionDB[key]
  if not bucket then return end
  for i = #bucket, 1, -1 do
    local row = bucket[i]
    if row and (row.name == namePlain or (row.link and row.link:find("%["..namePlain.."%]"))) then
      row.sold = true
      row.sold_ts = time()
      break
    end
  end
end
TrackerAuction.MarkSoldFromSystem = TA_MarkSoldFromSystem

-- ===== Inline WhoDAT_AHSave logic (owner rows) =====
do
  local f = CreateFrame("Frame")
  f:RegisterEvent("AUCTION_OWNED_LIST_UPDATE")
  local function appendOwnerRow(r)
    local realm  = GetRealmName() or "UNKNOWN"
    local faction= UnitFactionGroup("player") or "Neutral"
    local char   = UnitName("player") or "UNKNOWN"
    local key    = realm .. "-" .. faction .. ":" .. char
    WhoDAT_AuctionDB = WhoDAT_AuctionDB or {}
    local bucket = WhoDAT_AuctionDB[key] or {}
    TA_UpsertRow_Dedup(bucket, r) -- <-- use dedup wrapper
    WhoDAT_AuctionDB[key] = bucket
  end
  f:SetScript("OnEvent", function()
    local list = "owner"
    local n = GetNumAuctionItems(list)
    for i = 1, n do
      local rec = TrackerAuction.NormalizeAuctionRow(list, i)
      if rec then appendOwnerRow(rec) end
    end
  end)
end

-- ===== AutoScan Orchestrator (runs once per AH open) =====
do
  local f = CreateFrame("Frame")
  f:RegisterEvent("AUCTION_HOUSE_SHOW")
  f:RegisterEvent("AUCTION_HOUSE_CLOSED")
  f:RegisterEvent("AUCTION_OWNED_LIST_UPDATE")
  local LAST_MARKET_SCAN_TS = 0
  local THROTTLE = 30 -- seconds min between auto-scans
  local PENDING_AFTER_OWNED = false
  local AUTO_SCAN_ACTIVE = false

  local function canRunAutoScan()
    if AUTO_SCAN_ACTIVE then return false end
    local now = time()
    if (now - LAST_MARKET_SCAN_TS) < THROTTLE then return false end
    return true
  end

  local function startAutoScan(reason)
    if not canRunAutoScan() then return end
    AUTO_SCAN_ACTIVE = true
    TA_AnnounceScanStartedOnce()
    local function waitOwner(maxWait)
      local deadline = time() + (maxWait or 6)
      local function pollOwner()
        local n = GetNumAuctionItems("owner") or 0
        if n > 0 then
          TrackerAuction.ScanMyAuctionsWithMarket({persistTS=true}, function()
            LAST_MARKET_SCAN_TS = time()
            AUTO_SCAN_ACTIVE = false
            TA_SessionGC()
            TA_AnnounceScanCompletedOnce()
          end)
          return
        end
        if time() >= deadline then
          TrackerAuction.ScanMyAuctionsWithMarket({persistTS=true}, function()
            LAST_MARKET_SCAN_TS = time()
            AUTO_SCAN_ACTIVE = false
            TA_SessionGC()
            TA_AnnounceScanCompletedOnce()
          end)
          return
        end
        TA_After(0.25, pollOwner)
      end
      pollOwner()
    end
    TA_WaitForCanQuery(5, function() waitOwner(6) end)
  end

  f:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_SHOW" then
      PENDING_AFTER_OWNED = true
      TA_After(0.5, function() startAutoScan("AUCTION_HOUSE_SHOW") end)
    elseif event == "AUCTION_OWNED_LIST_UPDATE" then
      if PENDING_AFTER_OWNED then
        PENDING_AFTER_OWNED = false
        startAutoScan("OWNED_LIST_UPDATE")
      end
    elseif event == "AUCTION_HOUSE_CLOSED" then
      AUTO_SCAN_ACTIVE = false
      PENDING_AFTER_OWNED = false
    end
  end)
end

-- ===== QuerySafeName helper =====
function TrackerAuction.QuerySafeName(name)
  if type(name) ~= "string" or #name == 0 then return nil end
  local s = name:lower()
  if #s > 63 then s = string.sub(s, 1, 63) end
  return s
end

-- ===== Scan wrapper (manual one-shot of the visible list) =====
function TrackerAuction.Scan(params, onComplete)
  if not TA_EnsureAuctionReady() then
    if type(onComplete) == "function" then onComplete({}, { error = "AuctionHouseNotReady" }) end
    return nil, "AuctionHouseNotReady"
  end
  -- Announce start once if not already in an orchestrated cycle
  TA_AnnounceScanStartedOnce()

  local list = "list"
  local numBatch, total = GetNumAuctionItems(list)
  local rows = {}
  for i = 1, numBatch do
    local rec = TrackerAuction.NormalizeAuctionRow(list, i)
    if rec and TrackerAuction._passes(rec, params) then
      if (not rec.sellerName or rec.sellerName == "") then
        local s = TA_ReadSellerFromBrowseRow(i)
        if s then rec.sellerName = s end
      end
      table.insert(rows, rec)
    end
  end
  if type(onComplete) == "function" then
    onComplete(rows, { source = "scan", totalFound = #rows, totalAuctions = total, finishedAt = time() })
  end
  -- For the simple wrapper, treat this as the full lifecycle
  TA_SessionGC()
  TA_AnnounceScanCompletedOnce()
  return true
end
-- ============================================================================
-- PATCH 1: MAIL DETECTION FOR AUCTION SALES
-- ============================================================================

-- Track auction sales via mail parsing
TrackerAuction.MailTracker = TrackerAuction.MailTracker or {}
local MailTracker = TrackerAuction.MailTracker

-- Parse auction house mail subject to extract item
local function ParseAuctionMail(mailIndex)
    local _, _, sender, subject, money = GetInboxHeaderInfo(mailIndex)
    
    -- AH mail sender check (localized)
    if not sender then return nil end
    local isAHMail = sender:find("Auctioneer") or sender:find("Auction House")
    if not isAHMail then return nil end
    
    -- Must have gold
    if not money or money == 0 then return nil end
    
    -- Try to get item name from subject
    -- Subject formats vary by locale:
    -- English: "Auction successful: ItemName"
    -- Need to extract ItemName
    local itemName = subject and subject:match(":%s*(.+)") or subject
    
    -- Get actual item from mail attachment (more reliable)
    local itemLink = GetInboxItemLink(mailIndex, 1)
    if itemLink then
        -- Extract item name from link
        itemName = itemLink:match("%[(.+)%]") or itemName
    end
    
    return {
        item_name = itemName,
        item_link = itemLink or itemName,
        gold_received = money,
        ts = time()
    }
end

-- Scan inbox for auction sales
function MailTracker:ScanInbox()
    local numMail = GetInboxNumItems()
    if numMail == 0 then return end
    
    local sales = {}
    
    for i = 1, numMail do
        local saleData = ParseAuctionMail(i)
        if saleData then
            table.insert(sales, saleData)
            
            -- Mark the auction as sold in our data
            self:MarkAuctionSold(saleData)
        end
    end
    
    return sales
end

-- Mark an auction as sold based on item match
function MailTracker:MarkAuctionSold(saleData)
    -- Find in WhoDAT_AuctionDB
    local realm  = GetRealmName() or "UNKNOWN"
    local faction= UnitFactionGroup("player") or "Neutral"
    local char   = UnitName("player") or "UNKNOWN"
    local key    = realm .. "-" .. faction .. ":" .. char
    
    if not WhoDAT_AuctionDB or not WhoDAT_AuctionDB[key] then
        return
    end
    
    local bucket = WhoDAT_AuctionDB[key]
    
    -- Find matching auction and mark it sold
    for i, auction in ipairs(bucket) do
        if auction.name == saleData.item_name and not auction.sold then
            auction.sold = true
            auction.sold_ts = saleData.ts
            auction.sold_price = saleData.gold_received
            
            -- Log it
            print(string.format("[WhoDAT] Auction SOLD: %s for %dg %ds %dc", 
                saleData.item_name,
                math.floor(saleData.gold_received / 10000),
                math.floor((saleData.gold_received % 10000) / 100),
                saleData.gold_received % 100
            ))
            
            break
        end
    end
end

-- ============================================================================
-- PATCH 2: SNAPSHOT COMPARISON FOR SOLD/EXPIRED DETECTION
-- ============================================================================

-- Store previous auction snapshot for comparison
TrackerAuction.previousAuctions = TrackerAuction.previousAuctions or {}

-- Compare auction snapshots to detect sales/expirations
function TrackerAuction.DetectAuctionChanges(currentAuctions)
    local sold = {}
    local expired = {}
    
    -- Create lookup table for current auctions using unique key
    local currentLookup = {}
    for _, auction in ipairs(currentAuctions) do
        -- Use multiple fields to create unique key
        local key = string.format("%d_%d_%d_%d", 
            auction.itemId or 0,
            auction.stackSize or 1,
            auction.buyoutPrice or 0,
            auction.duration or 0
        )
        currentLookup[key] = auction
    end
    
    -- Check previous auctions against current
    for _, prevAuction in ipairs(TrackerAuction.previousAuctions) do
        local key = string.format("%d_%d_%d_%d", 
            prevAuction.itemId or 0,
            prevAuction.stackSize or 1,
            prevAuction.buyoutPrice or 0,
            prevAuction.duration or 0
        )
        
        if not currentLookup[key] then
            -- Auction is gone - determine if sold or expired
            local timeLeft = prevAuction.duration or 4
            local hoursSince = (time() - (prevAuction.ts or time())) / 3600
            
            -- Duration: 1=short(2h), 2=medium(8h), 3=long(24h), 4=very long(48h)
            local maxHours = {[1]=2, [2]=8, [3]=24, [4]=48}
            local expectedExpiry = maxHours[timeLeft] or 48
            
            if hoursSince >= (expectedExpiry - 0.5) then -- Allow 30min grace period
                -- Likely expired
                table.insert(expired, prevAuction)
            else
                -- Likely sold (disappeared before expiry)
                table.insert(sold, prevAuction)
            end
        end
    end
    
    -- Update previous snapshot
    TrackerAuction.previousAuctions = currentAuctions
    
    return sold, expired
end

-- Hook into the owner auction update to detect changes
function TrackerAuction.UpdateOwnerAuctionsWithChangeDetection()
    local currentAuctions, numOwner = TA_ReadOwnerRows()
    
    -- Detect what changed
    local sold, expired = TrackerAuction.DetectAuctionChanges(currentAuctions)
    
    -- Mark sold auctions in database
    local realm  = GetRealmName() or "UNKNOWN"
    local faction= UnitFactionGroup("player") or "Neutral"
    local char   = UnitName("player") or "UNKNOWN"
    local key    = realm .. "-" .. faction .. ":" .. char
    
    if WhoDAT_AuctionDB and WhoDAT_AuctionDB[key] then
        local bucket = WhoDAT_AuctionDB[key]
        
        -- Mark sold
        for _, soldAuction in ipairs(sold) do
            for i, auction in ipairs(bucket) do
                if auction.itemId == soldAuction.itemId 
                   and auction.stackSize == soldAuction.stackSize
                   and not auction.sold 
                   and not auction.expired then
                    auction.sold = true
                    auction.sold_ts = time()
                    print(string.format("[WhoDAT] Detected SOLD (snapshot): %s", auction.name or "Unknown"))
                    break
                end
            end
        end
        
        -- Mark expired
        for _, expiredAuction in ipairs(expired) do
            for i, auction in ipairs(bucket) do
                if auction.itemId == expiredAuction.itemId 
                   and auction.stackSize == expiredAuction.stackSize
                   and not auction.sold 
                   and not auction.expired then
                    auction.expired = true
                    auction.expired_ts = time()
                    print(string.format("[WhoDAT] Detected EXPIRED (snapshot): %s", auction.name or "Unknown"))
                    break
                end
            end
        end
    end
    
    return currentAuctions, numOwner
end

-- ============================================================================
-- PATCH 3: EVENT REGISTRATION FOR MAIL SCANNING
-- ============================================================================

-- Create frame to listen for mail events
local mailFrame = CreateFrame("Frame")
mailFrame:RegisterEvent("MAIL_INBOX_UPDATE")
mailFrame:RegisterEvent("MAIL_CLOSED")

mailFrame:SetScript("OnEvent", function(self, event)
    if event == "MAIL_INBOX_UPDATE" then
        -- Scan inbox for auction sales
        if TrackerAuction.MailTracker and TrackerAuction.MailTracker.ScanInbox then
            TrackerAuction.MailTracker:ScanInbox()
        end
    end
end)

-- Also hook into the existing AUCTION_OWNED_LIST_UPDATE to detect changes
local existingFrame = CreateFrame("Frame")
existingFrame:RegisterEvent("AUCTION_OWNED_LIST_UPDATE")
existingFrame:SetScript("OnEvent", function(self, event)
    if event == "AUCTION_OWNED_LIST_UPDATE" then
        -- Call the change detection function
        TrackerAuction.UpdateOwnerAuctionsWithChangeDetection()
    end
end)

print("[WhoDAT] Auction sold/expired tracking initialized")