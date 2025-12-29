-- profiler.lua
-- WhoDAT - Performance profiler for identifying bottlenecks
-- Optional, toggled via config, minimal overhead when disabled
-- Tracks function execution times, call counts, and memory usage

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Configuration
-- ============================================================================

local PROFILER_ENABLED = false  -- Toggle via /wdprofile enable
local PROFILE_THRESHOLD_MS = 10  -- Only log functions slower than this
local MAX_PROFILE_ENTRIES = 100  -- Limit stored profiles

-- ============================================================================
-- Profiler State
-- ============================================================================

local ProfileData = {
  functions = {},  -- function_name -> { calls, total_time, min_time, max_time }
  sessions = {},   -- profiling sessions
  active = false,
}

-- ============================================================================
-- Timer Utilities
-- ============================================================================

local getTime = debugprofilestop or function() return GetTime() * 1000 end

-- ============================================================================
-- Function Profiling
-- ============================================================================

--- Start profiling a function
-- @param func_name string - Name of the function
-- @return start_time number - Timestamp in milliseconds
local function profileStart(func_name)
  if not PROFILER_ENABLED then return 0 end
  return getTime()
end

--- End profiling a function
-- @param func_name string - Name of the function
-- @param start_time number - Timestamp from profileStart
local function profileEnd(func_name, start_time)
  if not PROFILER_ENABLED or start_time == 0 then return end
  
  local elapsed = getTime() - start_time
  
  -- Only record if above threshold
  if elapsed < PROFILE_THRESHOLD_MS then return end
  
  -- Initialize entry if needed
  ProfileData.functions[func_name] = ProfileData.functions[func_name] or {
    calls = 0,
    total_time = 0,
    min_time = math.huge,
    max_time = 0,
    avg_time = 0,
  }
  
  local entry = ProfileData.functions[func_name]
  
  -- Update statistics
  entry.calls = entry.calls + 1
  entry.total_time = entry.total_time + elapsed
  entry.min_time = math.min(entry.min_time, elapsed)
  entry.max_time = math.max(entry.max_time, elapsed)
  entry.avg_time = entry.total_time / entry.calls
end

--- Wrap a function with profiling
-- @param func_name string - Name for profiling
-- @param func function - Function to wrap
-- @return function wrapped function
local function wrapFunction(func_name, func)
  return function(...)
    local start_time = profileStart(func_name)
    local results = {pcall(func, ...)}
    profileEnd(func_name, start_time)
    
    if results[1] then
      -- Success, return actual results (skip success flag)
      return select(2, unpack(results))
    else
      -- Error, re-raise
      error(results[2], 2)
    end
  end
end

-- ============================================================================
-- Session Profiling
-- ============================================================================

local activeSession

--- Start a profiling session
local function startSession(name)
  activeSession = {
    name = name or "Unnamed Session",
    start_time = time(),
    start_time_ms = getTime(),
    functions = {},
  }
  
  ProfileData.active = true
  PROFILER_ENABLED = true
end

--- End a profiling session
local function endSession()
  if not activeSession then return nil end
  
  activeSession.end_time = time()
  activeSession.end_time_ms = getTime()
  activeSession.duration_ms = activeSession.end_time_ms - activeSession.start_time_ms
  activeSession.functions = ProfileData.functions
  
  -- Store session
  table.insert(ProfileData.sessions, activeSession)
  
  -- Limit sessions
  if #ProfileData.sessions > MAX_PROFILE_ENTRIES then
    table.remove(ProfileData.sessions, 1)
  end
  
  local session = activeSession
  activeSession = nil
  ProfileData.active = false
  
  return session
end

-- ============================================================================
-- Auto-Profiling (Key Functions)
-- ============================================================================

--- Auto-wrap common bottleneck functions
local function installAutoProfiles()
  if not PROFILER_ENABLED then return end
  
  -- Wrap export functions
  if NS.Export_Now_Blocking and not NS.Export_Now_Blocking._profiled then
    NS.Export_Now_Blocking = wrapFunction("Export_Now_Blocking", NS.Export_Now_Blocking)
    NS.Export_Now_Blocking._profiled = true
  end
  
  -- Wrap chunked export
  if NS.Export_StartChunked and not NS.Export_StartChunked._profiled then
    NS.Export_StartChunked = wrapFunction("Export_StartChunked", NS.Export_StartChunked)
    NS.Export_StartChunked._profiled = true
  end
  
  -- Wrap catalog generation
  -- Note: EnsureItemCatalog is local in export.lua, can't wrap directly
  -- Would need to be exposed or wrapped at call site
end

-- ============================================================================
-- Profiling Reports
-- ============================================================================

--- Get profiling summary
local function getProfileSummary()
  local summary = {
    total_functions = 0,
    total_calls = 0,
    total_time_ms = 0,
    slowest = nil,
    most_called = nil,
  }
  
  local slowest_time = 0
  local most_calls = 0
  
  for func_name, data in pairs(ProfileData.functions) do
    summary.total_functions = summary.total_functions + 1
    summary.total_calls = summary.total_calls + data.calls
    summary.total_time_ms = summary.total_time_ms + data.total_time
    
    if data.avg_time > slowest_time then
      slowest_time = data.avg_time
      summary.slowest = {
        name = func_name,
        avg_time = data.avg_time,
      }
    end
    
    if data.calls > most_calls then
      most_calls = data.calls
      summary.most_called = {
        name = func_name,
        calls = data.calls,
      }
    end
  end
  
  return summary
end

