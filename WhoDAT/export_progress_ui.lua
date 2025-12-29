-- export_progress_ui.lua
-- WhoDAT - Visual progress indicator for chunked export
-- Shows a progress bar and status text during export
-- WRATH 3.3.5a COMPATIBLE VERSION (animations removed)

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Progress Frame
-- ============================================================================

local ProgressFrame

local function CreateProgressFrame()
  if ProgressFrame then return ProgressFrame end
  
  local f = CreateFrame("Frame", ADDON_NAME .. "ExportProgress", UIParent)
  f:SetSize(300, 80)
  f:SetPoint("TOP", UIParent, "TOP", 0, -100)
  f:SetFrameStrata("DIALOG")
  f:SetFrameLevel(100)
  f:Hide()
  
  -- Background (WRATH FIX: SetTexture instead of SetColorTexture)
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints()
  f.bg:SetTexture(0, 0, 0, 0.8)
  
  -- Border
  f.border = CreateFrame("Frame", nil, f)
  f.border:SetAllPoints()
  f.border:SetBackdrop({
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
  })
  f.border:SetBackdropBorderColor(0.3, 0.6, 1, 1)
  
  -- Title
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("TOP", f, "TOP", 0, -10)
  f.title:SetText("Exporting Data...")
  f.title:SetTextColor(1, 1, 1)
  
  -- Status text
  f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.status:SetPoint("TOP", f.title, "BOTTOM", 0, -5)
  f.status:SetText("Initializing...")
  f.status:SetTextColor(0.8, 0.8, 0.8)
  
  -- Progress bar background
  f.barBg = CreateFrame("Frame", nil, f)
  f.barBg:SetSize(260, 20)
  f.barBg:SetPoint("TOP", f.status, "BOTTOM", 0, -8)
  
  local barBgTex = f.barBg:CreateTexture(nil, "BACKGROUND")
  barBgTex:SetAllPoints()
  barBgTex:SetTexture(0.2, 0.2, 0.2, 0.8)  -- WRATH FIX
  
  -- Progress bar
  f.bar = CreateFrame("StatusBar", nil, f.barBg)
  f.bar:SetAllPoints()
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.bar:SetStatusBarColor(0.2, 0.8, 0.2)
  f.bar:SetMinMaxValues(0, 100)
  f.bar:SetValue(0)
  
  -- Progress text
  f.percent = f.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.percent:SetPoint("CENTER", f.bar, "CENTER")
  f.percent:SetText("0%")
  
  -- Cancel button
  f.cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.cancel:SetSize(80, 22)
  f.cancel:SetPoint("TOP", f.barBg, "BOTTOM", 0, -8)
  f.cancel:SetText("Cancel")
  f.cancel:SetScript("OnClick", function()
    if NS.Export_CancelChunked then
      NS.Export_CancelChunked()
    end
    f:Hide()
  end)
  
  -- WRATH COMPATIBLE: Simple alpha pulse using OnUpdate instead of Animation API
  f.pulseAlpha = 1
  f.pulseDirection = -1
  f:SetScript("OnUpdate", function(self, elapsed)
    if not self:IsShown() then return end
    
    -- Pulse the title alpha
    self.pulseAlpha = self.pulseAlpha + (self.pulseDirection * elapsed * 0.8)
    
    if self.pulseAlpha <= 0.5 then
      self.pulseAlpha = 0.5
      self.pulseDirection = 1
    elseif self.pulseAlpha >= 1 then
      self.pulseAlpha = 1
      self.pulseDirection = -1
    end
    
    self.title:SetAlpha(self.pulseAlpha)
  end)
  
  ProgressFrame = f
  return f
end

-- ============================================================================
-- Progress API
-- ============================================================================

--- Show progress frame
function NS.ExportProgress_Show()
  local f = CreateProgressFrame()
  f:Show()
  f.bar:SetValue(0)
  f.percent:SetText("0%")
  f.status:SetText("Initializing...")
  f.title:SetAlpha(1)
  f.pulseAlpha = 1
  f.pulseDirection = -1
end

--- Hide progress frame
function NS.ExportProgress_Hide()
  local f = CreateProgressFrame()
  f:Hide()
end

