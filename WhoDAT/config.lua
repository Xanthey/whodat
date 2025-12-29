
-- config.lua
-- WhoDAT (Wrath 3.3.5a)
-- Centralized defaults, schema/versioning, feature flags, and bootstrap helpers.
-- ====================================================================================
-- SavedVariables (declared in .toc):
-- WhoDatDB, WhoDAT_AuctionDB, WhoDAT_AuctionMarketTS
-- ====================================================================================
local AddonName = "WhoDAT"
local AddonAuthor = "Belmont Labs"
----------------------------------------------------------
-- Versioning & schema
----------------------------------------------------------
WhoDAT_Config = WhoDAT_Config or {}
WhoDAT_Config.version = "3.0.0" -- addon version
WhoDAT_Config.schema = {
  -- bump this when you change the shape of WhoDatDB/export.lua
  catalog_version = 3, -- logical data model version
  export_format = "v3", -- human-readable tag
}
----------------------------------------------------------
-- Feature flags (toggle modules without touching core code)
----------------------------------------------------------
WhoDAT_Config.features = {
  items        = true, -- tracker_items.lua
  inventory    = true, -- tracker_inventory.lua
  stats        = true, -- tracker_stats.lua
  quests       = true, -- tracker_quests.lua
  auction      = true, -- tracker_auction.lua
  achievements = true, -- achievements tracking
  ui_main      = true, -- ui_main.lua
  ui_widget    = true, -- ui_widgetmode.lua
  export       = true, -- export.lua
}
----------------------------------------------------------
-- UI preferences (colors, formatting, behavior)
----------------------------------------------------------
WhoDAT_Config.ui = {
  title_text = "\ncffffffffWhoDAT\nr by \ncff3399ffBelmont Labs\nr",
  color = {
    white  = "ffffffff",
    blue   = "3399ff",
    gold   = "ffd100",
    green  = "00ff00",
    red    = "ff0000",
    yellow = "ffff00",
    purple = "cc66ff",
    cyan   = "66ffff",
  },
  widget = {
    enabled      = true,
    alpha        = 0.85,
    scale        = 1.0,
    anchor       = "CENTER",
    x            = 0,
    y            = 0,
    showMoney    = true,
    showXP       = true,
    showDurability = false,
  },
  graphs = {
    -- NOTE: operational knobs for graphs moved to the explicit ui.graphs section below.
    -- These are baseline presentation prefs; legends retained.
    show_legends = true,
  },
}
----------------------------------------------------------
-- Sampling preferences & trackers policy
----------------------------------------------------------
WhoDAT_Config.sampling = {
  item_scan_throttle_ms     = 250, -- avoid tooltip spam/taint
  currency_expand_lists     = true, -- expand headers to read all rows
  honor_collect_yesterday   = true,
  talents_include_links     = true, -- include GetTalentLink strings
  mailbox_include_attachments = true,
  equipment_tooltip_fallback  = true, -- fallback to tooltip for ilvl
  -- Series compaction on export (already used elsewhere); you can add
  -- a similar flag for events in export.lua if you decide to compact.
  series_compact_on_export  = true,
}
-- Auction-specific: time-series & market snapshot behavior
WhoDAT_Config.auction = {
  persist_rows_to_sv   = true, -- WhoDAT_AuctionDB
  persist_market_ts    = true, -- WhoDAT_AuctionMarketTS
  market_take          = 3,    -- top-N low/high buyouts to store
  prefer_getall_scans  = false,-- gated by server cooldown; set true if you plan bulk scans
}
----------------------------------------------------------
-- Identity & profile bootstrap (first-run defaults)
----------------------------------------------------------
WhoDAT_Config.identity = {
  realm       = nil,
  player_name = nil,
  class_local = nil,
  class_file  = nil,
  faction     = nil,
  locale      = nil,
}
WhoDAT_Config.profile = {
  has_relic_slot = false,
  last_login_ts  = nil,
}
-- ====================================================================================
-- Bootstrap helpers (call from core.lua on ADDON_LOADED or PLAYER_ENTERING_WORLD)
-- ====================================================================================
local function safeUnitName(unit)
  local n = UnitName(unit)
  return (type(n) == "string" and n) or "Unknown"