--- Get top N slowest functions
local function getTopSlowest(n)
  n = n or 10
  
  local list = {}
  for func_name, data in pairs(ProfileData.functions) do
    table.insert(list, {
      name = func_name,
      calls = data.calls,
      avg_time = data.avg_time,
      total_time = data.total_time,
      max_time = data.max_time,
    })
  end
  
  table.sort(list, function(a, b)
    return a.avg_time > b.avg_time
  end)
  
  local result = {}
  for i = 1, math.min(n, #list) do
    table.insert(result, list[i])
  end
  
  return result
end

--- Print profiling report
local function printReport()
  local summary = getProfileSummary()
  
  print("╔══════════════════════════════════════════╗")
  print("║  WhoDAT - Performance Profile           ║")
  print("╚══════════════════════════════════════════╝")
  print("")
  print(string.format("Functions Profiled: %d", summary.total_functions))
  print(string.format("Total Calls: %d", summary.total_calls))
  print(string.format("Total Time: %.2f ms", summary.total_time_ms))
  print("")
  
  if summary.slowest then
    print(string.format("Slowest Function: %s (%.2f ms avg)", 
      summary.slowest.name, summary.slowest.avg_time))
  end
  
  if summary.most_called then
    print(string.format("Most Called: %s (%d calls)", 
      summary.most_called.name, summary.most_called.calls))
  end
  
  print("")
  print("Top 10 Slowest Functions:")
  
  local top = getTopSlowest(10)
  for i, entry in ipairs(top) do
    print(string.format("  %d. %s", i, entry.name))
    print(string.format("     Avg: %.2f ms | Max: %.2f ms | Calls: %d", 
      entry.avg_time, entry.max_time, entry.calls))
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Enable profiler
function NS.Profiler_Enable()
  PROFILER_ENABLED = true
  installAutoProfiles()
  
  if NS.Log then
    NS.Log("INFO", "Profiler enabled")
  end
end

--- Disable profiler
function NS.Profiler_Disable()
  PROFILER_ENABLED = false
  
  if NS.Log then
    NS.Log("INFO", "Profiler disabled")
  end
end

--- Is profiler enabled?
function NS.Profiler_IsEnabled()
  return PROFILER_ENABLED
end

--- Start profiling session
function NS.Profiler_StartSession(name)
  startSession(name)
end

--- End profiling session
function NS.Profiler_EndSession()
  return endSession()
end

--- Reset profiling data
function NS.Profiler_Reset()
  ProfileData.functions = {}
  ProfileData.sessions = {}
  
  if NS.Log then
    NS.Log("INFO", "Profiler data reset")
  end
end

--- Get profiling summary
function NS.Profiler_GetSummary()
  return getProfileSummary()
end

--- Get top slowest functions
function NS.Profiler_GetTopSlowest(n)
  return getTopSlowest(n)
end

--- Print profiling report
function NS.Profiler_PrintReport()
  printReport()
end

--- Profile a function manually
-- Usage: local result = NS.Profiler_Run("MyFunction", myFunction, arg1, arg2)
function NS.Profiler_Run(func_name, func, ...)
  local start_time = profileStart(func_name)
  local results = {pcall(func, ...)}
  profileEnd(func_name, start_time)
  
  if results[1] then
    return select(2, unpack(results))
  else
    error(results[2], 2)
  end
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

SLASH_WDPROFILE1 = "/wdprofile"
SLASH_WDPROFILE2 = "/wdp"
SlashCmdList["WDPROFILE"] = function(msg)
  msg = (msg or ""):lower():trim()
  
  if msg == "enable" then
    NS.Profiler_Enable()
    print("[WhoDAT] Profiler enabled")
    
  elseif msg == "disable" then
    NS.Profiler_Disable()
    print("[WhoDAT] Profiler disabled")
    
  elseif msg == "status" then
    local enabled = NS.Profiler_IsEnabled()
    print(string.format("[WhoDAT] Profiler: %s", enabled and "ENABLED" or "DISABLED"))
    
    if enabled then
      local summary = getProfileSummary()
      print(string.format("  Functions: %d", summary.total_functions))
      print(string.format("  Calls: %d", summary.total_calls))
      print(string.format("  Time: %.2f ms", summary.total_time_ms))
    end
    
  elseif msg == "report" then
    if not NS.Profiler_IsEnabled() then
      print("[WhoDAT] Profiler is disabled")
      return
    end
    
    printReport()
    
  elseif msg == "reset" then
    NS.Profiler_Reset()
    print("[WhoDAT] Profiler data reset")
    
  elseif msg:match("^start") then
    local name = msg:match("start%s+(.+)")
    NS.Profiler_StartSession(name or "Manual Session")
    print("[WhoDAT] Profiling session started")
    
  elseif msg == "end" or msg == "stop" then
    local session = NS.Profiler_EndSession()
    
    if session then
      print(string.format("[WhoDAT] Session '%s' completed", session.name))
      print(string.format("  Duration: %.2f ms", session.duration_ms))
      print(string.format("  Functions: %d", NS.Utils and NS.Utils.TableCount 
        and NS.Utils.TableCount(session.functions) or 0))
    else
      print("[WhoDAT] No active session")
    end
    
  else
    print("=== WhoDAT Performance Profiler ===")
    print("/wdp enable      - Enable profiler")
    print("/wdp disable     - Disable profiler")
    print("/wdp status      - Show profiler status")
    print("/wdp report      - Print performance report")
    print("/wdp reset       - Reset profiler data")
    print("/wdp start [name] - Start profiling session")
    print("/wdp end         - End profiling session")
  end
end

-- ============================================================================
-- Configuration Hook
-- ============================================================================

-- Read configuration on load
if WhoDAT_Config and WhoDAT_Config.profiler then
  if WhoDAT_Config.profiler.enabled then
    NS.Profiler_Enable()
  end
  
  if WhoDAT_Config.profiler.threshold_ms then
    PROFILE_THRESHOLD_MS = WhoDAT_Config.profiler.threshold_ms
  end
end

return NS