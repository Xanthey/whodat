
-- WhoDAT - ui_widgetmode.lua
-- Lightweight widget overlay (formerly float mode) - Wrath 3.3.5a safe
local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ---------- Local helpers & constants ---------------------------------------
local UI = NS.CONFIG and NS.CONFIG.UI or nil
local DEFAULTS = {
  widget = {
    shown = false,
    lock = false,
    alpha = 0.85,
    scale = 1.0,
    strata = "MEDIUM",
    clickThrough= false,
    point = "TOPRIGHT",
    relFrame = "UIParent",
    relPoint = "TOPRIGHT",
    x = -20,
    y = -20,
    snap = true,
    snapPadding = 6,
    width = 240,
    height = 120,
    -- Default to no background for clean HUD
    noBackground = true,
  }
}
local function tbl_deepcopy(src)
  if type(src) ~= "table" then return src end
  local t = {}
  for k,v in pairs(src) do t[k] = tbl_deepcopy(v) end
  return t
end
local function ensure_db()
  WhoDatDB = WhoDatDB or {}
  WhoDatDB.ui = WhoDatDB.ui or {}
  WhoDatDB.ui.widget = WhoDatDB.ui.widget or tbl_deepcopy(DEFAULTS.widget)
  return WhoDatDB.ui.widget
end

-- Theme awareness (compat w/ ui_main.lua)
local function _GetThemeEnabled()
  local ok, ui
  ok, ui = pcall(function()
    WhoDatDB = WhoDatDB or {}
    WhoDatDB.ui = WhoDatDB.ui or {}
    return WhoDatDB.ui
  end)
  if ok and ui then
    if ui.themeWhoCHAT == nil then ui.themeWhoCHAT = true end
    return ui.themeWhoCHAT
  end
  return true
end

local function in_combat() return InCombatLockdown and InCombatLockdown() end
local function clamp(v, minv, maxv) if v < minv then return minv elseif v > maxv then return maxv else return v end end
local function clamp_to_screen(f)
  local scale = f:GetEffectiveScale()
  local sw = UIParent:GetWidth() * UIParent:GetEffectiveScale()
  local sh = UIParent:GetHeight() * UIParent:GetEffectiveScale()
  local w = f:GetWidth() * scale
  local h = f:GetHeight() * scale
  local l, b = f:GetLeft(), f:GetBottom()
  local r, t = f:GetRight(), f:GetTop()
  if not (l and b and r and t) then return end
  local dx, dy = 0, 0
  if l < 0 then dx = dx + (-l) end
  if r > sw then dx = dx + (sw - r) end
  if b < 0 then dy = dy + (-b) end
  if t > sh then dy = dy + (sh - t) end
  if dx ~= 0 or dy ~= 0 then
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "TOPLEFT",
      clamp(l + dx, 0, sw - w),
      clamp(t + dy, h, sh))
  end
end
local function snap_to_edges(f, snapPadding)
  local sw = UIParent:GetWidth() * UIParent:GetEffectiveScale()
  local sh = UIParent:GetHeight() * UIParent:GetEffectiveScale()
  local l, b = f:GetLeft(), f:GetBottom()
  local r, t = f:GetRight(), f:GetTop()
  if not (l and b and r and t) then return end
  local pad = (snapPadding or 6)
  local snappedX, snappedY = nil, nil
  if math.abs(l - 0) <= pad then snappedX = 0
  elseif math.abs(r - sw) <= pad then snappedX = sw end
  if math.abs(t - sh) <= pad then snappedY = sh
  elseif math.abs(b - 0) <= pad then snappedY = 0 end
  if snappedX or snappedY then
    local x = (snappedX and (snappedX == 0 and 0 or sw)) or l
    local y = (snappedY and (snappedY == 0 and 0 or sh)) or b
    local dist = {
      TOPLEFT = math.abs(x-0) + math.abs(y-sh),
      TOPRIGHT = math.abs(x-sw) + math.abs(y-sh),
      BOTTOMLEFT = math.abs(x-0) + math.abs(y-0),
      BOTTOMRIGHT = math.abs(x-sw) + math.abs(y-0),
    }
    local best, bestd = "TOPRIGHT", 1e9
    for p,d in pairs(dist) do if d < bestd then best, bestd = p, d end end
    f:ClearAllPoints()
    f:SetPoint(best, UIParent, best, (best:find("LEFT") and 0 or -0), (best:find("TOP") and -0 or 0))
  end
end

