
-- ui_main.lua
-- WhoDAT - ui_main.lua (Wrath 3.3.5a safe; Docked chrome & ElvUI skin-friendly)
local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS
WhoDAT_AuctionDB = WhoDAT_AuctionDB or {}
WhoDAT_AuctionMarketTS = WhoDAT_AuctionMarketTS or {}
local LSM = _G.LibStub and _G.LibStub("LibSharedMedia-3.0", true) or nil

-- SavedVariables scaffold
NS.ui = NS.ui or {}
NS.ui.tabs = NS.ui.tabs or {}
NS.ui.active = NS.ui.active or 1

-- ============================================================================
-- Standardized labels (lowercase keys for series; titlecase for display)
local LABEL_MAP = {
  money   = "Gold",
  xp      = "Experience",
  rested  = "Rested",
  quests  = "Quests",
  honor   = "Honor",
  pvpKills= "Kills",
  deaths  = "Deaths",
  level   = "Level",
  -- NEW:
  power   = "Power",
  defense = "Defense",
}
-- ============================================================================
-- ===== Utility to get canonical player key & ensure character bucket =====
local U = NS.Utils or {}
local function GetPlayerKey()
  return (U.GetPlayerKey and U.GetPlayerKey())
    or ((GetRealmName() or "Realm") .. ":" .. (UnitName("player") or "Player"))
end
local function EnsureCharacterBucket()
  local key = GetPlayerKey()
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.characters = WhoDatDB.characters or {}
  WhoDatDB.characters[key] = WhoDatDB.characters[key] or {}
  local C = WhoDatDB.characters[key]
  C.series = C.series or {}
  C.series.money  = C.series.money  or {}
  C.series.xp     = C.series.xp     or {}
  C.series.rested = C.series.rested or {}
  C.series.honor  = C.series.honor  or {}
  -- new series buckets are created in tracker_stats.lua; no need to precreate here
  return key, C
end

-- ============================================================================
-- SafeDB() defaults (include Graph visibility defaults with Power/Defense OFF)
local function SafeDB()
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.ui = WhoDatDB.ui or {}
  local ui = WhoDatDB.ui
  ui.point = ui.point or "CENTER"
  ui.rel   = ui.rel   or "CENTER"
  ui.x     = ui.x     or 0
  ui.y     = ui.y     or 0
  ui.size  = ui.size  or { w = 720, h = 440 }
  ui.lastTab   = ui.lastTab   or 1
  ui.floatMode = (ui.floatMode == true) and true or false
  ui.locked    = (ui.locked    == true) and true or false

  -- visibility and startup behavior
  if ui.showOnLogin == nil then ui.showOnLogin = true end
  ui.shown = (ui.shown == true) and true or false

  -- graphs visibility defaults
  ui.graphs = ui.graphs or {}
  ui.graphs.visible = ui.graphs.visible or {
    money   = true,   -- Gold
    xp      = true,   -- XP
    rested  = true,   -- Rested
    honor   = true,   -- Honor
    power   = false,  -- NEW: default OFF
    defense = false,  -- NEW: default OFF
  }
  -- Backward compatibility if user had old SVs without the new keys
  if ui.graphs.visible.power   == nil then ui.graphs.visible.power   = false end
  if ui.graphs.visible.defense == nil then ui.graphs.visible.defense = false end

  return ui
end

-- ElvUI skin helper (explicit support for CloseButton and ResizeGrip)
local function ApplyElvSkin(opts)
  local E = _G.ElvUI and _G.ElvUI[1] or nil
  if not E then return end
  local S
  if E.GetModule then
    local ok, mod = pcall(E.GetModule, E, "Skins")
    if ok then S = mod end
  end
  if not S then return end
  if opts and opts.frame and S.HandleFrame then S:HandleFrame(opts.frame) end
  if opts and opts.buttons and S.HandleButton then
    for _, b in ipairs(opts.buttons) do if b then S:HandleButton(b) end end
  end
  if opts and opts.closeButtons and S.HandleCloseButton then
    for _, cb in ipairs(opts.closeButtons) do if cb then S:HandleCloseButton(cb) end end
  end
  if opts and opts.scrollbars and S.HandleScrollBar then
    for _, sb in ipairs(opts.scrollbars) do if sb then S:HandleScrollBar(sb) end end
  end
  -- ElvUI doesn't have a dedicated resize-grip API; fall back to HandleButton to keep it skinnable
  if opts and opts.resizeGrips and S.HandleButton then
    for _, rg in ipairs(opts.resizeGrips) do if rg then S:HandleButton(rg, true) end end
  end
end

-- Wrath-safe solid color texture using WHITE8x8
local WHOCHAT_PAL = {
  bg     = {0.06, 0.07, 0.10, 0.96}, -- darker near-black, slightly cool
  border = {0.00, 0.00, 0.00, 0.15}, -- WhoCHAT-EXACT border (opaque)
  accent = {0.16, 0.32, 0.80, 0.90}, -- soft blue (buttons/hover)
  nav    = {0.08, 0.09, 0.12, 1.00}, -- darker striping
  input  = {0.12, 0.14, 0.18, 1.00}, -- input bars / footer
}
local function SetSolid(tex, r, g, b, a)
  tex:SetTexture("Interface\\Buttons\\WHITE8x8")
  tex:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
