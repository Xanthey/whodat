-- export_metadata.lua
-- WhoDAT - Export metadata with checksums for selective server-side ingestion
-- Enables server to detect changed chunks and skip unchanged data
-- Wrath 3.3.5a compatible

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Simple CRC32 Implementation (Wrath-safe, no external deps)
-- ============================================================================

local CRC32_TABLE = {}
do
  for i = 0, 255 do
    local crc = i
    for j = 1, 8 do
      crc = bit.band(crc, 1) == 1 
        and bit.bxor(bit.rshift(crc, 1), 0xEDB88320)
        or bit.rshift(crc, 1)
    end
    CRC32_TABLE[i] = crc
  end
end

local function crc32(str)
  if type(str) ~= "string" then str = tostring(str or "") end
  
  local crc = 0xFFFFFFFF
  for i = 1, #str do
    local byte = string.byte(str, i)
    local index = bit.band(bit.bxor(crc, byte), 0xFF)
    crc = bit.bxor(bit.rshift(crc, 8), CRC32_TABLE[index])
  end
  
  return bit.band(bit.bnot(crc), 0xFFFFFFFF)
end

-- ============================================================================
-- Hash Computation
-- ============================================================================

--- Compute stable hash for a table (deterministic serialization)
local function computeTableHash(tbl)
  if type(tbl) ~= "table" then return crc32(tostring(tbl or "")) end
  
  -- Collect and sort keys for deterministic ordering
  local keys = {}
  for k in pairs(tbl) do
    table.insert(keys, tostring(k))
  end
  table.sort(keys)
  
  -- Build serialized string
  local parts = {}
  for _, k in ipairs(keys) do
    local v = tbl[k]
    local vStr
    
    if type(v) == "table" then
      vStr = tostring(computeTableHash(v)) -- recursive
    elseif type(v) == "string" then
      vStr = v
    else
      vStr = tostring(v or "")
    end
    
    table.insert(parts, k .. "=" .. vStr)
  end
  
  local serialized = table.concat(parts, "|")
  return crc32(serialized)
end

--- Compute lightweight hash for array (fast path for series data)
local function computeArrayHash(arr)
  if type(arr) ~= "table" or #arr == 0 then return 0 end
  
  local sum = 0
  local count = #arr
  
  -- Sample: first, middle, last + length
  local samples = {
    arr[1],
    arr[math.floor(count / 2)],
    arr[count],
  }
  
  for _, item in ipairs(samples) do
    if type(item) == "table" then
      -- Hash key fields only (much faster than full table)
      local ts = tonumber(item.ts or 0) or 0
      local value = tonumber(item.value or item.val or item.hp or 0) or 0
      sum = sum + ts + value
    else
      sum = sum + tonumber(item or 0)
    end
  end
  
  -- Combine with count for uniqueness
  return crc32(string.format("%d:%d", count, sum))
end

-- ============================================================================
-- Metadata Generation
-- ============================================================================

local MetadataCache = {
  last_update = 0,
  chunk_hashes = {},
}