end
local function safeUnitClass(unit)
  local classLocal, classFile = UnitClass(unit)
  return classLocal or "Unknown", classFile or "UNKNOWN"
end
local function safeFaction(unit)
  local f = UnitFactionGroup(unit)
  return f or "Neutral"
end
local function safeLocale()
  local L = GetLocale()
  return L or "enUS"
end
local function hasRelic()
  if type(UnitHasRelicSlot) ~= "function" then 
    return false 
  end
  
  local ok, result = pcall(UnitHasRelicSlot, "player")
  return ok and result or false
end
function WhoDAT_InitConfig()
  -- Initialize SavedVariables bucket
  WhoDatDB = WhoDatDB or {
    sessions  = {}, -- time-bounded play sessions
    series    = {}, -- xp/money/rested/honor/etc. time-series
    events    = {}, -- append-only provenance events (items, mail, auction outcomes)
    snapshots = {}, -- current-state snapshots (equipment, containers, mailbox)
    catalogs  = {}, -- normalized catalogs (items with ilvl, names, qualities, etc.)
    identity  = {}, -- realm, player, class, faction, locale
    ui        = {}, -- persisted ui state
    schema    = { version = WhoDAT_Config.schema.catalog_version, tag = WhoDAT_Config.schema.export_format },
  }
  -- Identity bootstrap
  WhoDAT_Config.identity.realm       = GetRealmName()
  WhoDAT_Config.identity.player_name = safeUnitName("player")
  local classLocal, classFile        = safeUnitClass("player")
  WhoDAT_Config.identity.class_local = classLocal
  WhoDAT_Config.identity.class_file  = classFile
  WhoDAT_Config.identity.faction     = safeFaction("player")
  WhoDAT_Config.identity.locale      = safeLocale()
  -- Profile details
  WhoDAT_Config.profile.has_relic_slot = hasRelic()
  WhoDAT_Config.profile.last_login_ts  = time()
  -- Persist identity into WhoDatDB for exporters/UI
  WhoDatDB.identity = {
    realm         = WhoDAT_Config.identity.realm,
    player_name   = WhoDAT_Config.identity.player_name,
    class_local   = WhoDAT_Config.identity.class_local,
    class_file    = WhoDAT_Config.identity.class_file,
    faction       = WhoDAT_Config.identity.faction,
    locale        = WhoDAT_Config.identity.locale,
    last_login_ts = WhoDAT_Config.profile.last_login_ts,
    has_relic_slot= WhoDAT_Config.profile.has_relic_slot,
    addon         = { name = AddonName, author = AddonAuthor, version = WhoDAT_Config.version },
  }
  -- Ensure top-level audit/event streams exist
  -- (global stream is optional; modules may choose to mirror events here)
  WhoDatDB.events = WhoDatDB.events or {}
  -- Ensure per-character bucket exists for event bus & projections
  -- Your utils.lua WhoDAT_LogEvent() will populate WhoDatDB.characters[key].events.<domain>
  WhoDatDB.characters = WhoDatDB.characters or {}
  -- Initialize auction SV buckets if features enabled
  if WhoDAT_Config.features.auction then
    if WhoDAT_Config.auction.persist_rows_to_sv then
      WhoDAT_AuctionDB = WhoDAT_AuctionDB or {}
    end
    if WhoDAT_Config.auction.persist_market_ts then
      WhoDAT_AuctionMarketTS = WhoDAT_AuctionMarketTS or {}
    end
  end