end

-- Create layered background + border (safer than SetBackdrop alpha fiddling)
local function AttachWhoCHATChrome(frame)
  -- BACKGROUND layer
  local bg = frame:CreateTexture(nil, "BACKGROUND")
  bg:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
  bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
  SetSolid(bg, WHOCHAT_PAL.bg[1], WHOCHAT_PAL.bg[2], WHOCHAT_PAL.bg[3], WHOCHAT_PAL.bg[4])
  frame.__wc_bg = bg
  -- BORDER layer uses inset matte lines on all sides
  local border = CreateFrame("Frame", nil, frame)
  border:SetFrameLevel(frame:GetFrameLevel() + 2)
  local sides = {}
  for _, side in ipairs({"Top","Bottom","Left","Right"}) do
    local t = border:CreateTexture(nil, "ARTWORK")
    SetSolid(t, WHOCHAT_PAL.border[1], WHOCHAT_PAL.border[2], WHOCHAT_PAL.border[3], WHOCHAT_PAL.border[4])
    sides[side] = t
  end
  sides.Top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  sides.Top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  sides.Top:SetHeight(7) -- thicker border
  sides.Bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
  sides.Bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
  sides.Bottom:SetHeight(7)
  sides.Left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  sides.Left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
  sides.Left:SetWidth(7)
  sides.Right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  sides.Right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
  sides.Right:SetWidth(7)
  frame.__wc_border = sides
end

-- Apply button tinting consistent with WhoCHAT (hover-friendly)
local function TintButton(btn)
  if not btn or not btn.GetNormalTexture then return end
  local nt = btn:GetNormalTexture();  if nt then SetSolid(nt, WHOCHAT_PAL.nav[1], WHOCHAT_PAL.nav[2], WHOCHAT_PAL.nav[3], 0.65) end
  local pt = btn:GetPushedTexture();  if pt then SetSolid(pt, WHOCHAT_PAL.accent[1], WHOCHAT_PAL.accent[2], WHOCHAT_PAL.accent[3], 0.45) end
  local ht = btn:GetHighlightTexture(); if ht then ht:SetBlendMode("ADD"); SetSolid(ht, WHOCHAT_PAL.accent[1], WHOCHAT_PAL.accent[2], WHOCHAT_PAL.accent[3], 0.20) end
end

-- Backdrop (standard WoW dialog background & border)
local DEFAULT_BACKDROP = {
  bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
  edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile     = true, tileSize = 16, edgeSize = 16,
  insets   = { left = 3, right = 3, top = 3, bottom = 3 }
}

-- Toggleable theme flag (persisted in SafeDB)
local function GetThemeEnabled()
  local ui = SafeDB()
  if ui.themeWhoCHAT == nil then ui.themeWhoCHAT = true end -- default ON
  return ui.themeWhoCHAT
end
local function ApplyWhoCHATTheme_Main(frame)
  if not frame or frame.__wc_bg then return end
  -- Remove default WoW backdrop to prevent double-styling
  frame:SetBackdrop(nil)
  AttachWhoCHATChrome(frame)
  -- Title color pops better on the dark bg
  if frame.Title then frame.Title:SetTextColor(1, 1, 1, 0.95) end
  -- Tab bar strip
  if frame.TabBar and not frame.TabBar.__wc_bg then
    local strip = frame.TabBar:CreateTexture(nil, "BACKGROUND")
    strip:SetAllPoints(frame.TabBar)
    SetSolid(strip, WHOCHAT_PAL.nav[1], WHOCHAT_PAL.nav[2], WHOCHAT_PAL.nav[3], WHOCHAT_PAL.nav[4])
    frame.TabBar.__wc_bg = strip
  end
  -- Content background inset
  if frame.Content and not frame.Content.__wc_bg then
    local cbg = frame.Content:CreateTexture(nil, "BACKGROUND")
    cbg:SetPoint("TOPLEFT", frame.Content, "TOPLEFT", 4, -4)
    cbg:SetPoint("BOTTOMRIGHT", frame.Content, "BOTTOMRIGHT", -4, 4)
    SetSolid(cbg, WHOCHAT_PAL.bg[1], WHOCHAT_PAL.bg[2], WHOCHAT_PAL.bg[3], 0.92)
    frame.Content.__wc_bg = cbg
  end
  -- Buttons: Float, Close
  if frame.FloatBtn then TintButton(frame.FloatBtn) end
  if frame.Close and frame.Close.GetNormalTexture then
    local nt = frame.Close:GetNormalTexture(); if nt then SetSolid(nt, WHOCHAT_PAL.nav[1], WHOCHAT_PAL.nav[2], WHOCHAT_PAL.nav[3], 0.65) end
  end
end
local function RemoveWhoCHATTheme_Main(frame)
  if not frame then return end
  -- Clear our textures if present
  if frame.__wc_bg then frame.__wc_bg:Hide(); frame.__wc_bg = nil end
  if frame.__wc_border then
    for _, t in pairs(frame.__wc_border) do t:Hide() end
    frame.__wc_border = nil
  end
  if frame.TabBar and frame.TabBar.__wc_bg then frame.TabBar.__wc_bg:Hide(); frame.TabBar.__wc_bg = nil end
  if frame.Content and frame.Content.__wc_bg then frame.Content.__wc_bg:Hide(); frame.Content.__wc_bg = nil end
  -- Restore original Dock backdrop if needed
  frame:SetBackdrop(DEFAULT_BACKDROP)
  frame:SetBackdropColor(0,0,0,0.85)
