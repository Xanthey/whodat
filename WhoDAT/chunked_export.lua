-- chunked_export.lua
-- WhoDAT - Non-blocking chunked export with progress feedback
-- Prevents UI freezes during large exports by yielding between chunks
-- Wrath 3.3.5a compatible

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Configuration
-- ============================================================================

local CHUNK_DELAY = 0.05 -- seconds between chunks (50ms for smooth UI)
local COMPRESSION_ENABLED = false -- set true if LibDeflate is available

-- ============================================================================
-- Compression Support (Optional LibDeflate)
-- ============================================================================

local LibDeflate
do
  local ok, LD = pcall(function() return LibStub and LibStub("LibDeflate", true) end)
  if ok and LD then
    LibDeflate = LD
    COMPRESSION_ENABLED = true
  end
end

local function compressString(str)
  if not COMPRESSION_ENABLED or not LibDeflate then return str end
  local ok, compressed = pcall(function()
    return LibDeflate:CompressDeflate(str, {level = 6})
  end)
  if ok and compressed then return compressed end
  return str -- fallback
end

local function decompressString(str)
  if not COMPRESSION_ENABLED or not LibDeflate then return str end
  local ok, decompressed = pcall(function()
    return LibDeflate:DecompressDeflate(str)
  end)
  if ok and decompressed then return decompressed end
  return str -- fallback
end

-- ============================================================================
-- Chunk Generators
-- ============================================================================

local ChunkGenerators = {}

-- Chunk 1: Identity and Metadata
function ChunkGenerators.identity()
  local identity = WhoDatDB and WhoDatDB.identity or {}
  local schema = WhoDatDB and WhoDatDB.schema or {}
  
  return {
    chunk_id = "identity",
    version = WhoDAT_Config and WhoDAT_Config.version or "unknown",
    schema = schema,
    identity = identity,
    generated_ts = time(),
  }
end

-- Chunk 2: Core Series (money, xp, level, rested, honor)
function ChunkGenerators.series_core()
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if not C or not C.series then return { chunk_id = "series_core", data = {} } end
  
  return {
    chunk_id = "series_core",
    data = {
      money = C.series.money or {},
      xp = C.series.xp or {},
      level = C.series.level or {},
      rested = C.series.rested or {},
      honor = C.series.honor or {},
    }
  }
end

-- Chunk 3: Base Stats Series
function ChunkGenerators.series_base_stats()
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if not C or not C.series then return { chunk_id = "series_base_stats", data = {} } end
  
  return {
    chunk_id = "series_base_stats",
    data = {
      base_stats = C.series.base_stats or {},
    }
  }
end

-- Chunk 4: Combat Series (attack, power, defense)
function ChunkGenerators.series_combat()
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if not C or not C.series then return { chunk_id = "series_combat", data = {} } end
  
  return {
    chunk_id = "series_combat",
    data = {
      attack = C.series.attack or {},
      power = C.series.power or {},
      defense = C.series.defense or {},
    }
  }
end

-- Chunk 5: Other Series (currency, achievements, arena, zones)
function ChunkGenerators.series_other()
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if not C or not C.series then return { chunk_id = "series_other", data = {} } end
  
  return {
    chunk_id = "series_other",
    data = {
      currency = C.series.currency or {},
      zones = C.series.zones or {},
      resource_max = C.series.resource_max or {},
      spell_ranged = C.series.spell_ranged or {},
    }
  }
end

-- Chunk 6: Containers (bags, bank, mailbox)
function ChunkGenerators.containers()
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if not C or not C.containers then return { chunk_id = "containers", data = {} } end
  
  return {
    chunk_id = "containers",
    data = {
      bags = C.containers.bags or {},
      bank = C.containers.bank or {},
      keyring = C.containers.keyring or {},
      mailbox = C.containers.mailbox or {},
    }
  }
end

-- Chunk 7: Item Catalog
function ChunkGenerators.items_catalog()
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if not C or not C.catalogs then return { chunk_id = "items_catalog", data = {} } end
  
  return {
    chunk_id = "items_catalog",
    data = C.catalogs.items_catalog or {},
  }
end

-- Chunk 8: Events (container, session, items, quests, achievements)
function ChunkGenerators.events()
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if not C or not C.events then return { chunk_id = "events", data = {} } end
  
  return {
    chunk_id = "events",
    data = C.events or {},
  }
