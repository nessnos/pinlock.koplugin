--[[--
PinLockWidget is a reusable, minimalist numeric PIN pad.

It is a "dumb" input widget: it only knows how to display a row of dots
showing how many digits have been entered so far and a 3x4 numeric
keypad, styled after typical e-reader lock screens (e.g. Kobo's
"Settings" PIN prompt) -- but with no title text at all, sized to a
fraction of the screen width (so there's margin on either side) and
only as tall as the pad itself needs to be, centered over a plain
full-screen background. Small back/close icons, when shown, float in
the top corners of the screen with a little margin from the bezel,
independent of the pad itself. It does NOT know what a "correct" PIN
is; that responsibility belongs to whoever creates the widget (see
main.lua), which is what makes it reusable both as the actual lock
screen and as the "set a new PIN" / "confirm new PIN" prompts in the
plugin's settings.

Colors are always drawn as plain black-on-white: KOReader's own Night
Mode (Device/UIManager) inverts the whole screen's rendering, so this
widget automatically becomes white-on-black there too, exactly like
every other KOReader dialog. It must NOT invert its own colors, or the
two inversions would cancel out.

@usage
    local widget
    widget = PinLockWidget:new{
        pin_length = 4,
        -- Called once pin_length digits have been entered.
        -- `entered` is a string of digits, e.g. "1234".
        on_complete = function(self, entered)
            if checkPin(entered) then
                UIManager:close(self)
            else
                self:flashWrong(_("Incorrect PIN"))
            end
        end,
    }
    UIManager:show(widget, "full")
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local _ = require("gettext")
local Screen = Device.screen

-- A small filled-or-outlined circle, used to show how many digits of the
-- PIN have been entered so far. e-ink has no color, so "entered" is simply
-- a solid dot and "not yet entered" is a thin ring.
local Dot = Widget:extend{
    size = nil,
    filled = false,
    color = Blitbuffer.COLOR_BLACK,
}

function Dot:init()
    self.dimen = Geom:new{ w = self.size, h = self.size }
end

function Dot:paintTo(bb, x, y)
    local r = math.floor(self.size / 2)
    local cx, cy = x + r, y + r
    if self.filled then
        bb:paintCircle(cx, cy, r, self.color)
    else
        bb:paintCircle(cx, cy, r, self.color, math.max(1, math.ceil(Screen:scaleBySize(1.5))))
    end
end

local PinLockWidget = InputContainer:extend{
    -- Absolute path to a font file to use for the keypad digits, e.g. one
    -- of the device's own fonts, picked by the user in the plugin's
    -- settings (see main.lua). If nil, or if it fails to load, the
    -- default "cfont" (KOReader's own UI font) is used instead.
    font_path = nil,
    -- How many digits make up a full PIN.
    pin_length = 4,
    -- Optional small status line shown above the dots (e.g. a lockout
    -- countdown). Empty/nil by default: nothing is shown, and no space
    -- is reserved for it, so a plain PIN entry has no text at all.
    status_text = nil,
    -- If set, a back chevron icon is shown and tapping it (or pressing a
    -- physical Back key) calls this function. If nil, no back icon is
    -- shown and the physical Back key is swallowed (does nothing), so
    -- this screen cannot be dismissed that way.
    left_icon_callback = nil,
    -- If set, a close (x) icon is shown and tapping it calls this
    -- function. If nil, no close icon is shown.
    right_icon_callback = nil,
    -- If set (to a non-empty string), a small "device owner" button is
    -- shown near the bottom of the screen; tapping it shows this text in a
    -- popup, with a close (x) to dismiss it. Meant to let someone who
    -- finds a lost, locked device see contact info without needing the
    -- PIN. Optional: nil shows no button at all. Only meaningful on the
    -- actual lock screen (main.lua doesn't set it for the set/confirm PIN
    -- prompts).
    device_owner_text = nil,
    -- Called as on_complete(self, entered_pin_string) once pin_length
    -- digits have been entered.
    on_complete = nil,

    -- Internal state.
    entered = "",
    input_disabled = false,
}

function PinLockWidget:init()
    self.entered = ""
    self.covers_fullscreen = true -- hint for UIManager:_repaint()
    self.modal = true -- stay on top of the window stack
    self.dimen = Geom:new{
        x = 0, y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }

    if Device:hasKeys() then
        -- Swallow the physical Back/Home key rather than letting it bubble
        -- down to whatever is underneath us. If we do have a back action
        -- (e.g. "suspend the device"), run that instead.
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Resolve the digit font once, up front. Font:getFace() returns nil
    -- (rather than erroring) if a font can't be loaded, but widgets like
    -- Button/TextWidget don't check for that and will hard-crash on a nil
    -- face -- so we test it ourselves here and fall back to the default
    -- "cfont", meaning a missing, removed, or unreadable font (e.g. one
    -- picked from an SD card that's since been taken out) can never take
    -- down the lock screen.
    self.digit_font_face = "cfont"
    if self.font_path and Font:getFace(self.font_path, 23) then
        self.digit_font_face = self.font_path
    end

    self:buildLayout()
end

function PinLockWidget:onClose()
    if self.left_icon_callback then
        self.left_icon_callback()
    end
    return true
end

-- (Re)builds the whole screen. Called on init and after every change
-- (digit typed, backspace, disabled state, status text change).
function PinLockWidget:buildLayout()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    -- The pad itself (dots + keypad) is narrower than the screen, with
    -- visible margin on either side, rather than running edge to edge.
    local pad_width = math.floor(screen_w * 0.65)

    -- Optional one-line status message (e.g. a lockout countdown).
    -- Reserves no space at all when there's nothing to say.
    local status_row = nil
    if self.status_text then
        status_row = CenterContainer:new{
            dimen = Geom:new{ w = pad_width, h = Screen:scaleBySize(30) },
            TextWidget:new{
                text = self.status_text,
                face = Font:getFace("cfont", 16),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }
    end

    -- Dot row: one dot per digit of the PIN, plus a backspace key shaped
    -- like a left-pointing arrow (the classic "delete" glyph), rather
    -- than a generic cancel/X icon.
    local dot_size = Screen:scaleBySize(12)
    local dot_gap = Screen:scaleBySize(18)
    local dots = HorizontalGroup:new{}
    for i = 1, self.pin_length do
        table.insert(dots, Dot:new{ size = dot_size, filled = i <= #self.entered })
        if i < self.pin_length then
            table.insert(dots, HorizontalSpan:new{ width = dot_gap })
        end
    end
    local backspace_button = Button:new{
        text = "\u{2190}", -- ← leftwards arrow
        text_font_face = "cfont",
        text_font_size = 20,
        bordersize = 0,
        radius = 0,
        margin = 0,
        padding = 0,
        width = Screen:scaleBySize(26),
        height = Screen:scaleBySize(26),
        enabled = not self.input_disabled,
        callback = function() self:backspace() end,
    }
    local dot_row_h = Screen:scaleBySize(50)
    local dot_row = CenterContainer:new{
        dimen = Geom:new{ w = pad_width, h = dot_row_h },
        HorizontalGroup:new{
            dots,
            HorizontalSpan:new{ width = Screen:scaleBySize(22) },
            backspace_button,
        },
    }

    -- Keypad: fixed-height rows of 1-2-3 / 4-5-6 / 7-8-9 / 0, separated
    -- by faint horizontal divider lines only -- no vertical dividers
    -- between columns. Rows are a fixed, compact height (not stretched
    -- to fill the screen), which is what keeps the whole pad compact
    -- rather than full-screen.
    local line_color = Blitbuffer.COLOR_GRAY_E -- very faint divider lines, uniform throughout
    local function hline(width)
        return LineWidget:new{
            dimen = Geom:new{ w = width, h = Size.line.thin },
            background = line_color,
        }
    end

    -- The keypad itself (digit rows) is a bit narrower than the dot row
    -- above it, so the digits sit closer together horizontally; VerticalGroup
    -- centers it automatically within the wider pad.
    local keypad_width = math.floor(pad_width * 0.8)
    local row_h = Screen:scaleBySize(56)
    local col_w = math.floor(keypad_width / 3)

    -- Resolved once in init() -- either the user's chosen font (verified to
    -- actually load) or the default "cfont"; see there.
    local digit_font_face = self.digit_font_face

    local function keyButton(label, width, height)
        return Button:new{
            text = label,
            text_font_face = digit_font_face,
            text_font_size = 23,
            bordersize = 0,
            radius = 0,
            margin = 0,
            padding = 0,
            width = width,
            height = height,
            enabled = not self.input_disabled,
            callback = function() self:appendDigit(label) end,
        }
    end

    local keypad = VerticalGroup:new{}
    table.insert(keypad, hline(keypad_width))
    local digit_rows = { { "1", "2", "3" }, { "4", "5", "6" }, { "7", "8", "9" } }
    for _, row in ipairs(digit_rows) do
        local hgroup = HorizontalGroup:new{}
        for _, label in ipairs(row) do
            table.insert(hgroup, keyButton(label, col_w, row_h))
        end
        table.insert(keypad, hgroup)
        table.insert(keypad, hline(keypad_width))
    end
    -- No divider under the "0" row itself, on purpose.
    table.insert(keypad, keyButton("0", keypad_width, row_h))

    -- Assemble the compact "pad": status, dots, keypad -- only as tall
    -- (and as wide) as its content needs, nothing stretched.
    local pad = VerticalGroup:new{}
    if status_row then
        table.insert(pad, status_row)
    end
    table.insert(pad, dot_row)
    table.insert(pad, keypad)

    -- Full-screen plain background (white; KOReader's Night Mode inverts
    -- this to black automatically), with the compact pad centered on it,
    -- with room to spare on its left and right.
    local background = FrameContainer:new{
        width = screen_w,
        height = screen_h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            pad,
        },
    }

    -- Back/close icons: small, pinned to the very top corners of the
    -- screen (not part of the centered pad), with a little margin from
    -- the bezel, floating over the background.
    local icon_size = Screen:scaleBySize(24)
    -- The back chevron is narrower than it is tall, so it reads as a
    -- slimmer arrow rather than a wide, chunky glyph.
    local chevron_width = math.floor(icon_size * 0.6)
    local icon_side_margin = Screen:scaleBySize(20)
    local icon_top_margin = Screen:scaleBySize(14)
    local overlay = { dimen = Geom:new{ w = screen_w, h = screen_h }, background }
    if self.left_icon_callback then
        table.insert(overlay, IconButton:new{
            icon = "chevron.left",
            width = chevron_width,
            height = icon_size,
            padding = 0,
            show_parent = self,
            callback = self.left_icon_callback,
            overlap_offset = { icon_side_margin, icon_top_margin },
        })
    end
    if self.right_icon_callback then
        table.insert(overlay, IconButton:new{
            icon = "close",
            width = icon_size,
            height = icon_size,
            padding = 0,
            show_parent = self,
            callback = self.right_icon_callback,
            overlap_offset = { screen_w - icon_size - icon_side_margin, icon_top_margin },
        })
    end

    -- Optional small "device owner" button, floating near the bottom of
    -- the screen (independent of the centered pad), for someone who finds
    -- a lost, locked device to see contact info without needing the PIN.
    if self.device_owner_text and self.device_owner_text ~= "" then
        local device_owner_button = Button:new{
            text = _("device owner"),
            -- Match the keypad's own font choice, not the general UI font.
            text_font_face = digit_font_face,
            text_font_size = 11,
            bordersize = Size.border.thin,
            radius = 0, -- plain square corners, not rounded
            margin = 0,
            padding_h = Screen:scaleBySize(14),
            padding_v = Screen:scaleBySize(8),
            callback = function() self:showDeviceOwnerInfo() end,
        }
        -- Paint it black-on-white ourselves, rather than through Button's
        -- own `background` field: that field is *also* what
        -- Button:_doFeedbackHighlight() checks to decide whether the tap
        -- highlight gets rounded corners -- which would make the pressed
        -- state rounded even though the button itself is square. Poking
        -- the colors directly here keeps radius == 0 throughout, so the
        -- highlight instead uses a plain rectangle invert that matches
        -- the button's actual (square) shape. Button also always renders
        -- its label in black regardless of `background`, so the white
        -- text needs the same direct treatment (mirroring the fgcolor +
        -- optional :update() poke Button:enable()/disable() uses
        -- internally). Since it's all still plain black-on-white under
        -- the hood, koreader's Night Mode inverts it the same way it
        -- inverts everything else -- white background, black text --
        -- with no dark-mode-specific code of our own needed.
        device_owner_button.frame.background = Blitbuffer.COLOR_BLACK
        device_owner_button.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
        if device_owner_button.label_widget.update then
            device_owner_button.label_widget:update()
        end
        local button_size = device_owner_button:getSize()
        local bottom_margin = Screen:scaleBySize(16)
        table.insert(overlay, device_owner_button)
        device_owner_button.overlap_offset = {
            math.floor((screen_w - button_size.w) / 2),
            screen_h - button_size.h - bottom_margin,
        }
    end

    self[1] = OverlapGroup:new(overlay)
end

-- Shows the device owner's message in a small, dismissible popup (with the
-- usual koreader close "x" in its title bar) -- sized to fit the message
-- itself rather than the whole screen, with no button row underneath.
function PinLockWidget:showDeviceOwnerInfo()
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local popup_width = math.floor(screen_w * 0.75)
    local title = _("Device Owner")

    -- TextViewer is built to fill most of the screen and to always show a
    -- title bar plus a bottom row of buttons. We pass an empty
    -- buttons_table to drop that button row (leaving just its hairline-thin
    -- separator, a pixel or so), and compute our own `height` so the popup
    -- is only as tall as the title bar plus the message actually needs --
    -- mirroring TextViewer's own internal layout math so our estimate
    -- matches what it will really draw.
    local titlebar = TitleBar:new{
        width = popup_width,
        align = "left",
        with_bottom_line = true,
        title = title,
        show_parent = self,
    }
    local titlebar_h = titlebar:getHeight()
    titlebar:free()

    local text_padding = Size.padding.large
    local text_margin = Size.margin.small
    -- Same width reduction ScrollTextWidget applies internally for its
    -- scrollbar gutter, so our measurement matches the real thing.
    local scroll_bar_width = Screen:scaleBySize(6)
    local text_scroll_span = Screen:scaleBySize(12)
    local content_width = popup_width - 2 * (text_padding + text_margin)
        - scroll_bar_width - text_scroll_span

    local measure = TextBoxWidget:new{
        text = self.device_owner_text,
        face = Font:getFace("x_smallinfofont", 20),
        width = content_width,
        for_measurement_only = true,
    }
    local content_h = measure:getSize().h
    measure:free(true)

    -- A little slack so a font-metric rounding difference can't force an
    -- unwanted scrollbar, capped so we never exceed the screen itself.
    local slack = Screen:scaleBySize(6)
    local popup_height = math.min(
        screen_h - Screen:scaleBySize(30),
        titlebar_h + content_h + 2 * (text_padding + text_margin) + Size.line.medium + slack
    )

    UIManager:show(TextViewer:new{
        title = title,
        text = self.device_owner_text,
        width = popup_width,
        height = popup_height,
        buttons_table = {},
        -- Without this, TextViewer (not modal by default) would be stacked
        -- *below* this lock screen widget (which is modal), since koreader
        -- always keeps modal widgets on top of non-modal ones regardless of
        -- show() order -- meaning the popup would be invisible and
        -- untappable until the lock screen itself closes.
        modal = true,
    })
end

function PinLockWidget:refresh()
    self:buildLayout()
    UIManager:setDirty(self, "ui")
end

function PinLockWidget:appendDigit(digit)
    if self.input_disabled then return end
    if #self.entered >= self.pin_length then return end
    self.entered = self.entered .. digit
    self:refresh()
    if #self.entered == self.pin_length then
        local entered = self.entered
        UIManager:scheduleIn(0.15, function()
            if self.on_complete then
                self.on_complete(self, entered)
            end
        end)
    end
end

function PinLockWidget:backspace()
    if self.input_disabled then return end
    if #self.entered == 0 then return end
    self.entered = self.entered:sub(1, -2)
    self:refresh()
end

function PinLockWidget:resetEntry()
    self.entered = ""
    self:refresh()
end

function PinLockWidget:setDisabled(disabled)
    self.input_disabled = disabled
    self:refresh()
end

function PinLockWidget:setStatus(text)
    self.status_text = text
    self:refresh()
end

-- Clears the entered digits and shows a brief message. e-ink has no red,
-- so we don't try to "flash" the dots; a short toast plus an immediate
-- reset is clearer anyway.
function PinLockWidget:flashWrong(message)
    self:resetEntry()
    UIManager:show(InfoMessage:new{
        text = message or _("Incorrect PIN"),
        timeout = 1.5,
    })
end

return PinLockWidget