end

-- Helpers
local function SetTitleFont(fs)
  if LSM then
    local font = LSM:Fetch("font", "Friz Quadrata TT") or _G.STANDARD_TEXT_FONT
    fs:SetFont(font, 14, "OUTLINE")
  end
end
local function RestorePositionAndSize(f)
  local ui = SafeDB()
  f:ClearAllPoints()
  f:SetPoint(ui.point, UIParent, ui.rel, ui.x, ui.y)
  f:SetWidth(ui.size.w); f:SetHeight(ui.size.h)
end
local function SavePosition(f)
  local ui = SafeDB()
  local point, _, rel, x, y = f:GetPoint(1)
  ui.point, ui.rel, ui.x, ui.y = point, rel, x, y
end
local function SaveSize(f)
  local ui = SafeDB()
  local w, h = f:GetWidth(), f:GetHeight()
  ui.size.w, ui.size.h = math.floor(w), math.floor(h)
end

-- Graphs margins
local GRAPH_MARGINS = { left = 8, right = 8, top = 36, bottom = 8 }
-- Public helper for graph code to get the actual drawable area.
function NS.Graphs_GetDrawArea(panel)
  return panel and panel.GraphRoot or panel
end

-- ===== Section creation (sparkline + clipped content) =====
do
  local function _SparklineFallback(parent, thickness, height)
    local obj = CreateFrame("Frame", nil, parent)
    function obj:SetPalette(...) end
    function obj:SetSeries(points, opts) obj._points, obj._opts = points, opts end
    function obj:Render() end
    function obj:SetScript(ev, fn) obj["__script_"..ev] = fn end
    obj.Render = obj.Render
    return obj
  end
  NS.CreateSparkline = NS.CreateSparkline or _SparklineFallback
end
function CreateSection(parent, key, color)
  local frame = CreateFrame("Frame", nil, parent)
  frame.key = key
  frame.color = color
  frame.content = CreateFrame("Frame", nil, frame)
  frame.content:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -24)
  frame.content:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -24)
  frame.content:SetHeight(64)
  frame.content:SetClipsChildren(true)
  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -4)
  frame.title:SetText(LABEL_MAP[key] or key)
  frame.poly = frame.poly or NS.CreateSparkline(frame.content, 1, 64)
  frame.poly:SetPalette(color.r, color.g, color.b, color.a)
  function frame:ClearItems() end
  function frame:RenderGraph(points)
    self:ClearItems()
    self.content:Show()
    self.content:SetHeight(64)
    self:SetHeight(64 + 24 + 8)
    local ui = (SafeDB() or nil)
    ui = (ui or (WhoDAT_GetUI and WhoDAT_GetUI()) or (WhoDAT_Config and WhoDAT_Config.ui))
    local gcfg = (ui and ui.graphs) or NS.Graphs_DefaultConfig
    self.poly:SetSeries(points or {}, {
      max_points       = gcfg and gcfg.max_points_per_series or 600,
      max_ui_columns   = gcfg and gcfg.max_ui_columns or 256,
      enable_smoothing = (gcfg and gcfg.enable_smoothing) ~= false,
      gradient_enable  = gcfg and gcfg.gradient_enable or false,
      tooltip_enable   = (gcfg and gcfg.tooltip_enable) ~= false,
      meta = { key = key, label = LABEL_MAP[key] or key },
    })
    if self.poly.Render then self.poly:Render() end
  end
  frame.poly:SetScript("OnSizeChanged", function(self)
    if self.Render then self:Render() end
  end)
  return frame
end