end

-- Chunk 9: Sessions
function ChunkGenerators.sessions()
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if not C or not C.sessions then return { chunk_id = "sessions", data = {} } end
  
  return {
    chunk_id = "sessions",
    data = C.sessions or {},
  }
end

-- Chunk 10: Snapshots (equipment, quests, talents, etc.)
function ChunkGenerators.snapshots()
  local key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
  
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  if not C or not C.snapshots then return { chunk_id = "snapshots", data = {} } end
  
  return {
    chunk_id = "snapshots",
    data = C.snapshots or {},
  }
end

-- ============================================================================
-- Chunked Export Engine
-- ============================================================================

local ExportState = {
  active = false,
  current_chunk = 0,
  total_chunks = 0,
  chunks = {},
  callback = nil,
  start_time = 0,
}

local CHUNK_ORDER = {
  "identity",
  "series_core",
  "series_base_stats",
  "series_combat",
  "series_other",
  "containers",
  "items_catalog",
  "events",
  "sessions",
  "snapshots",
}

-- Progress callback (optional, for UI feedback)
local function notifyProgress(current, total, chunk_id)
  if ExportState.callback then
    pcall(ExportState.callback, current, total, chunk_id)
  end
  
  -- Also log to chat if verbose
  if NS.Log then
    NS.Log("DEBUG", "Export progress: %d/%d (%s)", current, total, chunk_id or "unknown")
  end
end

-- Process next chunk (recursive with C_Timer.After for yielding)
local function processNextChunk()
  if not ExportState.active then return end
  
  ExportState.current_chunk = ExportState.current_chunk + 1
  local idx = ExportState.current_chunk
  
  if idx > ExportState.total_chunks then
    -- Export complete!
    ExportState.active = false
    local elapsed = time() - ExportState.start_time
    
    if NS.Log then
      NS.Log("INFO", "Chunked export completed in %d seconds", elapsed)
    end
    
    notifyProgress(ExportState.total_chunks, ExportState.total_chunks, "complete")
    return
  end
  
  -- Generate chunk
  local chunk_id = CHUNK_ORDER[idx]
  local generator = ChunkGenerators[chunk_id]
  
  if not generator then
    -- Skip unknown chunks
    if NS.Log then
      NS.Log("WARN", "Skipping unknown chunk: %s", tostring(chunk_id))
    end
    
    -- Schedule next chunk immediately
    if C_Timer and C_Timer.After then
      C_Timer.After(0, processNextChunk)
    else
      processNextChunk() -- fallback: no yield
    end
    return
  end
  
  -- Execute generator
  local ok, chunk = pcall(generator)
  if not ok then
    if NS.Log then
      NS.Log("ERROR", "Chunk generator failed for %s: %s", chunk_id, tostring(chunk))
    end
    chunk = { chunk_id = chunk_id, error = tostring(chunk), data = {} }
  end
  
  -- Store chunk
  ExportState.chunks[chunk_id] = chunk
  
  -- Notify progress
  notifyProgress(idx, ExportState.total_chunks, chunk_id)
  
  -- Yield to UI, then process next
  if C_Timer and C_Timer.After then
    C_Timer.After(CHUNK_DELAY, processNextChunk)
  else
    -- No C_Timer: process immediately (blocking, but better than nothing)
    processNextChunk()
  end
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Start chunked export (non-blocking)
-- @param progressCallback function(current, total, chunk_id) - optional progress updates
function NS.Export_StartChunked(progressCallback)
  if ExportState.active then
    if NS.Log then
      NS.Log("WARN", "Chunked export already in progress")
    end
    return false
  end
  
  -- Initialize state
  ExportState.active = true
  ExportState.current_chunk = 0
  ExportState.total_chunks = #CHUNK_ORDER
  ExportState.chunks = {}
  ExportState.callback = progressCallback
  ExportState.start_time = time()
  
  if NS.Log then
    NS.Log("INFO", "Starting chunked export (%d chunks)", ExportState.total_chunks)
  end
  
  -- Kick off first chunk
  if C_Timer and C_Timer.After then
    C_Timer.After(0, processNextChunk)
  else
    processNextChunk() -- fallback: blocking
  end
  
  return true
end

--- Check if export is active
function NS.Export_IsActive()
  return ExportState.active