--- Update progress
-- @param current number - current chunk index
-- @param total number - total chunk count
-- @param chunk_id string - current chunk identifier
function NS.ExportProgress_Update(current, total, chunk_id)
  local f = CreateProgressFrame()
  
  if not f:IsShown() then
    f:Show()
  end
  
  local percent = total > 0 and (current / total * 100) or 0
  
  f.bar:SetValue(percent)
  f.percent:SetText(string.format("%.0f%%", percent))
  
  -- Format chunk name nicely
  local chunk_name = chunk_id or "unknown"
  chunk_name = chunk_name:gsub("_", " "):gsub("(%a)(%w*)", function(a, b)
    return a:upper() .. b
  end)
  
  f.status:SetText(string.format("Processing: %s (%d/%d)", chunk_name, current, total))
  
  -- Change color based on progress
  if percent < 33 then
    f.bar:SetStatusBarColor(0.8, 0.2, 0.2) -- red
  elseif percent < 66 then
    f.bar:SetStatusBarColor(0.8, 0.8, 0.2) -- yellow
  else
    f.bar:SetStatusBarColor(0.2, 0.8, 0.2) -- green
  end
  
  -- Completed?
  if current >= total then
    f.title:SetText("Export Complete!")
    f.status:SetText(string.format("Processed %d chunks", total))
    f.percent:SetText("100%")
    f.bar:SetStatusBarColor(0.2, 0.8, 0.2)
    f.title:SetAlpha(1)
    
    -- Auto-hide after 2 seconds (WRATH COMPATIBLE: frame-based timer)
    local hideFrame = CreateFrame("Frame")
    local hideElapsed = 0
    hideFrame:SetScript("OnUpdate", function(self, delta)
      hideElapsed = hideElapsed + delta
      if hideElapsed >= 2 then
        hideFrame:SetScript("OnUpdate", nil)
        f:Hide()
      end
    end)
  end
end

-- ============================================================================
-- Integration with Chunked Export
-- ============================================================================

-- Hook into chunked export to show progress automatically
if NS.Export_StartChunked then
  local original_StartChunked = NS.Export_StartChunked
  
  NS.Export_StartChunked = function(progressCallback)
    -- Show progress UI
    NS.ExportProgress_Show()
    
    -- Wrap callback to update UI
    local wrapped_callback = function(current, total, chunk_id)
      NS.ExportProgress_Update(current, total, chunk_id)
      
      -- Call original callback if provided
      if progressCallback then
        pcall(progressCallback, current, total, chunk_id)
      end
    end
    
    -- Call original with wrapped callback
    return original_StartChunked(wrapped_callback)
  end
end

-- ============================================================================
-- Manual Control Commands
-- ============================================================================

SLASH_WDEXPORTPROGRESS1 = "/wdprogress"
SlashCmdList["WDEXPORTPROGRESS"] = function(msg)
  msg = (msg or ""):lower():trim()
  
  if msg == "show" then
    NS.ExportProgress_Show()
    print("[WhoDAT] Progress frame shown")
    
  elseif msg == "hide" then
    NS.ExportProgress_Hide()
    print("[WhoDAT] Progress frame hidden")
    
  elseif msg == "test" then
    -- Test animation
    NS.ExportProgress_Show()
    
    local current = 0
    local total = 10
    
    local function advance()
      current = current + 1
      NS.ExportProgress_Update(current, total, "test_chunk_" .. current)
      
      if current < total then
        -- WRATH COMPATIBLE: Always use frame timer
        local testFrame = CreateFrame("Frame")
        local testElapsed = 0
        testFrame:SetScript("OnUpdate", function(self, delta)
          testElapsed = testElapsed + delta
          if testElapsed >= 0.3 then
            testFrame:SetScript("OnUpdate", nil)
            advance()
          end
        end)
      end
    end
    
    advance()
    
  else
    print("=== WhoDAT Export Progress Commands ===")
    print("/wdprogress show - Show progress frame")
    print("/wdprogress hide - Hide progress frame")
    print("/wdprogress test - Test progress animation")
  end
end

-- ============================================================================
-- Make frame movable (hold Shift to drag)
-- ============================================================================

do
  local f = CreateProgressFrame()
  
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  
  f:SetScript("OnDragStart", function(self)
    if IsShiftKeyDown() then
      self:StartMoving()
    end
  end)
  
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
  end)
  
  f:SetScript("OnEnter", function(self)
    if IsShiftKeyDown() then
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:SetText("Hold Shift and drag to move")
      GameTooltip:Show()
    end
  end)
  
  f:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
end

return NS