-- ============================================================================
-- Main frame
function NS.UI_Init()
  if NS.mainFrame then return end
  local ui = SafeDB()
  local f = CreateFrame("Frame", "WhoDatMainFrame", UIParent)
  f:SetFrameStrata("MEDIUM")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetResizable(true)
  f:SetMinResize(310, 360)
  f:SetMaxResize(1000, 700)
  -- Start Docked with WoW backdrop; theme layer may replace it
  f:SetBackdrop(DEFAULT_BACKDROP)
  f:SetBackdropColor(0,0,0,0.85)
  f:SetScript("OnDragStart", function(self)
    if SafeDB().locked then return end
    self:StartMoving()
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SavePosition(self)
  end)
  -- Resize grip
  local grip = CreateFrame("Button", nil, f)
  grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  grip:SetWidth(16); grip:SetHeight(16)
  local texUp = grip:CreateTexture(nil, "OVERLAY")
  texUp:SetAllPoints(grip)
  texUp:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip.texUp = texUp
  local texDown = grip:CreateTexture(nil, "OVERLAY")
  texDown:SetAllPoints(grip)
  texDown:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  texDown:Hide()
  grip.texDown = texDown
  local texHi = grip:CreateTexture(nil, "HIGHLIGHT")
  texHi:SetAllPoints(grip)
  texHi:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  texHi:SetBlendMode("ADD")
  grip.texHi = texHi
  grip:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
      texUp:Hide(); texDown:Show()
      f:StartSizing("BOTTOMRIGHT")
    end
  end)
  grip:SetScript("OnMouseUp", function()
    texDown:Hide(); texUp:Show()
    f:StopMovingOrSizing(); SaveSize(f)
    if NS.UI_OnSizeChanged then NS.UI_OnSizeChanged() end
  end)
  NS.ResizeGrip = grip

  -- Title
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
  title:SetText("WhoDAT")
  SetTitleFont(title)
  f.Title = title
  -- Clickable overlay on title
  local titleBtn = CreateFrame("Button", nil, f)
  titleBtn:SetPoint("TOPLEFT", title, "TOPLEFT")
  titleBtn:SetPoint("BOTTOMRIGHT", title, "BOTTOMRIGHT")
  titleBtn:EnableMouse(true)
  titleBtn:SetFrameLevel(f:GetFrameLevel() + 10)
  titleBtn:SetScript("OnClick", function()
    local db = SafeDB()
    if db.floatMode then
      db.floatMode = false
      NS.UI_ApplyFloatMode()
    end
  end)
  titleBtn:SetScript("OnEnter", function(self)
    local db = SafeDB()
    if db.floatMode and GameTooltip then
      GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
      GameTooltip:SetText("Click to Dock", 1, 1, 1)
      GameTooltip:Show()
    end
  end)
  titleBtn:SetScript("OnLeave", function()
    if GameTooltip then GameTooltip:Hide() end
  end)
  f.TitleBtn = titleBtn

  -- Close button
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, -2)
  f.Close = close

  -- Float/Dock toggle button
  local floatBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  floatBtn:SetWidth(80); floatBtn:SetHeight(22)
  floatBtn:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -36)
  floatBtn:SetText(ui.floatMode and "Dock" or "Widget Mode")
  floatBtn:SetScript("OnClick", function()
    local db = SafeDB()
    db.floatMode = not db.floatMode
    floatBtn:SetText(db.floatMode and "Dock" or "Widget Mode")
    NS.UI_ApplyFloatMode()
  end)
  f.FloatBtn = floatBtn

  -- Tab bar
  local tabBar = CreateFrame("Frame", nil, f)
  tabBar:SetPoint("TOPLEFT", f, "TOPLEFT", 100, -34)
  tabBar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -34)
  tabBar:SetHeight(24)
  f.TabBar = tabBar

  -- Content
  local content = CreateFrame("Frame", nil, f)
  content:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -64)
  content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
  f.Content = content

  -- Propagate resize
  f:SetScript("OnSizeChanged", function()
    SaveSize(f)
    if NS.UI_OnSizeChanged then NS.UI_OnSizeChanged() end
  end)

  RestorePositionAndSize(f)
  -- Apply WhoCHAT theme if enabled (Docked look)
  if GetThemeEnabled() then
    ApplyWhoCHATTheme_Main(f)
  else
    -- keep legacy backdrop (already set above)
  end

  NS.mainFrame = f
  -- ElvUI skinning
  ApplyElvSkin({
    frame = f,
    buttons = { floatBtn },
    closeButtons = { close },
    resizeGrips = { grip },
  })

  NS.UI_BuildDefaultPanels()
  NS.UI_ApplyFloatMode()
  if NS.UI_ReflowTabs then NS.UI_ReflowTabs() end
  f:Hide()
end

-- Float/Dock visuals & layout (Float unconditionally removes all backgrounds)
function NS.UI_ApplyFloatMode()
  if not NS.mainFrame then return end
  local ui = SafeDB()
  local f = NS.mainFrame
  if ui.floatMode then
    -- Float/widget overlay: no backdrop, no borders, no tab strip or content bg
    f:SetFrameStrata("HIGH")
    -- Remove legacy backdrop always
    f:SetBackdrop(nil)
    -- Hide theme chrome (bg/border), and content inset bg if present
    if f.__wc_border then for _, t in pairs(f.__wc_border) do t:Hide() end end
    if f.__wc_bg then f.__wc_bg:Hide() end
    if f.Content and f.Content.__wc_bg then f.Content.__wc_bg:Hide() end
    if f.TabBar and f.TabBar.__wc_bg then f.TabBar.__wc_bg:Hide() end
    -- Hide chrome
    if f.Close then f.Close:Hide() end
    if f.FloatBtn then f.FloatBtn:Hide() end
    if f.TabBar then f.TabBar:Hide() end
    -- Show title & clickable WhoDAT overlay
    if f.Title then f.Title:Show() end
    if f.TitleBtn then f.TitleBtn:Show() end
    -- Pull content up under the title (smaller top margin)
    if f.Content then
      f.Content:ClearAllPoints()
      f.Content:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -32) -- was -64
      f.Content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
    end
    -- No resize grip in overlay
    if NS.ResizeGrip then NS.ResizeGrip:Hide() end
  else
    -- Docked: full window look w/ WhoCHAT dark bg + thicker semi-transparent border
    f:SetFrameStrata("MEDIUM")
    if GetThemeEnabled() then
      -- Ensure theme textures are present
      ApplyWhoCHATTheme_Main(f)
      -- Show border again when docked
      if f.__wc_border then for _, t in pairs(f.__wc_border) do t:Show() end end
      if f.__wc_bg then f.__wc_bg:Show() end
      if f.Content and f.Content.__wc_bg then f.Content.__wc_bg:Show() end
      if f.TabBar and f.TabBar.__wc_bg then f.TabBar.__wc_bg:Show() end
    else
      RemoveWhoCHATTheme_Main(f) -- restores DEFAULT_BACKDROP
    end
    -- Show chrome
    if f.Close then f.Close:Show() end
    if f.FloatBtn then
      f.FloatBtn:Show()
      f.FloatBtn:SetText("Widget Mode")
    end
    if f.TabBar then f.TabBar:Show() end
    -- Title visible; click layer harmless in Dock
    if f.Title then f.Title:Show() end
    if f.TitleBtn then f.TitleBtn:Show() end
    -- Restore original content anchors (below tab bar)
    if f.Content then
      f.Content:ClearAllPoints()
      f.Content:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -64)
      f.Content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
    end
    -- Resize grip available in Docked mode
    if NS.ResizeGrip then NS.ResizeGrip:Show() end
  end
  -- Keep active tab selection consistent
  if NS.ui and NS.ui.lastTab then
    NS.UI_SetActiveTab(SafeDB().lastTab or 1)
  end