end

--- Get current export progress
-- @return current, total, percent
function NS.Export_GetProgress()
  return ExportState.current_chunk, ExportState.total_chunks, 
    (ExportState.total_chunks > 0 and (ExportState.current_chunk / ExportState.total_chunks * 100) or 0)
end

--- Get completed chunks (returns table of chunk_id -> chunk_data)
function NS.Export_GetChunks()
  return ExportState.chunks
end

--- Cancel active export
function NS.Export_CancelChunked()
  if ExportState.active then
    ExportState.active = false
    if NS.Log then
      NS.Log("INFO", "Chunked export cancelled")
    end
  end
end

--- Serialize chunks to string (for file save or transmission)
-- @param compress boolean - use LibDeflate compression if available
-- @return string serialized data
function NS.Export_SerializeChunks(compress)
  local data = {
    version = WhoDAT_Config and WhoDAT_Config.version or "unknown",
    generated_ts = time(),
    compressed = compress and COMPRESSION_ENABLED or false,
    chunks = ExportState.chunks,
  }
  
  -- Serialize using Blizzard's Serializer if available (more robust than manual)
  local serialized
  if AceSerializer then
    serialized = AceSerializer:Serialize(data)
  else
    -- Fallback: manual table serialization (less robust)
    serialized = NS.Export_TableToString(data)
  end
  
  if compress and COMPRESSION_ENABLED then
    serialized = compressString(serialized)
  end
  
  return serialized
end

--- Simple table-to-string serializer (fallback, not recommended for large data)
function NS.Export_TableToString(tbl, indent)
  indent = indent or 0
  local result = {}
  local prefix = string.rep("  ", indent)
  
  table.insert(result, "{\n")
  
  for k, v in pairs(tbl) do
    local key = type(k) == "string" and string.format("[%q]", k) or string.format("[%d]", k)
    local value
    
    if type(v) == "table" then
      value = NS.Export_TableToString(v, indent + 1)
    elseif type(v) == "string" then
      value = string.format("%q", v)
    else
      value = tostring(v)
    end
    
    table.insert(result, prefix .. "  " .. key .. " = " .. value .. ",\n")
  end
  
  table.insert(result, prefix .. "}")
  return table.concat(result)
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

SLASH_WDEXPORTCHUNK1 = "/wdexportchunk"
SLASH_WDEXPORTCHUNK2 = "/wdec"
SlashCmdList["WDEXPORTCHUNK"] = function(msg)
  msg = (msg or ""):lower():trim()
  
  if msg == "start" then
    local callback = function(current, total, chunk_id)
      print(string.format("[WhoDAT] Export: %d/%d (%s)", current, total, chunk_id or "?"))
    end
    
    NS.Export_StartChunked(callback)
    print("[WhoDAT] Chunked export started (watch chat for progress)")
    
  elseif msg == "cancel" then
    NS.Export_CancelChunked()
    print("[WhoDAT] Export cancelled")
    
  elseif msg == "status" then
    if NS.Export_IsActive() then
      local current, total, percent = NS.Export_GetProgress()
      print(string.format("[WhoDAT] Export active: %d/%d (%.1f%%)", current, total, percent))
    else
      print("[WhoDAT] No export active")
    end
    
  elseif msg == "chunks" then
    local chunks = NS.Export_GetChunks()
    print("[WhoDAT] Completed chunks:")
    for id, chunk in pairs(chunks) do
      print(string.format("  - %s", id))
    end
    
  else
    print("=== WhoDAT Chunked Export Commands ===")
    print("/wdec start   - Start chunked export")
    print("/wdec cancel  - Cancel active export")
    print("/wdec status  - Show export progress")
    print("/wdec chunks  - List completed chunks")
  end
end

-- ============================================================================
-- Integration with main export
-- ============================================================================

-- Hook into main export to use chunked export by default
if NS.Export_Now then
  NS.Export_Now_Original = NS.Export_Now
  
  function NS.Export_Now()
    -- Check if chunked export is enabled in config
    local use_chunked = WhoDAT_Config and WhoDAT_Config.export and WhoDAT_Config.export.use_chunked
    
    if use_chunked ~= false then
      -- Use chunked export by default
      NS.Export_StartChunked()
    else
      -- Fallback to original export
      NS.Export_Now_Original()
    end
  end
end

return NS