--- Generate metadata for all export chunks
-- @return table { chunk_id -> { hash, size, timestamp } }
function NS.Export_GenerateMetadata()
  local metadata = {
    version = WhoDAT_Config and WhoDAT_Config.version or "unknown",
    schema_version = WhoDAT_Config and WhoDAT_Config.schema and WhoDAT_Config.schema.catalog_version or 3,
    generated_ts = time(),
    character_key = NS.Utils and NS.Utils.GetPlayerKey and NS.Utils.GetPlayerKey()
      or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player")),
    chunks = {},
  }
  
  local key = metadata.character_key
  local C = WhoDatDB and WhoDatDB.characters and WhoDatDB.characters[key]
  
  if not C then return metadata end
  
  -- Identity chunk
  metadata.chunks.identity = {
    hash = computeTableHash(WhoDatDB.identity or {}),
    size = 0, -- not computed for efficiency
    ts = time(),
  }
  
  -- Series chunks (use lightweight array hash)
  if C.series then
    for _, series_name in ipairs({"money", "xp", "level", "rested", "honor"}) do
      local series = C.series[series_name]
      if series and #series > 0 then
        metadata.chunks["series_" .. series_name] = {
          hash = computeArrayHash(series),
          size = #series,
          ts = time(),
        }
      end
    end
    
    -- Base stats (full table hash - less frequent changes)
    if C.series.base_stats and #C.series.base_stats > 0 then
      metadata.chunks.series_base_stats = {
        hash = computeArrayHash(C.series.base_stats),
        size = #C.series.base_stats,
        ts = time(),
      }
    end
    
    -- Combat series
    for _, series_name in ipairs({"attack", "power", "defense"}) do
      local series = C.series[series_name]
      if series and #series > 0 then
        metadata.chunks["series_" .. series_name] = {
          hash = computeArrayHash(series),
          size = #series,
          ts = time(),
        }
      end
    end
  end
  
  -- Containers (use full hash - structure matters)
  if C.containers then
    for _, container_type in ipairs({"bags", "bank", "keyring", "mailbox"}) do
      local container = C.containers[container_type]
      if container then
        metadata.chunks["containers_" .. container_type] = {
          hash = computeTableHash(container),
          size = type(container) == "table" and #container or 0,
          ts = time(),
        }
      end
    end
  end
  
  -- Item catalog
  if C.catalogs and C.catalogs.items_catalog then
    metadata.chunks.items_catalog = {
      hash = computeTableHash(C.catalogs.items_catalog),
      size = #C.catalogs.items_catalog,
      ts = time(),
    }
  end
  
  -- Events
  if C.events then
    for event_type, events in pairs(C.events) do
      if type(events) == "table" and #events > 0 then
        metadata.chunks["events_" .. event_type] = {
          hash = computeArrayHash(events),
          size = #events,
          ts = time(),
        }
      end
    end
  end
  
  -- Sessions
  if C.sessions and #C.sessions > 0 then
    metadata.chunks.sessions = {
      hash = computeArrayHash(C.sessions),
      size = #C.sessions,
      ts = time(),
    }
  end
  
  -- Snapshots (full hash - complex structure)
  if C.snapshots then
    for snapshot_type, snapshot in pairs(C.snapshots) do
      if type(snapshot) == "table" then
        metadata.chunks["snapshot_" .. snapshot_type] = {
          hash = computeTableHash(snapshot),
          size = 0, -- not computed
          ts = time(),
        }
      end
    end
  end
  
  -- Cache for comparison
  MetadataCache.last_update = time()
  MetadataCache.chunk_hashes = {}
  for chunk_id, chunk_meta in pairs(metadata.chunks) do
    MetadataCache.chunk_hashes[chunk_id] = chunk_meta.hash
  end
  
  return metadata
end

--- Compare current metadata with cached to detect changes
-- @return table { changed = {chunk_ids}, unchanged = {chunk_ids} }
function NS.Export_CompareMetadata()
  local current = NS.Export_GenerateMetadata()
  local changed = {}
  local unchanged = {}
  
  for chunk_id, chunk_meta in pairs(current.chunks) do
    local cached_hash = MetadataCache.chunk_hashes[chunk_id]
    
    if cached_hash and cached_hash == chunk_meta.hash then
      table.insert(unchanged, chunk_id)
    else
      table.insert(changed, chunk_id)
    end
  end
  
  return {
    changed = changed,
    unchanged = unchanged,
    changed_count = #changed,
    unchanged_count = #unchanged,
  }
end

--- Serialize metadata to string (for transmission to server)
-- @return string JSON-like serialized metadata
function NS.Export_SerializeMetadata(metadata)
  metadata = metadata or NS.Export_GenerateMetadata()
  
  local lines = {}
  table.insert(lines, "{")
  table.insert(lines, string.format('  "version": %q,', metadata.version))
  table.insert(lines, string.format('  "schema_version": %d,', metadata.schema_version))
  table.insert(lines, string.format('  "generated_ts": %d,', metadata.generated_ts))
  table.insert(lines, string.format('  "character_key": %q,', metadata.character_key))
  table.insert(lines, '  "chunks": {')
  
  local chunk_lines = {}
  for chunk_id, chunk_meta in pairs(metadata.chunks) do
    local chunk_str = string.format('    %q: {"hash": %d, "size": %d, "ts": %d}',
      chunk_id, chunk_meta.hash, chunk_meta.size, chunk_meta.ts)
    table.insert(chunk_lines, chunk_str)
  end
  
  table.insert(lines, table.concat(chunk_lines, ",\n"))
  table.insert(lines, '  }')
  table.insert(lines, '}')
  
  return table.concat(lines, "\n")
end

-- ============================================================================
-- Integration with Chunked Export
-- ============================================================================