end

-- Tabs registry
function NS.UI_RegisterPanel(key, label, buildFn, refreshFn)
  assert(type(key) == "string" and label, "panel key/label required")
  local idx = #NS.ui.tabs + 1
  local btn = CreateFrame("Button", nil, NS.mainFrame.TabBar, "UIPanelButtonTemplate")
  btn:SetWidth(90); btn:SetHeight(22)
  if idx == 1 then
    btn:SetPoint("LEFT", NS.mainFrame.TabBar, "LEFT", 0, 0)
  else
    btn:SetPoint("LEFT", NS.ui.tabs[idx-1].button, "RIGHT", 6, 0)
  end
  btn:SetText(label)
  local panel = CreateFrame("Frame", nil, NS.mainFrame.Content)
  panel:SetAllPoints(NS.mainFrame.Content)
  panel:Hide()
  btn:SetScript("OnClick", function() NS.UI_SetActiveTab(idx) end)
  local tab = { key = key, button = btn, panel = panel, buildFn = buildFn, refreshFn = refreshFn }
  table.insert(NS.ui.tabs, tab)
  ApplyElvSkin({ buttons = { btn } })
  TintButton(btn)
  if NS.UI_ReflowTabs then NS.UI_ReflowTabs() end
  return idx
end

function NS.UI_SetActiveTab(idx)
  if idx < 1 or idx > #NS.ui.tabs then return end
  for i, t in ipairs(NS.ui.tabs) do
    if i == idx then
      t.button:LockHighlight()
      t.panel:Show()
      if t._built ~= true and type(t.buildFn) == "function" then
        local ok, err = pcall(t.buildFn, t.panel)
        if not ok then geterrorhandler()(err) end
        t._built = true
      end
      if type(t.refreshFn) == "function" then
        local ok, err = pcall(t.refreshFn, t.panel)
        if not ok then geterrorhandler()(err) end
      end
      if t.panel.UpdateLayout then
        local ok, err = pcall(t.panel.UpdateLayout, t.panel)
        if not ok then geterrorhandler()(err) end
      end
    else
      t.button:UnlockHighlight()
      t.panel:Hide()
    end
  end
  NS.ui.active = idx
  SafeDB().lastTab = idx
end

function NS.UI_Show()
  if not NS.mainFrame then NS.UI_Init() end
  NS.mainFrame:Show()
  NS.UI_SetActiveTab(1)
  local ui = SafeDB()
  ui.lastTab = 1
  ui.shown = true
end
function NS.UI_Hide()
  if NS.mainFrame then NS.mainFrame:Hide() end
  SafeDB().shown = false
end
function NS.UI_Toggle()
  if NS.mainFrame and NS.mainFrame:IsShown() then NS.UI_Hide() else NS.UI_Show() end
end
function NS.UI_RefreshCurrentTab()
  if not NS.mainFrame or not NS.mainFrame:IsShown() then return end
  local t = NS.ui.tabs[NS.ui.active]
  if t and type(t.refreshFn) == "function" then t.refreshFn(t.panel) end
end

-- Reflow tab buttons into rows when width is constrained
function NS.UI_ReflowTabs()
  if not NS.mainFrame or not NS.mainFrame.TabBar then return end
  local bar = NS.mainFrame.TabBar
  local availW = math.max(1, bar:GetWidth() or 1)
  local xPad, yPad, gap, rowGap = 0, 0, 6, 6
  local curX, curY = xPad, 0
  local rowH = 0
  -- Measure and position each button
  for i, t in ipairs(NS.ui.tabs or {}) do
    local btn = t.button
    if btn then
      local bw = math.floor(btn:GetWidth() or 90)
      local bh = math.floor(btn:GetHeight() or 22)
      if rowH < bh then rowH = bh end
      -- If this button would overflow the row, wrap to next line
      if (curX + bw) > availW then
        curX = xPad
        curY = curY + rowH + rowGap
        rowH = bh
      end
      btn:ClearAllPoints()
      btn:SetPoint("TOPLEFT", bar, "TOPLEFT", curX, -curY)
      curX = curX + bw + gap
    end
  end
  -- Update tab bar height to fit rows
  local totalH = curY + rowH + yPad
  bar:SetHeight(totalH > 0 and totalH or 24)