-- ---------- Frame build ------------------------------------------------------
NS.widgetFrame = NS.widgetFrame
function NS.Widget_Init()
  if in_combat() then
    if not NS._widgetInitDeferred then
      NS._widgetInitDeferred = true
      local fDefer = CreateFrame("Frame")
      fDefer:RegisterEvent("PLAYER_REGEN_ENABLED")
      fDefer:SetScript("OnEvent", function(self, ev)
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        NS._widgetInitDeferred = nil
        NS.Widget_Init()
      end)
    end
    return
  end
  local db = ensure_db()
  if NS.widgetFrame and NS.widgetFrame.__built then
    NS.Widget_ApplySettings()
    return
  end
  local f = CreateFrame("Frame", "WhoDatWidgetFrame", UIParent)
  f:SetSize(db.width, db.height)
  f:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
  f:SetMovable(true)
  f:SetResizable(true)
  f:SetMinResize(160, 80)
  f:EnableMouse(not db.clickThrough)
  f:SetFrameStrata(db.strata)
  f:SetScale(db.scale)
  f:Hide()

  -- Background texture (Wrath-safe); immediately hidden by default for clean HUD
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(true)
  bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  bg:SetVertexColor(0, 0, 0, db.alpha or 0.85)
  f.bg = bg
  -- Remove background if requested or whenever Float is active
  if db.noBackground == true then f.bg:Hide() else f.bg:Show() end
  if WhoDatDB and WhoDatDB.ui and WhoDatDB.ui.floatMode then f.bg:Hide() end

  -- Title text
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", 8, -8)
  title:SetText("WhoDAT Widget")
  f.Title = title

  -- Content slots
  local line1 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  line1:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  line1:SetText("Gold: -- XP: --")
  f.Line1 = line1
  local line2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  line2:SetPoint("TOPLEFT", line1, "BOTTOMLEFT", 0, -4)
  line2:SetText("Rested: -- Rep(avg): -- Avg iLVL: --")
  f.Line2 = line2

  -- Resize grip
  local grip = CreateFrame("Frame", nil, f)
  grip:SetSize(14, 14)
  grip:SetPoint("BOTTOMRIGHT", -2, 2)
  grip:EnableMouse(true)
  local gtx = grip:CreateTexture(nil, "OVERLAY")
  gtx:SetAllPoints(true)
  gtx:SetTexture("Interface\\AddOns\\WhoDAT\\media\\resize") -- optional
  gtx:SetVertexColor(1,1,1,0.7)
  grip.tx = gtx

  -- Dragging (Alt + LeftButton unless unlocked)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self)
    local d = ensure_db()
    if d.lock and not IsAltKeyDown() then return end
    if in_combat() then return end
    self:StartMoving()
    self.__dragging = true
  end)
  f:SetScript("OnDragStop", function(self)
    if not self.__dragging then return end
    self:StopMovingOrSizing()
    self.__dragging = nil
    clamp_to_screen(self)
    local d = ensure_db()
    local p, rf, rp, x, y = self:GetPoint(1)
    d.point, d.relFrame, d.relPoint, d.x, d.y = p or "TOPRIGHT", "UIParent", rp or "TOPRIGHT", x or -20, y or -20
    if d.snap then snap_to_edges(self, d.snapPadding) end
  end)

  -- Alt + RightButton resize / context menu
  f:SetScript("OnMouseDown", function(self, btn)
    if btn ~= "RightButton" then return end
    local d = ensure_db()
    if d.lock and not IsAltKeyDown() then return end
    if in_combat() then return end
    self:StartSizing("BOTTOMRIGHT")
    self.__resizing = true
  end)
  f:SetScript("OnMouseUp", function(self, btn)
    if self.__resizing then
      self:StopMovingOrSizing()
      self.__resizing = nil
      local d = ensure_db()
      d.width, d.height = self:GetSize()
    end
    if btn == "RightButton" and not self.__resizing then
      NS.Widget_ShowMenu(self)
    end
  end)

  -- Grip resize
  grip:SetScript("OnMouseDown", function(self, btn)
    if btn ~= "LeftButton" then return end
    if in_combat() then return end
    local d = ensure_db()
    if d.lock and not IsAltKeyDown() then return end
    local parent = self:GetParent()
    parent:StartSizing("BOTTOMRIGHT")
    parent.__resizing = true
  end)
  grip:SetScript("OnMouseUp", function(self, btn)
    local parent = self:GetParent()
    if parent.__resizing then
      parent:StopMovingOrSizing()
      parent.__resizing = nil
      local d = ensure_db()
      d.width, d.height = parent:GetSize()
    end
  end)

  -- Combat guard
  f:RegisterEvent("PLAYER_REGEN_DISABLED")
  f:RegisterEvent("PLAYER_REGEN_ENABLED")
  f:SetScript("OnEvent", function(self, ev)
    if ev == "PLAYER_REGEN_DISABLED" then
      self:EnableMouse(false)
    elseif ev == "PLAYER_REGEN_ENABLED" then
      local d = ensure_db()
      self:EnableMouse(not d.clickThrough)
    end
  end)

  -- Periodic update
  local t_accum = 0
  f:SetScript("OnUpdate", function(self, elapsed)
    t_accum = t_accum + elapsed
    if t_accum < 0.25 then return end
    t_accum = 0
    local goldStr = "--"
    do
      local gs = NS.GetMoney and NS.GetMoney()
      if type(gs) == "table" then
        goldStr = gs[1]
      elseif type(gs) == "string" then
        goldStr = gs
      end
    end
    local lvl = (NS.GetLevel and NS.GetLevel()) or (UnitLevel and UnitLevel("player")) or nil
    local xpStr = ""
    if not (lvl and lvl >= 80) then
      local xp, xpMax, rested = NS.GetXP and NS.GetXP()
      if xp and xpMax and xpMax > 0 then
        local pct = (xp / xpMax) * 100
        local restedStr = (rested and rested > 0) and string.format(" (+%s)", rested) or ""
        xpStr = string.format(" XP: %s/%s (%.1f%%%s)", xp, xpMax, pct, restedStr)
      else
        xpStr = " XP: --"
      end
    end
    local _, _, rested = NS.GetXP and NS.GetXP()
    local restedStr = " --"
    if rested and rested > 0 then
      restedStr = string.format(" %s", rested)
    end
    local repAvg = NS.GetReputationAverage and NS.GetReputationAverage() or nil
    local repStr = repAvg and string.format("%.1f%%", repAvg * 100) or "--"
    local avgIlvl = NS.GetAverageItemLevel and NS.GetAverageItemLevel() or nil
    local ilvlStr = avgIlvl and string.format("%.1f", avgIlvl) or "--"
    self.Line1:SetText(string.format("Gold: %s%s", goldStr, xpStr))
    self.Line2:SetText(string.format("Rested:%s Rep(avg): %s Avg iLVL: %s", restedStr, repStr, ilvlStr))
  end)
  f.__built = true
  NS.widgetFrame = f
  NS.Widget_ApplySettings()
  if db.shown then f:Show() else f:Hide() end
