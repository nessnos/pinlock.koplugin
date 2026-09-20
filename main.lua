--[[--
PinLock: a PIN-code lock screen for KOReader, styled after typical
e-reader lock screens (e.g. Kobo's "Settings" PIN prompt).

It can require a PIN:
  - when KOReader starts, and/or
  - whenever the device wakes up from suspend/sleep,
each independently toggleable from the plugin's own menu, and only once
a PIN has actually been set.

@module koplugin.PinLock
--]]--

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher") -- luacheck:ignore
local FontList = require("fontlist")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local PinLockWidget = require("pinlockwidget")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local sha2 = require("ffi/sha2")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

math.randomseed(os.time() + math.floor(os.clock() * 1000000))

local MIN_PIN_LENGTH = 4
local MAX_PIN_LENGTH = 8
local MAX_ATTEMPTS = 5
local LOCKOUT_SECONDS = 30

local PinLock = WidgetContainer:extend{
    name = "pinlock",
    is_doc_only = false,
}

-- These are set directly on the class table (not inside :init()), so they
-- are shared "static" state across every instance of this plugin, whether
-- it was loaded for the FileManager or for a ReaderUI. This matters
-- because KOReader creates a fresh plugin instance per document/context,
-- but we only ever want ONE "did we already show the startup lock" flag
-- and ONE "is a lock screen currently on screen" guard for the whole
-- process, not one per instance.
PinLock.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/pinlock.lua")
PinLock.startup_lock_done = false
PinLock.lock_widget = nil
PinLock.failed_attempts = 0

--- Settings helpers -------------------------------------------------------

function PinLock:hasPinSet()
    return self.settings:has("pin_hash")
end

function PinLock:getPinLength()
    return self.settings:readSetting("pin_length", MIN_PIN_LENGTH)
end

function PinLock:getKeypadFontPath()
    return self.settings:readSetting("keypad_font_path")
end

function PinLock:generateSalt()
    local hex = "0123456789abcdef"
    local chars = {}
    for i = 1, 32 do
        local idx = math.random(1, #hex)
        chars[i] = hex:sub(idx, idx)
    end
    return table.concat(chars)
end

function PinLock:computeHash(pin, salt)
    return sha2.sha256(salt .. ":" .. pin)
end

function PinLock:verifyPin(pin)
    local salt = self.settings:readSetting("pin_salt")
    local hash = self.settings:readSetting("pin_hash")
    if not salt or not hash then return false end
    return self:computeHash(pin, salt) == hash
end

function PinLock:setPin(pin)
    local salt = self:generateSalt()
    self.settings:saveSetting("pin_salt", salt)
    self.settings:saveSetting("pin_hash", self:computeHash(pin, salt))
    self.settings:flush()
end

function PinLock:clearPin()
    self.settings:delSetting("pin_hash")
    self.settings:delSetting("pin_salt")
    self.settings:saveSetting("lock_on_startup", false)
    self.settings:saveSetting("lock_on_resume", false)
    self.settings:flush()
end

--- Plugin lifecycle --------------------------------------------------------

function PinLock:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

    if not PinLock.startup_lock_done then
        PinLock.startup_lock_done = true
        if self.settings:isTrue("lock_on_startup") and self:hasPinSet() then
            -- Defer to the next tick so we show our full-screen widget
            -- after the FileManager/ReaderUI we're attached to has
            -- finished laying itself out, instead of racing it.
            UIManager:nextTick(function() self:showLockScreen() end)
        end
    end
end

function PinLock:onResume()
    if self.settings:isTrue("lock_on_resume") and self:hasPinSet() then
        self:showLockScreen()
    end
end

function PinLock:onDispatcherRegisterActions()
    Dispatcher:registerAction("pinlock_lock_now", {
        category = "none",
        event = "PinLockNow",
        title = _("Lock now (PinLock)"),
        general = true,
    })
end

function PinLock:onPinLockNow()
    self:showLockScreen()
end

--- The actual lock screen --------------------------------------------------

function PinLock:showLockScreen()
    if PinLock.lock_widget then return end -- already showing
    if not self:hasPinSet() then return end

    local widget
    local can_suspend = Device:canSuspend()
    widget = PinLockWidget:new{
        pin_length = self:getPinLength(),
        font_path = self:getKeypadFontPath(),
        -- There is no legitimate way to dismiss the actual lock screen
        -- without the correct PIN: no close (x) icon at all, and the
        -- back chevron (if the device can suspend) just puts the device
        -- back to sleep rather than unlocking anything.
        left_icon_callback = can_suspend and function()
            PinLock.lock_widget = nil
            UIManager:close(widget)
            UIManager:suspend()
        end or nil,
        on_complete = function(w, entered)
            if self:verifyPin(entered) then
                PinLock.failed_attempts = 0
                PinLock.lock_widget = nil
                UIManager:close(w)
                UIManager:setDirty("all", "full")
                return
            end

            PinLock.failed_attempts = PinLock.failed_attempts + 1
            if PinLock.failed_attempts < MAX_ATTEMPTS then
                w:flashWrong(_("Incorrect PIN"))
                return
            end

            -- Too many wrong attempts: lock the keypad for a cooldown
            -- period instead of letting a wrong PIN be retried instantly.
            w:setDisabled(true)
            local function tick(remaining)
                if not PinLock.lock_widget then return end -- unlocked/closed meanwhile
                if remaining <= 0 then
                    PinLock.failed_attempts = 0
                    w:setStatus(nil)
                    w:resetEntry()
                    w:setDisabled(false)
                else
                    w:setStatus(T(_("Too many attempts. Try again in %1s."), remaining))
                    UIManager:scheduleIn(1, function() tick(remaining - 1) end)
                end
            end
            tick(LOCKOUT_SECONDS)
        end,
    }
    PinLock.lock_widget = widget
    UIManager:show(widget, "full")
end

--- Setting/changing/removing the PIN --------------------------------------

function PinLock:promptSetPin()
    local pin_length = self:getPinLength()
    local first_pin
    local showFirstStep, showConfirmStep

    showConfirmStep = function()
        local widget
        widget = PinLockWidget:new{
            status_text = _("Confirm new PIN"),
            pin_length = pin_length,
            font_path = self:getKeypadFontPath(),
            right_icon_callback = function() UIManager:close(widget) end,
            on_complete = function(w, entered)
                if entered == first_pin then
                    UIManager:close(w)
                    self:setPin(entered)
                    UIManager:show(InfoMessage:new{ text = _("PIN saved."), timeout = 2 })
                else
                    w:flashWrong(_("PINs didn't match. Try again."))
                    UIManager:scheduleIn(1.6, function()
                        UIManager:close(w)
                        showFirstStep()
                    end)
                end
            end,
        }
        UIManager:show(widget, "full")
    end

    showFirstStep = function()
        local widget
        widget = PinLockWidget:new{
            status_text = _("Enter new PIN"),
            pin_length = pin_length,
            font_path = self:getKeypadFontPath(),
            right_icon_callback = function() UIManager:close(widget) end,
            on_complete = function(w, entered)
                first_pin = entered
                UIManager:close(w)
                showConfirmStep()
            end,
        }
        UIManager:show(widget, "full")
    end

    showFirstStep()
end

--- Keypad font picker -------------------------------------------------------

-- A friendly display name for a font file: its own name if we can get one
-- (e.g. "Noto Sans"), otherwise just its filename without the extension.
local function getFontDisplayName(path)
    local name = FontList:getLocalizedFontName(path, 0)
    if name then return name end
    local filename = select(2, util.splitFilePathName(path))
    return (util.splitFileNameSuffix(filename))
end

-- Builds the "Keypad font" submenu: "Default" plus one radio entry per font
-- installed on the device (bundled or in the user's own font folder). Built
-- lazily (only when the submenu is actually opened), since scanning fonts
-- can be slow the first time, and the result is cached by koreader itself
-- (FontList) for reuse by its own "Change font" menu.
function PinLock:genKeypadFontMenuItems()
    local items = {}

    table.insert(items, {
        text = _("Default (KOReader UI font)"),
        radio = true,
        check_callback_closes_menu = true,
        checked_func = function() return not self.settings:has("keypad_font_path") end,
        callback = function()
            self.settings:delSetting("keypad_font_path")
            self.settings:flush()
        end,
        separator = true,
    })

    for _, path in ipairs(FontList:getFontList()) do
        table.insert(items, {
            text = getFontDisplayName(path),
            radio = true,
            check_callback_closes_menu = true,
            checked_func = function()
                return self:getKeypadFontPath() == path
            end,
            callback = function()
                self.settings:saveSetting("keypad_font_path", path)
                self.settings:flush()
            end,
        })
    end

    return items
end

--- Menu ---------------------------------------------------------------------

function PinLock:addToMainMenu(menu_items)
    menu_items.pinlock = {
        text = _("PinLock"),
        sorting_hint = "screen",
        sub_item_table = {
            {
                text_func = function()
                    return self:hasPinSet() and _("Change PIN") or _("Set PIN")
                end,
                keep_menu_open = true,
                callback = function() self:promptSetPin() end,
            },
            {
                text = _("Remove PIN"),
                keep_menu_open = true,
                enabled_func = function() return self:hasPinSet() end,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Remove the PIN? PinLock will stop locking the device until you set a new one."),
                        ok_text = _("Remove"),
                        ok_callback = function() self:clearPin() end,
                    })
                end,
            },
            {
                text_func = function()
                    return T(_("PIN length: %1 digits"), self:getPinLength())
                end,
                keep_menu_open = true,
                callback = function()
                    local spin = SpinWidget:new{
                        value = self:getPinLength(),
                        value_min = MIN_PIN_LENGTH,
                        value_max = MAX_PIN_LENGTH,
                        value_step = 1,
                        value_hold_step = 2,
                        title_text = _("PIN length"),
                        info_text = self:hasPinSet()
                            and _("Changing the PIN length clears your current PIN. You'll be asked to set a new one.")
                            or nil,
                        ok_text = _("Set"),
                        callback = function(spin_widget)
                            local new_length = spin_widget.value
                            if new_length == self:getPinLength() then return end
                            local had_pin = self:hasPinSet()
                            self.settings:saveSetting("pin_length", new_length)
                            if had_pin then
                                self:clearPin()
                                UIManager:show(InfoMessage:new{
                                    text = _("PIN length changed. Please set a new PIN."),
                                    timeout = 3,
                                })
                            else
                                self.settings:flush()
                            end
                        end,
                    }
                    UIManager:show(spin)
                end,
            },
            {
                text_func = function()
                    local path = self:getKeypadFontPath()
                    return T(_("Keypad font: %1"), path and getFontDisplayName(path) or _("Default"))
                end,
                keep_menu_open = true,
                sub_item_table_func = function() return self:genKeypadFontMenuItems() end,
                separator = true,
            },
            {
                text = _("Lock on startup"),
                keep_menu_open = true,
                checked_func = function() return self.settings:isTrue("lock_on_startup") end,
                enabled_func = function() return self:hasPinSet() end,
                callback = function()
                    self.settings:toggle("lock_on_startup")
                    self.settings:flush()
                end,
            },
            {
                text = _("Lock on wake from sleep"),
                keep_menu_open = true,
                checked_func = function() return self.settings:isTrue("lock_on_resume") end,
                enabled_func = function() return self:hasPinSet() end,
                callback = function()
                    self.settings:toggle("lock_on_resume")
                    self.settings:flush()
                end,
                separator = true,
            },
            {
                text = _("Lock now"),
                enabled_func = function() return self:hasPinSet() end,
                callback = function() self:showLockScreen() end,
            },
        },
    }
end

return PinLock