end

-- ===== Layout recompute hook =====
local StatSections = StatSections or {}
local RightScrollChild = RightScrollChild or (RightPanel and RightPanel.ScrollChild)
local function LayoutSections()
  local y = 0
  local order = { "xp", "money", "rested", "quests", "honor", "pvpKills", "deaths", "level", "power", "defense" }
  local ui = SafeDB()
  local vis = (ui.graphs and ui.graphs.visible) or {}
  for _, key in ipairs(order) do
    local sec = StatSections[key]
    if sec then
      local show = (vis[key] ~= false) -- default ON when absent for legacy; new ones default OFF in SafeDB
      sec:ClearAllPoints()
      if show then
        if RightScrollChild then
          sec:SetPoint("TOPLEFT", RightScrollChild, "TOPLEFT", 0, -y)
          sec:SetPoint("TOPRIGHT", RightScrollChild, "TOPRIGHT", 0, -y)
        end
        sec:Show()
        if sec.RenderGraph then sec:RenderGraph(sec.points or {}) end
        local h = math.max(96, sec:GetHeight() or 96)
        y = y + h + 8
      else
        sec:Hide()
      end
    end
  end
  if RightScrollChild and RightScrollChild.SetHeight then
    RightScrollChild:SetHeight(y + 8)
  end
end

function NS.UI_OnSizeChanged()
  local t = NS.ui.tabs[NS.ui.active]
  if t and t.panel and t.panel.UpdateLayout then t.panel:UpdateLayout() end
  if NS.UI_ReflowTabs then NS.UI_ReflowTabs() end
  local ok, err = pcall(LayoutSections)
  if not ok and geterrorhandler then geterrorhandler()(err) end
end

-- Default panels
local function BuildSummary(panel)
  local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
  fs:SetText("Summary: identity, session stats, recent changes.")
  panel.text = fs
end
local function RefreshSummary(panel)
  if NS.Identity_Refresh then NS.Identity_Refresh(panel) end
  if NS.UpdateWhoDatStats then NS.UpdateWhoDatStats(panel) end
end

local function BuildInventory(panel)
  local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
  fs:SetText("Inventory: bags & equipment snapshot.")
end
local function RefreshInventory(panel)
  if NS.Inventory_Refresh then NS.Inventory_Refresh(panel) end
end

local function BuildStats(panel)
  local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
  fs:SetText("Stats: base, ratings, resistances, honor, currency.")
end
local function RefreshStats(panel)
  if NS.Stats_Refresh then NS.Stats_Refresh(panel) end
end

local function BuildQuests(panel)
  local fs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
  fs:SetText("Quests & Reputation.")
end
local function RefreshQuests(panel)
  if NS.Quests_Refresh then NS.Quests_Refresh(panel) end
  if NS.Rep_Refresh then NS.Rep_Refresh(panel) end
end

-- ---- GRAPHS PANEL: responsive layout via GraphRoot ----
local GRAPH_MARGINS2 = { left = 8, right = 8, top = 8, bottom = 8 }
local function BuildGraphs(panel)
  local root = CreateFrame("Frame", nil, panel)
  root:SetPoint("TOPLEFT", panel, "TOPLEFT", GRAPH_MARGINS2.left, -GRAPH_MARGINS2.top)
  root:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -GRAPH_MARGINS2.right, GRAPH_MARGINS2.bottom)
  panel.GraphRoot = root
  if NS.Graphs_Init then
    local ok, err = pcall(NS.Graphs_Init, panel)
    if not ok then geterrorhandler()(err) end
  end
  panel:SetScript("OnUpdate", function(self, elapsed)
    if NS.Graphs_OnUpdate then
      local ok, err = pcall(NS.Graphs_OnUpdate, self, elapsed)
      if not ok then geterrorhandler()(err) end
    end
  end)
  panel:SetScript("OnShow", function(self)
    if self.UpdateLayout then self:UpdateLayout() end
  end)
  panel:SetScript("OnSizeChanged", function(self)
    if self.UpdateLayout then self:UpdateLayout() end
    local ok, err = pcall(LayoutSections)
    if not ok and geterrorhandler then geterrorhandler()(err) end
  end)
  if panel.UpdateLayout then panel:UpdateLayout() end
end
local function RefreshGraphs(panel)
  if NS.Graphs_Refresh then
    local ok, err = pcall(NS.Graphs_Refresh, panel)
    if not ok then geterrorhandler()(err) end
  end
  local ok, err = pcall(LayoutSections)
  if not ok and geterrorhandler then geterrorhandler()(err) end
end

-- Export panel
local function BuildExport(panel)
  local btn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  btn:SetWidth(140); btn:SetHeight(24)
  btn:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
  btn:SetText("Export Now")
  btn:SetScript("OnClick", function()
    if NS.Export_Now then NS.Export_Now() end
  end)
  ApplyElvSkin({ buttons = { btn } })
  TintButton(btn)