end

-- ---------- Settings application --------------------------------------------
function NS.Widget_ApplySettings()
  local db = ensure_db()
  if not NS.widgetFrame then return end
  local f = NS.widgetFrame
  if not f.bg then
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(true)
    bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    bg:SetVertexColor(0, 0, 0, db.alpha or 0.85)
    f.bg = bg
  end
  f:SetScale(db.scale or 1.0)
  f:SetFrameStrata(db.strata or "MEDIUM")
  f:EnableMouse(not db.clickThrough)
  f.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
  f.bg:SetVertexColor(0, 0, 0, db.alpha or 0.85)
  -- Respect background removal & Float
  if db.noBackground == true then f.bg:Hide() else f.bg:Show() end
  if WhoDatDB and WhoDatDB.ui and WhoDatDB.ui.floatMode then f.bg:Hide() end
  f:ClearAllPoints()
  f:SetPoint(db.point or "TOPRIGHT", UIParent, db.relPoint or "TOPRIGHT", db.x or -20, db.y or -20)
  f:SetSize(db.width or 240, db.height or 120)
  clamp_to_screen(f)
end

-- ---------- Public API -------------------------------------------------------
function NS.Widget_Toggle()
  local db = ensure_db()
  if not NS.widgetFrame or not NS.widgetFrame.__built then NS.Widget_Init() end
  db.shown = not db.shown
  if db.shown then NS.widgetFrame:Show() else NS.widgetFrame:Hide() end
end
function NS.Widget_Show()
  local db = ensure_db()
  if not NS.widgetFrame or not NS.widgetFrame.__built then NS.Widget_Init() end
  db.shown = true
  NS.widgetFrame:Show()
end
function NS.Widget_Hide()
  local db = ensure_db()
  db.shown = false
  if NS.widgetFrame then NS.widgetFrame:Hide() end
end
function NS.Widget_SetAlpha(a)
  local db = ensure_db()
  db.alpha = clamp(tonumber(a) or db.alpha or 0.85, 0.1, 1.0)
  if NS.widgetFrame and NS.widgetFrame.bg then
    NS.widgetFrame.bg:SetTexture("Interface\\Buttons\\WHITE8x8")
    NS.widgetFrame.bg:SetVertexColor(0, 0, 0, db.alpha)
    if db.noBackground == true then NS.widgetFrame.bg:Hide() else NS.widgetFrame.bg:Show() end
    if WhoDatDB and WhoDatDB.ui and WhoDatDB.ui.floatMode then NS.widgetFrame.bg:Hide() end
  end
end
function NS.Widget_SetScale(s)
  local db = ensure_db()
  db.scale = clamp(tonumber(s) or db.scale or 1.0, 0.5, 2.0)
  if NS.widgetFrame then NS.widgetFrame:SetScale(db.scale) end
