-- WhoDAT - events.lua (Event Bus Architecture)
-- Decouples modules via publish/subscribe pattern
-- Wrath 3.3.5a compatible

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Event Bus Core
-- ============================================================================

local EventBus = {
  _listeners = {},
  _history = {},
  _enabled = true,
}

-- ============================================================================
-- Subscribe to Events
-- ============================================================================

---Subscribe to a domain's events
---@param domain string Event domain (e.g., "container", "session", "items")
---@param handler function Callback function(action, payload)
---@return number subscriptionId Unique ID for unsubscribing
function EventBus:Subscribe(domain, handler)
  if type(handler) ~= "function" then
    if NS.Log then
      NS.Log("ERROR", "EventBus:Subscribe requires function handler")
    end
    return nil
  end
  
  self._listeners[domain] = self._listeners[domain] or {}
  local id = #self._listeners[domain] + 1
  self._listeners[domain][id] = handler
  
  return id
end

-- ============================================================================
-- Unsubscribe from Events
-- ============================================================================

---Remove a subscription
---@param domain string
---@param subscriptionId number
function EventBus:Unsubscribe(domain, subscriptionId)
  if self._listeners[domain] and self._listeners[domain][subscriptionId] then
    self._listeners[domain][subscriptionId] = nil
  end
end

-- ============================================================================
-- Emit Events
-- ============================================================================

---Emit an event to all subscribers
---@param domain string Event domain
---@param action string Event action (e.g., "added", "removed", "changed")
---@param payload table Event data
function EventBus:Emit(domain, action, payload)
  if not self._enabled then return end
  
  domain = tostring(domain or "unknown")
  action = tostring(action or "event")
  payload = payload or {}
  
  -- Add metadata
  payload._domain = domain
  payload._action = action
  payload._ts = time()
  
  -- Add session context if available
  if NS.Session_GetId then
    payload._session_id = NS.Session_GetId()
  end
  
  -- Store in history (limited size)
  self:_addToHistory(domain, action, payload)
  
  -- Call all subscribers
  local listeners = self._listeners[domain] or {}
  for _, handler in pairs(listeners) do
    local ok, err = pcall(handler, action, payload)
    if not ok then
      if NS.Log then
        NS.Log("ERROR", "EventBus subscriber error in %s: %s", domain, tostring(err))
      end
    end
  end
end

-- ============================================================================
-- Event History (for debugging/analytics)
-- ============================================================================

function EventBus:_addToHistory(domain, action, payload)
  self._history[domain] = self._history[domain] or {}
  local hist = self._history[domain]
  
  table.insert(hist, {
    action = action,
    payload = payload,
    ts = time()
  })
  
  -- Keep only last 100 events per domain
  if #hist > 100 then
    table.remove(hist, 1)
  end
end

---Get recent events for a domain
---@param domain string
---@param count number Max events to return (default 10)
---@return table events
function EventBus:GetHistory(domain, count)
  count = count or 10
  local hist = self._history[domain] or {}
  local result = {}
  
  local start = math.max(1, #hist - count + 1)
  for i = start, #hist do
    table.insert(result, hist[i])
  end
  
  return result
end

-- ============================================================================
-- Enable/Disable Event Bus
-- ============================================================================

function EventBus:Enable()
  self._enabled = true
end

function EventBus:Disable()
  self._enabled = false
end

function EventBus:IsEnabled()
  return self._enabled
end

-- ============================================================================
-- Debug Helpers
-- ============================================================================

---Print all active subscriptions
function EventBus:DebugSubscriptions()
  print("=== EventBus Subscriptions ===")
  for domain, listeners in pairs(self._listeners) do
    local count = 0
    for _ in pairs(listeners) do count = count + 1 end
    print(string.format("%s: %d subscribers", domain, count))
  end
end

---Print recent events
function EventBus:DebugHistory(domain, count)
  domain = domain or "container"
  count = count or 10
  
  print(string.format("=== Recent %s Events ===", domain))
  local events = self:GetHistory(domain, count)
  for i, evt in ipairs(events) do
    print(string.format("[%d] %s - %s (items: %d)", 
      i, 
      date("%H:%M:%S", evt.ts),
      evt.action,
      evt.payload.item_id or 0))
  end
end

-- ============================================================================
-- Export
-- ============================================================================

NS.EventBus = EventBus

-- ============================================================================
-- Default Subscriptions (Core Logging)
-- ============================================================================

-- Subscribe to container events and log to SavedVariables
EventBus:Subscribe("container", function(action, payload)
  if type(WhoDAT_LogEvent) == "function" then
    WhoDAT_LogEvent("container", action, {
      location = payload.location,
      item_id = payload.item_id,
      delta = payload.delta,
      ts = payload._ts,
      session_id = payload._session_id
    })
  end
end)

-- Subscribe to session events
EventBus:Subscribe("session", function(action, payload)
  if type(WhoDAT_LogEvent) == "function" then
    WhoDAT_LogEvent("session", action, {
      session_id = payload.session_id,
      reason = payload.reason,
      zone = payload.zone,
      ts = payload._ts
    })
  end
end)

-- Subscribe to items events (loot, vendor, etc.)
EventBus:Subscribe("items", function(action, payload)
  if type(WhoDAT_LogEvent) == "function" then
    WhoDAT_LogEvent("items", action, {
      item_id = payload.item_id or payload.id,
      link = payload.link,
      count = payload.count,
      source = payload.source,
      location = payload.location,
      context = payload.context,
      ts = payload._ts,
      session_id = payload._session_id
    })
  end
end)

-- Subscribe to quest events (accepted, completed, abandoned, objective)
EventBus:Subscribe("quests", function(action, payload)
  if type(WhoDAT_LogEvent) == "function" then
    WhoDAT_LogEvent("quests", action, {
      quest_id = payload.quest_id,
      quest_name = payload.quest_name,
      quest_level = payload.quest_level,
      is_daily = payload.is_daily,
      objectives = payload.objectives,
      rewards = payload.rewards,
      ts = payload._ts,
      session_id = payload._session_id
    })
  end
end)

-- ============================================================================
-- Slash Commands for Debugging
-- ============================================================================

SLASH_WDEVENTBUS1 = "/wdeventbus"
SLASH_WDEVENTBUS2 = "/wdeb"
SlashCmdList["WDEVENTBUS"] = function(msg)
  msg = (msg or ""):lower():trim()
  
  if msg == "subs" or msg == "subscriptions" then
    EventBus:DebugSubscriptions()
  elseif msg:match("^history") then
    local domain = msg:match("history%s+(%w+)") or "container"
    EventBus:DebugHistory(domain, 20)
  elseif msg == "disable" then
    EventBus:Disable()
    print("[WhoDAT] EventBus disabled")
  elseif msg == "enable" then
    EventBus:Enable()
    print("[WhoDAT] EventBus enabled")
  elseif msg == "test" then
    EventBus:Emit("test", "ping", { message = "Hello from EventBus!" })
    print("[WhoDAT] Test event emitted")
  else
    print("=== WhoDAT EventBus Commands ===")
    print("/wdeb subs - Show all subscriptions")
    print("/wdeb history [domain] - Show recent events")
    print("/wdeb enable/disable - Toggle EventBus")
    print("/wdeb test - Emit test event")
  end
end

return EventBus