end
local function RefreshExport(panel) end

-- Settings panel
-- Settings panel (COMPLETE - Replace entire function starting at line 759)
local function BuildSettings(panel)
  local ui = SafeDB()
  
  -- Lock window checkbox
  local lock = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  lock:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
  local lockLabel = lock:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  lockLabel:SetPoint("LEFT", lock, "RIGHT", 6, 0)
  lockLabel:SetText("Lock window")
  lockLabel:SetWidth(180)      -- ✅ ADDED
  lockLabel:SetWordWrap(false) -- ✅ ADDED
  lock.Label = lockLabel
  lock:SetChecked(ui.locked)
  lock:SetScript("OnClick", function(self)
    SafeDB().locked = self:GetChecked() and true or false
  end)

  -- Reset position button
  local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  reset:SetWidth(120); reset:SetHeight(22)
  reset:SetPoint("TOPLEFT", lock, "BOTTOMLEFT", 0, -12)
  reset:SetText("Reset position")
  reset:SetScript("OnClick", function()
    local db = SafeDB()
    db.point, db.rel, db.x, db.y = "CENTER", "CENTER", 0, 0
    RestorePositionAndSize(NS.mainFrame)
  end)

  -- Reset size button
  local resetSize = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  resetSize:SetWidth(120); resetSize:SetHeight(22)
  resetSize:SetPoint("LEFT", reset, "RIGHT", 8, 0)
  resetSize:SetText("Reset size")
  resetSize:SetScript("OnClick", function()
    local db = SafeDB()
    db.size.w, db.size.h = 720, 440
    RestorePositionAndSize(NS.mainFrame)
    if NS.UI_OnSizeChanged then NS.UI_OnSizeChanged() end
  end)

  -- Float/Dock toggle button
  local float = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  float:SetWidth(120); float:SetHeight(22)
  float:SetPoint("LEFT", resetSize, "RIGHT", 8, 0)
  float:SetText(ui.floatMode and "Dock" or "Widget Mode")
  float:SetScript("OnClick", function()
    local db = SafeDB()
    db.floatMode = not db.floatMode
    float:SetText(db.floatMode and "Dock" or "Widget Mode")
    NS.UI_ApplyFloatMode()
  end)

  -- Show on login checkbox
  local showLogin = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  showLogin:SetPoint("TOPLEFT", reset, "BOTTOMLEFT", 0, -12)
  local showLoginLabel = showLogin:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  showLoginLabel:SetPoint("LEFT", showLogin, "RIGHT", 6, 0)
  showLoginLabel:SetText("Show on login")
  showLoginLabel:SetWidth(180)      -- ✅ ADDED
  showLoginLabel:SetWordWrap(false) -- ✅ ADDED
  showLogin.Label = showLoginLabel
  if ui.showOnLogin == nil then ui.showOnLogin = true end
  showLogin:SetChecked(ui.showOnLogin)
  showLogin:SetScript("OnClick", function(self)
    SafeDB().showOnLogin = self:GetChecked() and true or false
  end)

  -- Theme toggle checkbox
  local theme = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  theme:SetPoint("TOPLEFT", showLogin, "BOTTOMLEFT", 0, -12)
  local themeLabel = theme:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  themeLabel:SetPoint("LEFT", theme, "RIGHT", 6, 0)
  themeLabel:SetText("Use WhoCHAT visual style")
  themeLabel:SetWidth(180)      -- ✅ ADDED
  themeLabel:SetWordWrap(false) -- ✅ ADDED
  theme.Label = themeLabel
  theme:SetChecked(GetThemeEnabled())
  theme:SetScript("OnClick", function(self)
    local ui = SafeDB()
    ui.themeWhoCHAT = self:GetChecked() and true or false
    if NS.mainFrame then
      if ui.themeWhoCHAT then
        ApplyWhoCHATTheme_Main(NS.mainFrame)
      else
        RemoveWhoCHATTheme_Main(NS.mainFrame)
      end
      NS.UI_ApplyFloatMode()
    end
  end)

  -- Visibility status text
  local visFS = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  visFS:SetPoint("TOPLEFT", showLogin, "BOTTOMLEFT", 24, -6)
  visFS:SetWidth(180)      -- ✅ ADDED
  visFS:SetWordWrap(false) -- ✅ ADDED
  local function updateVisText()
    visFS:SetText(string.format("Currently: %s", (NS.mainFrame and NS.mainFrame:IsShown()) and "Shown" or "Hidden"))
  end
  updateVisText()
  panel:SetScript("OnShow", updateVisText)

  -- ElvUI skin and button tinting
  ApplyElvSkin({ buttons = { reset, resetSize, float } })
  TintButton(reset); TintButton(resetSize); TintButton(float)

  -- === Graphs visibility toggles ===
  do
    -- Helper to get the Graphs panel
    local function getGraphsPanel()
      for _, t in ipairs(NS.ui.tabs or {}) do
        if t.key == "graphs" then return t.panel end
      end
      return nil
    end
    
    -- Helper to add a graph toggle checkbox
    local function AddGraphToggle(parent, anchor, key, labelText)
      local ui = SafeDB()
      local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
      cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -10)
      local lbl = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      lbl:SetPoint("LEFT", cb, "RIGHT", 6, 0)
      lbl:SetText(labelText)
      lbl:SetWidth(180)      -- ✅ ADDED
      lbl:SetWordWrap(false) -- ✅ ADDED
      cb.Label = lbl
      cb:SetChecked((ui.graphs and ui.graphs.visible and ui.graphs.visible[key] == true) or false)
      cb:SetScript("OnClick", function(self)
        local panelForGraphs = getGraphsPanel()
        if NS.Graphs_SetVisibility then
          NS.Graphs_SetVisibility(panelForGraphs or (NS.mainFrame and NS.mainFrame.Content) or nil, key, self:GetChecked())
        else
          local db = SafeDB()
          db.graphs = db.graphs or {}
          db.graphs.visible = db.graphs.visible or {}
          db.graphs.visible[key] = self:GetChecked() and true or false
          if NS.UI_RefreshCurrentTab then NS.UI_RefreshCurrentTab() end
        end
        local ok, err = pcall(LayoutSections)
        if not ok and geterrorhandler then geterrorhandler()(err) end
      end)
      return cb
    end

    -- Group label for graph toggles
    local groupFS = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    groupFS:SetPoint("TOPLEFT", theme, "BOTTOMLEFT", 0, -18)
    groupFS:SetText("Graphs visibility")
    groupFS:SetWidth(180) -- ✅ ADDED

    -- Existing toggles
    local cbMoney  = AddGraphToggle(panel, groupFS, "money",  "Show Gold")
    local cbXP     = AddGraphToggle(panel, cbMoney,  "xp",     "Show XP")
    local cbRested = AddGraphToggle(panel, cbXP,     "rested", "Show Rested")
    local cbHonor  = AddGraphToggle(panel, cbRested, "honor",  "Show Honor")
    -- NEW: Power & Defense toggles (default OFF)
    local cbPower   = AddGraphToggle(panel, cbHonor,  "power",   "Show Power")
    local cbDefense = AddGraphToggle(panel, cbPower,  "defense", "Show Defense")
  end
