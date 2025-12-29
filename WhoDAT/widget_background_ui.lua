-- widget_background_ui.lua
-- WhoDAT - UI controls for widget background toggle
-- Adds a checkbox and/or button to the widget settings panel
-- This is a PATCH/ENHANCEMENT to ui_widgetmode.lua

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Background Toggle UI (Checkbox Style)
-- ============================================================================

--- Create a checkbox control for background toggle
-- @param parent frame - Parent frame to attach to
-- @param label string - Label text
-- @param callback function - Called when toggled
local function CreateBackgroundCheckbox(parent, label, callback)
  local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  check:SetSize(24, 24)
  
  -- Label
  local labelText = check:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  labelText:SetPoint("LEFT", check, "RIGHT", 5, 0)
  labelText:SetText(label or "Show Background")
  check.label = labelText
  
  -- Tooltip
  check:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Widget Background")
    GameTooltip:AddLine("Toggle the widget background texture", 1, 1, 1)
    GameTooltip:AddLine("Disable for a clean HUD overlay", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  
  check:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  
  -- Click handler
  check:SetScript("OnClick", function(self)
    local checked = self:GetChecked()
    if callback then
      callback(checked)
    end
    PlaySound(checked and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
  end)
  
  return check
end

-- ============================================================================
-- Integration with Widget Settings
-- ============================================================================

--- Add background toggle to widget right-click menu
function NS.Widget_AddBackgroundMenuItem()
  -- This would hook into the existing right-click menu in ui_widgetmode.lua
  -- The menu already has this functionality (line 419), but we can enhance it
  
  if not NS.widgetFrame then
    if NS.Log then
      NS.Log("DEBUG", "Widget frame not available, skipping background UI")
    end
    return
  end
  
  -- The background toggle is already in the right-click menu
  -- We just need to ensure it's visible and functional
  
  if NS.Log then
    NS.Log("DEBUG", "Widget background toggle already available in right-click menu")
  end
end

-- ============================================================================
-- Standalone Settings Panel (Optional)
-- ============================================================================

--- Create a standalone settings panel for widget configuration
local function CreateWidgetSettingsPanel()
  local panel = CreateFrame("Frame", ADDON_NAME .. "WidgetSettings", UIParent)
  panel:SetSize(300, 200)
  panel:SetPoint("CENTER")
  panel:SetFrameStrata("DIALOG")
  panel:SetFrameLevel(100)
  panel:Hide()
  
  -- Make draggable
  panel:SetMovable(true)
  panel:EnableMouse(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
  panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  
  -- Background
  panel.bg = panel:CreateTexture(nil, "BACKGROUND")
  panel.bg:SetAllPoints()
  panel.bg:SetTexture(0, 0, 0, 0.9)
  
  -- Border
  panel.border = CreateFrame("Frame", nil, panel)
  panel.border:SetAllPoints()
  panel.border:SetBackdrop({
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
  })
  panel.border:SetBackdropBorderColor(0.4, 0.4, 1, 1)
  
  -- Title
  panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  panel.title:SetPoint("TOP", panel, "TOP", 0, -15)
  panel.title:SetText("Widget Settings")
  
  -- Close button
  panel.close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  panel.close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -5, -5)
  panel.close:SetScript("OnClick", function() panel:Hide() end)
  
  -- Background checkbox
  local yOffset = -50
  panel.bgCheck = CreateBackgroundCheckbox(panel, "Show Background", function(checked)
    if NS.Widget_SetBackgroundEnabled then
      NS.Widget_SetBackgroundEnabled(checked)
    end
  end)
  panel.bgCheck:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, yOffset)
  
  -- Alpha slider
  yOffset = yOffset - 40
  panel.alphaLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  panel.alphaLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, yOffset)
  panel.alphaLabel:SetText("Opacity:")
  
  panel.alphaSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
  panel.alphaSlider:SetPoint("TOPLEFT", panel.alphaLabel, "BOTTOMLEFT", 0, -10)
  panel.alphaSlider:SetWidth(250)
  panel.alphaSlider:SetMinMaxValues(0.1, 1.0)
  panel.alphaSlider:SetValueStep(0.05)
  panel.alphaSlider:SetObeyStepOnDrag(true)
  
  -- Slider labels
  panel.alphaSlider.Low = panel.alphaSlider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  panel.alphaSlider.Low:SetPoint("TOPLEFT", panel.alphaSlider, "BOTTOMLEFT", 0, 0)
  panel.alphaSlider.Low:SetText("10%")
  
  panel.alphaSlider.High = panel.alphaSlider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  panel.alphaSlider.High:SetPoint("TOPRIGHT", panel.alphaSlider, "BOTTOMRIGHT", 0, 0)
  panel.alphaSlider.High:SetText("100%")
  
  panel.alphaSlider.Text = panel.alphaSlider:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  panel.alphaSlider.Text:SetPoint("TOP", panel.alphaSlider, "BOTTOM", 0, 0)
  
  panel.alphaSlider:SetScript("OnValueChanged", function(self, value)
    self.Text:SetText(string.format("%.0f%%", value * 100))
    
    if NS.widgetFrame then
      NS.widgetFrame:SetAlpha(value)
      
      -- Save to DB
      WhoDatDB = WhoDatDB or {}
      WhoDatDB.ui = WhoDatDB.ui or {}
      WhoDatDB.ui.widget = WhoDatDB.ui.widget or {}
      WhoDatDB.ui.widget.alpha = value
    end
  end)
  
  -- Scale slider
  yOffset = yOffset - 70
  panel.scaleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  panel.scaleLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, yOffset)
  panel.scaleLabel:SetText("Scale:")
  
  panel.scaleSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
  panel.scaleSlider:SetPoint("TOPLEFT", panel.scaleLabel, "BOTTOMLEFT", 0, -10)
  panel.scaleSlider:SetWidth(250)
  panel.scaleSlider:SetMinMaxValues(0.5, 2.0)
  panel.scaleSlider:SetValueStep(0.1)
  panel.scaleSlider:SetObeyStepOnDrag(true)
  
  panel.scaleSlider.Low = panel.scaleSlider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  panel.scaleSlider.Low:SetPoint("TOPLEFT", panel.scaleSlider, "BOTTOMLEFT", 0, 0)
  panel.scaleSlider.Low:SetText("50%")
  
  panel.scaleSlider.High = panel.scaleSlider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  panel.scaleSlider.High:SetPoint("TOPRIGHT", panel.scaleSlider, "BOTTOMRIGHT", 0, 0)
  panel.scaleSlider.High:SetText("200%")
  
  panel.scaleSlider.Text = panel.scaleSlider:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  panel.scaleSlider.Text:SetPoint("TOP", panel.scaleSlider, "BOTTOM", 0, 0)
  
  panel.scaleSlider:SetScript("OnValueChanged", function(self, value)
    self.Text:SetText(string.format("%.0f%%", value * 100))
    
    if NS.widgetFrame then
      NS.widgetFrame:SetScale(value)
      
      -- Save to DB
      WhoDatDB = WhoDatDB or {}
      WhoDatDB.ui = WhoDatDB.ui or {}
      WhoDatDB.ui.widget = WhoDatDB.ui.widget or {}
      WhoDatDB.ui.widget.scale = value
    end
  end)
  
  -- Initialize values from DB
  panel:SetScript("OnShow", function(self)
    WhoDatDB = WhoDatDB or {}
    WhoDatDB.ui = WhoDatDB.ui or {}
    WhoDatDB.ui.widget = WhoDatDB.ui.widget or {}
    local db = WhoDatDB.ui.widget
    
    -- Background checkbox
    self.bgCheck:SetChecked(not (db.noBackground == true))
    
    -- Alpha slider
    self.alphaSlider:SetValue(db.alpha or 0.85)
    
    -- Scale slider
    self.scaleSlider:SetValue(db.scale or 1.0)
  end)
  
  return panel