end
function NS.Widget_SetStrata(strata)
  local db = ensure_db()
  db.strata = (strata == "LOW" or strata == "MEDIUM" or strata == "HIGH" or strata == "BACKGROUND" or strata == "DIALOG" or strata == "TOOLTIP") and strata or "MEDIUM"
  if NS.widgetFrame then NS.widgetFrame:SetFrameStrata(db.strata) end
end
function NS.Widget_SetLock(flag)
  local db = ensure_db()
  db.lock = not not flag
end
function NS.Widget_SetClickThrough(flag)
  local db = ensure_db()
  db.clickThrough = not not flag
  if NS.widgetFrame then NS.widgetFrame:EnableMouse(not db.clickThrough) end
end
-- Programmatic background toggle (true = show background; false = remove)
function NS.Widget_SetBackgroundEnabled(flag)
  local db = ensure_db()
  db.noBackground = not (flag == true)
  if NS.widgetFrame and NS.widgetFrame.bg then
    if db.noBackground == true then NS.widgetFrame.bg:Hide() else NS.widgetFrame.bg:Show() end
  end
end
function NS.Widget_SetSnap(flag, padding)
  local db = ensure_db()
  db.snap = not not flag
  if padding ~= nil then db.snapPadding = tonumber(padding) or db.snapPadding or 6 end
end

-- ---------- Context menu -----------------------------------------------------
function NS.Widget_ShowMenu(parent)
  local db = ensure_db()
  local menu = CreateFrame("Frame", nil, UIParent)
  menu:SetFrameStrata("TOOLTIP")
  menu:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
  })
  menu:SetSize(180, 180)
  local x, y = GetCursorPosition()
  local effScale = UIParent:GetEffectiveScale()
  menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x/effScale, (y/effScale))
  local function addButton(text, onClick, ypos)
    local b = CreateFrame("Button", nil, menu, "UIPanelButtonTemplate")
    b:SetSize(160, 20)
    b:SetPoint("TOPLEFT", 10, -10 - (ypos*24))
    b:SetText(text)
    b:SetScript("OnClick", function()
      onClick()
      menu:Hide()
    end)
    return b
  end
  local row = 0
  addButton((db.shown and "Hide" or "Show"), function() NS.Widget_Toggle() end, row) row = row + 1
  addButton((db.lock and "Unlock (Alt-drag)" or "Lock"), function() NS.Widget_SetLock(not db.lock) end, row) row = row + 1
  addButton((db.clickThrough and "Disable Click-Through" or "Enable Click-Through"), function() NS.Widget_SetClickThrough(not db.clickThrough) end, row) row = row + 1
  addButton((db.snap and "Disable Edge Snap" or "Enable Edge Snap"), function() NS.Widget_SetSnap(not db.snap) end, row) row = row + 1
  addButton("Alpha -", function() NS.Widget_SetAlpha((db.alpha or 0.85) - 0.05) end, row) row = row + 1
  addButton("Alpha +", function() NS.Widget_SetAlpha((db.alpha or 0.85) + 0.05) end, row) row = row + 1
  addButton("Scale -", function() NS.Widget_SetScale((db.scale or 1.0) - 0.05) end, row) row = row + 1
  addButton("Scale +", function() NS.Widget_SetScale((db.scale or 1.0) + 0.05) end, row) row = row + 1
  addButton((db.noBackground and "Enable Background" or "Disable Background"), function() NS.Widget_SetBackgroundEnabled(db.noBackground) end, row) row = row + 1
  addButton("Strata: "..(db.strata or "MEDIUM"), function()
    local nextOrder = { BACKGROUND="LOW", LOW="MEDIUM", MEDIUM="HIGH", HIGH="DIALOG", DIALOG="TOOLTIP", TOOLTIP="BACKGROUND" }
    NS.Widget_SetStrata(nextOrder[db.strata or "MEDIUM"] or "MEDIUM")
  end, row) row = row + 1
  menu:EnableMouse(true)
  menu:SetScript("OnHide", function(self) self:SetParent(nil) end)
  menu:Show()
end

-- ---------- Keybinding bridge (optional) -------------------------------------
function NS_Widget_Toggle() NS.Widget_Toggle() end

-- ---------- Bootstrap on load ------------------------------------------------
local _initLoader
local function _loader_OnEvent(self, ev)
  if ev == "PLAYER_ENTERING_WORLD" then
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    NS.Widget_Init()
    _initLoader = nil
  end
end
if not NS.widgetFrame then
  _initLoader = CreateFrame("Frame")
  _initLoader:RegisterEvent("PLAYER_ENTERING_WORLD")
  _initLoader:SetScript("OnEvent", _loader_OnEvent)
end