end
-- ====================================================================================
-- Public accessors (modules should read through these, not internal tables directly)
-- ====================================================================================
function WhoDAT_GetIdentity() return WhoDAT_Config.identity end
function WhoDAT_GetProfile()  return WhoDAT_Config.profile end
function WhoDAT_GetUI()      return WhoDAT_Config.ui end
function WhoDAT_GetFeatures()return WhoDAT_Config.features end
function WhoDAT_GetSampling()return WhoDAT_Config.sampling end
function WhoDAT_GetAuctionCfg() return WhoDAT_Config.auction end
function WhoDAT_GetSchema()  return WhoDAT_Config.schema end
function WhoDAT_GetVersion() return WhoDAT_Config.version end
-- ====================================================================================
-- Optional: feature toggles at runtime (e.g., slash commands or UI buttons)
-- ====================================================================================
function WhoDAT_SetFeature(name, enabled)
  if WhoDAT_Config.features[name] == nil then return false, "UnknownFeature" end
  WhoDAT_Config.features[name] = not not enabled
  return true
end
function WhoDAT_SetWidgetEnabled(enabled)
  WhoDAT_Config.ui.widget.enabled = not not enabled
end
-- Ensure nested tables exist before mutating knobs (idempotent safety)
WhoDAT_Config.ui = WhoDAT_Config.ui or {}
WhoDAT_Config.ui.graphs = WhoDAT_Config.ui.graphs or {}

-- ============================================================================
-- Graphs: patches per request (production-ready defaults)
-- ============================================================================
-- Hard cap on columns and sane defaults
WhoDAT_Config.ui.graphs.max_ui_columns = 256
WhoDAT_Config.ui.graphs.max_points_per_series = 300  -- tune 300–1000 as you prefer
WhoDAT_Config.ui.graphs.enable_smoothing = true
WhoDAT_Config.ui.graphs.gradient_enable = false
WhoDAT_Config.ui.graphs.gradient_top_px = 2
WhoDAT_Config.ui.graphs.gradient_bottom_px = 3

-- Only show data points from the last N sessions (default: 3)
-- Set to nil or <=0 to disable session scoping.
WhoDAT_Config.ui.graphs.session_window = nil  -- Disable session-based filtering

-- Money series behavior
WhoDAT_Config.ui.graphs.money_on_change_only = true  -- compress identical values
WhoDAT_Config.ui.graphs.money_step_style = false     -- set true to disable smoothing

-- Zero-point omission controls
WhoDAT_Config.ui.graphs.omit_zero_points = false
WhoDAT_Config.ui.graphs.omit_zero_points_by_key = {
  xp      = true,
  rested  = true,
  honor   = true,
  money   = false, -- keep money snapshots even if 0 (usually meaningful at start)
  power   = true,
  defense = true,
}

-- Series compaction knob declared above; kept here for backward compatibility
WhoDAT_Config.sampling.series_compact_on_export = true
-- ====================================================================================
-- ============================================================================
-- Memory Management Configuration
-- ============================================================================
WhoDAT_Config.memory = {
  prune_old_series = false, -- set true to enable automatic pruning
  max_series_age_days = 90,  -- prune data older than this
}

-- ============================================================================
-- Export Configuration
-- ============================================================================
WhoDAT_Config.export = {
  use_chunked = true,  -- use chunked export by default (recommended)
  chunk_delay = 0.05,  -- seconds between chunks (50ms)
  enable_compression = false,  -- set true if LibDeflate available
}
-- ============================================================================
-- Session 4 Configuration (Data Collection - No Expiration)
-- ============================================================================

-- Character Events (keep all data indefinitely)
WhoDAT_Config.character_events = {
  enable_item_events = true,  -- Track item events
  enable_zone_events = true,  -- Track zone changes
  money_threshold = 10000,    -- Min money change to log (1 gold = 10000 copper)
  -- NOTE: No retention limits - all data kept indefinitely
}

-- Profiler (optional performance monitoring)
WhoDAT_Config.profiler = {
  enabled = false,          -- Enable profiler (optional, adds 2-5% overhead)
  threshold_ms = 10,        -- Only log functions slower than 10ms
  auto_wrap_exports = true, -- Automatically profile export functions
}

-- Memory Management (garbage collection only, no data deletion)
WhoDAT_Config.memory = {
  prune_old_series = false,   -- DISABLED - never delete series data
  -- NOTE: Memory GC only applies to temporary session data (SESSION_SEEN table)
  -- No actual character data is ever deleted automatically
}
-- End of config.lua