end
local function RefreshSettings(panel)
  if panel and panel:IsShown() then local _ = panel:GetRegions() end
end

function NS.UI_BuildDefaultPanels()
  NS.UI_RegisterPanel("graphs",   "Graphs",   BuildGraphs,   RefreshGraphs)
  NS.UI_RegisterPanel("settings", "Settings", BuildSettings, RefreshSettings)
end

-- Slash commands
SLASH_WHODAT1 = "/whodat"
SLASH_WHODAT2 = "/wd"
SlashCmdList["WHODAT"] = function(msg)
  msg = (msg or ""):lower()
  if msg == "show" then NS.UI_Show()
  elseif msg == "hide" then NS.UI_Hide()
  elseif msg == "toggle" or msg == "" then NS.UI_Toggle()
  elseif msg == "reset" then
    local ui = SafeDB()
    ui.point, ui.rel, ui.x, ui.y = "CENTER", "CENTER", 0, 0
    ui.size = { w = 720, h = 440 }
    RestorePositionAndSize(NS.mainFrame)
    NS.UI_SetActiveTab(1)
    NS.UI_ApplyFloatMode()
  elseif msg == "float" then
    local ui = SafeDB(); ui.floatMode = true;  NS.UI_ApplyFloatMode(); NS.UI_Show()
  elseif msg == "dock" then
    local ui = SafeDB(); ui.floatMode = false; NS.UI_ApplyFloatMode(); NS.UI_Show()
  else
    NS.Log("INFO", "Usage: /whodat [show \\n hide \\n toggle \\n reset \\n float \\n dock]")
  end
end

-- ===== Auto-restore, show at login, and live session bootstrap =====
do
  local _loader = CreateFrame("Frame")
  _loader:RegisterEvent("PLAYER_ENTERING_WORLD")
  _loader:RegisterEvent("PLAYER_MONEY")
  _loader:RegisterEvent("MERCHANT_SHOW")
  _loader:RegisterEvent("MERCHANT_CLOSED")
  local function SampleMoney(tag)
    local key, C = EnsureCharacterBucket()
    table.insert(C.series.money, { ts = time(), value = GetMoney(), tag = tag })
    if NS.UI_RefreshCurrentTab then NS.UI_RefreshCurrentTab() end
  end
  _loader:SetScript("OnEvent", function(self, ev)
    if ev == "PLAYER_ENTERING_WORLD" then
      self:UnregisterEvent("PLAYER_ENTERING_WORLD")
      local ui = SafeDB()
      NS.UI_Init()
      NS.UI_SetActiveTab(ui.lastTab or 1)
      NS.UI_ApplyFloatMode()
      EnsureCharacterBucket()
      SampleMoney("login")
      if ui.showOnLogin or ui.shown then
        NS.UI_Show()
      end
      return
    end
    if ev == "PLAYER_MONEY" then
      SampleMoney("PLAYER_MONEY")
    elseif ev == "MERCHANT_SHOW" or ev == "MERCHANT_CLOSED" then
      SampleMoney(ev)
    end
  end)
end