end

-- ============================================================================
-- Public API
-- ============================================================================

local settingsPanel

--- Show widget settings panel
function NS.Widget_ShowSettings()
  if not settingsPanel then
    settingsPanel = CreateWidgetSettingsPanel()
  end
  
  settingsPanel:Show()
end

--- Hide widget settings panel
function NS.Widget_HideSettings()
  if settingsPanel then
    settingsPanel:Hide()
  end
end

--- Toggle widget settings panel
function NS.Widget_ToggleSettings()
  if not settingsPanel then
    settingsPanel = CreateWidgetSettingsPanel()
  end
  
  if settingsPanel:IsShown() then
    settingsPanel:Hide()
  else
    settingsPanel:Show()
  end
end

-- ============================================================================
-- Slash Commands
-- ============================================================================

SLASH_WDWIDGET1 = "/wdwidget"
SLASH_WDWIDGET2 = "/wdw"
SlashCmdList["WDWIDGET"] = function(msg)
  msg = (msg or ""):lower():trim()
  
  if msg == "settings" or msg == "config" then
    NS.Widget_ShowSettings()
    
  elseif msg == "bg" or msg == "background" then
    -- Toggle background
    WhoDatDB = WhoDatDB or {}
    WhoDatDB.ui = WhoDatDB.ui or {}
    WhoDatDB.ui.widget = WhoDatDB.ui.widget or {}
    local db = WhoDatDB.ui.widget
    
    local new_state = not (db.noBackground == true)
    
    if NS.Widget_SetBackgroundEnabled then
      NS.Widget_SetBackgroundEnabled(new_state)
      print(string.format("[WhoDAT] Widget background %s", new_state and "enabled" or "disabled"))
    end
    
  elseif msg == "show" then
    if NS.Widget_Show then
      NS.Widget_Show()
    end
    
  elseif msg == "hide" then
    if NS.Widget_Hide then
      NS.Widget_Hide()
    end
    
  elseif msg == "toggle" then
    if NS.Widget_Toggle then
      NS.Widget_Toggle()
    end
    
  else
    print("=== WhoDAT Widget Commands ===")
    print("/wdw settings  - Open widget settings panel")
    print("/wdw bg        - Toggle background")
    print("/wdw show      - Show widget")
    print("/wdw hide      - Hide widget")
    print("/wdw toggle    - Toggle widget")
  end
end

-- ============================================================================
-- Initialization
-- ============================================================================

-- Add menu item on widget load
if NS.widgetFrame then
  NS.Widget_AddBackgroundMenuItem()
end

return NS