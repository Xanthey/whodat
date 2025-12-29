-- memory_management_patches.lua
-- WhoDAT - Memory management improvements for Phase 2C
-- Fixes memory leaks and unbounded growth issues
-- 
-- FIXES:
-- 1. Add GC to tracker_auction.lua SESSION_SEEN table
-- 2. Release texture pool when graph tabs hidden

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- FIX #1: Auction SESSION_SEEN Garbage Collection
-- ============================================================================

--[[
PROBLEM: tracker_auction.lua's SESSION_SEEN table grows unbounded during 
         long sessions, causing memory leak.
         
SOLUTION: Add periodic GC that purges entries >10 minutes old.
          Already has GC on line 167-172, but only runs during scan.
          We add a background timer to run GC every 60 seconds.

INTEGRATION: Patch TrackerAuction module if it exists
]]


local function PatchAuctionSessionGC()
  if not _G.TrackerAuction then
    if NS.Log then
      NS.Log("DEBUG", "TrackerAuction not loaded, skipping SESSION_SEEN GC patch")
    end
    return
  end
  
  -- We can't directly access local SESSION_SEEN from tracker_auction.lua,
  -- so rely on a public GC function exposed by TrackerAuction instead.
  if type(_G.TrackerAuction.SessionGC) ~= "function" then
    if NS.Log then
      NS.Log("WARN", "TrackerAuction.SessionGC not found - SESSION_SEEN GC not available")
      NS.Log("WARN", "Consider adding public GC function to tracker_auction.lua")
    end
    return
  end

  -- GC interval in seconds
  local GC_INTERVAL = 60

  -- Wrapper to safely invoke the public GC
  local function runGC()
    local ok, err = pcall(function()
      _G.TrackerAuction.SessionGC()
    end)
    if not ok and NS.Log then
      NS.Log("ERROR", "SESSION_SEEN GC failed: %s", tostring(err))
    end
  end

  -- Always use manual frame timer (Wrath-safe, simpler)
  local gcFrame = CreateFrame("Frame")
  local gcElapsed = 0

  gcFrame:SetScript("OnUpdate", function(self, delta)
    gcElapsed = gcElapsed + delta
    if gcElapsed >= GC_INTERVAL then
      gcElapsed = 0
      runGC()
    end
  end)

  if NS.Log then
       NS.Log("INFO", "SESSION_SEEN GC timer installed (frame-based, every %ds)", GC_INTERVAL)
  end
end

-- ============================================================================
-- FIX #2: Graph Texture Pool Cleanup
-- ============================================================================

--[[
PROBLEM: graphs.lua creates texture pool that stays in memory when graphs 
         are hidden, causing unnecessary memory usage.
         
SOLUTION: Hide all textures when graph panel not visible, allowing WoW's 
          GC to reclaim memory.

INTEGRATION: Hook into UI tab switching to detect when graphs hidden
]]

local function PatchGraphTexturePool()
  -- Hook into sparkline frames to add cleanup behavior
  
  if not NS.CreateSparkline then
    if NS.Log then
      NS.Log("DEBUG", "CreateSparkline not found, skipping texture pool patch")
    end
    return
  end
  
  -- Wrap CreateSparkline to add OnHide cleanup
  local original_CreateSparkline = NS.CreateSparkline
  
  NS.CreateSparkline = function(parent, width, height, r, g, b, a)
    local frame = original_CreateSparkline(parent, width, height, r, g, b, a)
    
    -- Add OnHide script to cleanup textures
    frame:HookScript("OnHide", function(self)
      -- Hide all texture columns to free memory
      if self.columns then
        for i = 1, #self.columns do
          local tex = self.columns[i]
          if tex and tex.Hide then
            tex:Hide()
          end
        end
      end
      
      -- Clear index map
      self._indexMap = nil
    end)
    
    -- Add OnShow script to restore visibility (Render will handle this)
    frame:HookScript("OnShow", function(self)
      -- Render will restore textures when needed
      if self.Render then
        self:Render()
      end
    end)
    
    return frame
  end
  
  if NS.Log then
    NS.Log("INFO", "Graph texture pool cleanup installed")
  end
end

-- ============================================================================
-- Additional Memory Optimization: Series Pruning
-- ============================================================================

--[[
OPTIONAL: Add pruning for very old series data to prevent unbounded growth.
This is more aggressive than compaction and should be opt-in via config.
]]