--- Export only changed chunks (selective export)
-- @param progressCallback function - optional progress updates
function NS.Export_StartSelectiveChunked(progressCallback)
  -- First, compare metadata
  local comparison = NS.Export_CompareMetadata()
  
  if #comparison.changed == 0 then
    if NS.Log then
      NS.Log("INFO", "No changes detected, skipping export")
    end
    if progressCallback then
      progressCallback(0, 0, "no_changes")
    end
    return false
  end
  
  if NS.Log then
    NS.Log("INFO", "Selective export: %d changed chunks, %d unchanged", 
      comparison.changed_count, comparison.unchanged_count)
  end
  
  -- TODO: Integrate with chunked_export.lua to only export changed chunks
  -- For now, just generate metadata and return
  return true
end

-- ============================================================================
-- Persistence (Save metadata to SavedVariables)
-- ============================================================================

--- Save metadata to SavedVariables for persistence across sessions
function NS.Export_SaveMetadata()
  WhoDatDB = WhoDatDB or {}
  WhoDatDB._metadata = WhoDatDB._metadata or {}
  
  local metadata = NS.Export_GenerateMetadata()
  WhoDatDB._metadata.last_export = {
    ts = time(),
    chunks = metadata.chunks,
  }
  
  if NS.Log then
    NS.Log("DEBUG", "Metadata saved to SavedVariables")
  end
end

--- Load metadata from SavedVariables
function NS.Export_LoadMetadata()
  if not WhoDatDB or not WhoDatDB._metadata or not WhoDatDB._metadata.last_export then
    return nil
  end
  
  local saved = WhoDatDB._metadata.last_export
  
  -- Restore cache
  MetadataCache.last_update = saved.ts or 0
  MetadataCache.chunk_hashes = {}
  
  for chunk_id, chunk_meta in pairs(saved.chunks or {}) do
    MetadataCache.chunk_hashes[chunk_id] = chunk_meta.hash
  end
  
  if NS.Log then
    NS.Log("DEBUG", "Metadata loaded from SavedVariables")
  end
  
  return saved
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

SLASH_WDEXPORTMETA1 = "/wdexportmeta"
SLASH_WDEXPORTMETA2 = "/wdem"
SlashCmdList["WDEXPORTMETA"] = function(msg)
  msg = (msg or ""):lower():trim()
  
  if msg == "generate" then
    local metadata = NS.Export_GenerateMetadata()
    print("[WhoDAT] Metadata generated:")
    print(string.format("  Version: %s", metadata.version))
    print(string.format("  Schema: v%d", metadata.schema_version))
    print(string.format("  Chunks: %d", NS.Utils and NS.Utils.TableCount and NS.Utils.TableCount(metadata.chunks) or 0))
    
  elseif msg == "compare" then
    local comparison = NS.Export_CompareMetadata()
    print("[WhoDAT] Metadata comparison:")
    print(string.format("  Changed: %d chunks", comparison.changed_count))
    print(string.format("  Unchanged: %d chunks", comparison.unchanged_count))
    
    if comparison.changed_count > 0 then
      print("  Changed chunks:")
      for _, chunk_id in ipairs(comparison.changed) do
        print(string.format("    - %s", chunk_id))
      end
    end
    
  elseif msg == "save" then
    NS.Export_SaveMetadata()
    print("[WhoDAT] Metadata saved to SavedVariables")
    
  elseif msg == "load" then
    local saved = NS.Export_LoadMetadata()
    if saved then
      print(string.format("[WhoDAT] Metadata loaded (last export: %s)", 
        date("%Y-%m-%d %H:%M:%S", saved.ts)))
    else
      print("[WhoDAT] No saved metadata found")
    end
    
  elseif msg == "serialize" then
    local metadata = NS.Export_GenerateMetadata()
    local serialized = NS.Export_SerializeMetadata(metadata)
    print("[WhoDAT] Serialized metadata (first 500 chars):")
    print(serialized:sub(1, 500))
    
  else
    print("=== WhoDAT Export Metadata Commands ===")
    print("/wdem generate  - Generate current metadata")
    print("/wdem compare   - Compare with cached metadata")
    print("/wdem save      - Save metadata to SavedVariables")
    print("/wdem load      - Load metadata from SavedVariables")
    print("/wdem serialize - Serialize metadata to string")
  end
end

-- ============================================================================
-- Auto-save on PLAYER_LOGOUT
-- ============================================================================

local MetadataFrame = CreateFrame("Frame")
MetadataFrame:RegisterEvent("PLAYER_LOGOUT")
MetadataFrame:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGOUT" then
    NS.Export_SaveMetadata()
  end
end)

-- Load metadata on addon load
NS.Export_LoadMetadata()

return NS