local function PruneOldSeriesData()
  local cfg = WhoDAT_Config and WhoDAT_Config.memory
  if not cfg or not cfg.prune_old_series then return end
  
  local max_age_days = cfg.max_series_age_days or 90
  local max_age_sec = max_age_days * 24 * 60 * 60
  local cutoff_ts = time() - max_age_sec
  
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if not C or not C.series then return end
  
  local pruned_count = 0
  
  for series_name, series_data in pairs(C.series) do
    if type(series_data) == "table" and #series_data > 0 then
      local new_series = {}
      
      for i = 1, #series_data do
        local point = series_data[i]
        local ts = tonumber(point.ts or 0) or 0
        
        if ts >= cutoff_ts then
          table.insert(new_series, point)
        else
          pruned_count = pruned_count + 1
        end
      end
      
      -- Replace series if we pruned anything
      if #new_series < #series_data then
        C.series[series_name] = new_series
      end
    end
  end
  
  if pruned_count > 0 and NS.Log then
    NS.Log("INFO", "Pruned %d old series points (older than %d days)", 
      pruned_count, max_age_days)
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Force garbage collection on all managed resources
function NS.Memory_ForceGC()
  -- Run auction SESSION_SEEN GC
  if _G.TrackerAuction and _G.TrackerAuction.SessionGC then
    pcall(_G.TrackerAuction.SessionGC)
  end
  
  -- Prune old series data if enabled
  PruneOldSeriesData()
  
  -- Force Lua GC
  collectgarbage("collect")
  
  if NS.Log then
    NS.Log("INFO", "Manual garbage collection completed")
  end
end

--- Get memory statistics
function NS.Memory_GetStats()
  local stats = {
    lua_memory_kb = collectgarbage("count"),
    addon_name = ADDON_NAME,
  }
  
  -- Count SESSION_SEEN entries if accessible
  -- (This would need TrackerAuction to expose it)
  
  -- Count texture pool size
  if NS.Graphs and NS.Graphs._sparklines then
    local total_textures = 0
    for _, sparkline in pairs(NS.Graphs._sparklines) do
      if sparkline.columns then
        total_textures = total_textures + #sparkline.columns
      end
    end
    stats.graph_textures = total_textures
  end
  
  -- Count series data points
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if C and C.series then
    local total_points = 0
    for _, series_data in pairs(C.series) do
      if type(series_data) == "table" then
        total_points = total_points + #series_data
      end
    end
    stats.series_points = total_points
  end
  
  return stats
end

-- ============================================================================
-- Installation
-- ============================================================================

local function InstallMemoryPatches()
  PatchAuctionSessionGC()
  PatchGraphTexturePool()
  
  if NS.Log then
    NS.Log("INFO", "Memory management patches installed")
  end
end

-- Install on PLAYER_LOGIN
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    InstallMemoryPatches()
  end
end)

-- ============================================================================
-- Slash Commands
-- ============================================================================

SLASH_WDMEMORY1 = "/wdmemory"
SLASH_WDMEMORY2 = "/wdmem"
SlashCmdList["WDMEMORY"] = function(msg)
  msg = (msg or ""):lower():trim()
  
  if msg == "gc" then
    NS.Memory_ForceGC()
    print("[WhoDAT] Forced garbage collection")
    
  elseif msg == "stats" then
    local stats = NS.Memory_GetStats()
    print("[WhoDAT] Memory Statistics:")
    print(string.format("  Lua Memory: %.2f MB", stats.lua_memory_kb / 1024))
    if stats.graph_textures then
      print(string.format("  Graph Textures: %d", stats.graph_textures))
    end
    if stats.series_points then
      print(string.format("  Series Points: %d", stats.series_points))
    end
    
  elseif msg == "prune" then
    PruneOldSeriesData()
    print("[WhoDAT] Old series data pruned (if enabled)")
    
  else
    print("=== WhoDAT Memory Management ===")
    print("/wdmem gc    - Force garbage collection")
    print("/wdmem stats - Show memory statistics")
    print("/wdmem prune - Prune old series data")
  end
end

-- ============================================================================
-- PATCH CODE for tracker_auction.lua
-- ============================================================================

--[[
ADD TO tracker_auction.lua (after line 172):

-- PUBLIC: Expose GC for external callers (memory management)
function TrackerAuction.SessionGC()
  TA_SessionGC()
end

This allows memory_management_patches.lua to call the GC function.
]]

-- ============================================================================
-- CONFIGURATION
-- ============================================================================

--[[
ADD TO config.lua:

WhoDAT_Config.memory = {
  prune_old_series = false, -- set true to enable automatic pruning
  max_series_age_days = 90,  -- prune data older than this
}
]]

return NS