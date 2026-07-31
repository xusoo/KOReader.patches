--[[
    Track Reading Location v1.1.0

    This patch remembers the last "confirmed" reading position (the furthest page
    you've actually read) for the book you're currently reading.

    If you page backward more than one page - one page at a time or in a single
    jump (progress bar, etc.) - a small floating pill-shaped button appears at
    the bottom-right of the screen. If you jump forward more than two pages at
    once (e.g. tapping a table of contents entry that lands you in the
    appendix), the same button appears mirrored at the bottom-left. What it
    shows is configurable independently (Reader menu -> Navigation -> hold "Go
    to furthest reading location"):

    - "Show full text": include the "Go back to page" wording.
    - "Show page number": include the page number next to the arrow.
    - "Show dismiss button": include a tappable "X" to cancel/dismiss.
    - "Mode: Pages/Percentage": show the reference point as a page number
      (default) or as a percentage of the book, both on the button and in
      the "Go back to..." wording.

    With everything off, the button shrinks to just a small circular arrow.

    - Tapping the go-back side (or the whole button, if there's no dismiss
      section) jumps back to that page.
    - Tapping the "X" - or, if it isn't shown, holding the button instead -
      cancels the prompt and accepts your current page as the new reference
      point (it won't nag you about this jump again).
    - Reading normally (forward, or drifting back by at most one page) silently
      advances the remembered position - no popup.

    The button is drawn as an overlay on top of the page (like KOReader's own
    footer/progress bar), so it never blocks taps anywhere else on the screen -
    you can keep turning pages or open menus while it's showing.

    A "Go to furthest reading location (hold for settings)" menu entry (Reader menu ->
    Navigation, right below "Go forward to next location") lets you jump to
    your reference page at any time with a tap, and can also be bound to a
    gesture via the gesture manager. Holding the same menu entry opens a
    settings submenu with a "Show button on screen" checkbox (to turn the
    floating button off entirely if you'd rather only use the menu/gesture),
    the three display checkboxes described above, a "Show shadow" checkbox
    (toggles the button's drop shadow), "Bottom offset"/"Side offset"
    settings to adjust how far the button is docked from the bottom and side
    edges of the screen (applied the same way to both corners), and a
    "Button radius" setting to adjust how rounded its corners are, from 0
    (square) up to fully rounded (pill/circle, the default).

    A second, standalone "Set current page as reading location" action is
    also available, both as its own menu entry (right below "Go to furthest
    reading location") and as a system action (gesture manager, profiles,
    etc.). It accepts the current page as the new reference point on demand -
    the same thing tapping/holding the button's "X" does - without needing an
    active prompt to dismiss first.

    The reference page is saved per book, so a pending prompt will still be there
    if you close the book and reopen it later.

    This patch works for both paginated documents (PDF, CBZ, DjVu...) and
    reflowable documents (EPUB, FB2...).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local ReaderLink = require("apps/reader/modules/readerlink")
local ReaderUI = require("apps/reader/readerui")
local ReaderView = require("apps/reader/modules/readerview")
local Size = require("ui/size")
local SpinWidget = require("ui/widget/spinwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

logger.dbg("ReadingLocationTracker Patch: Loading...")

local SETTING_SHOW_BUTTON = "readingloc_show_floating_button"
-- Independent display toggles for the floating button's content (all
-- default on, matching the button's original look). With all three off,
-- the button shrinks to a small circular arrow, and holding it (instead of
-- tapping a visible "X") is how you cancel/dismiss - see
-- ReadingLocationOverlay:handleHold.
local SETTING_SHOW_FULL_TEXT = "readingloc_show_full_text"
local SETTING_SHOW_PAGE_NUMBER = "readingloc_show_page_number"
local SETTING_SHOW_DISMISS_BUTTON = "readingloc_show_dismiss_button"
-- Whether the reference point is displayed (button + "Go back to..." wording)
-- as a page number (default) or as a percentage of the book.
local SETTING_MODE_PERCENTAGE = "readingloc_mode_percentage"

-- The button is always docked to its fixed bottom-left/bottom-right corner.
-- Its distance from the bottom edge, and from whichever side edge (left or
-- right) it's currently anchored to, is configurable from the settings
-- submenu - the same two values apply to both corners.
local BUTTON_BASE_MARGIN = 14
local SETTING_OFFSET_BOTTOM = "readingloc_offset_bottom"
local SETTING_OFFSET_SIDE = "readingloc_offset_side"

-- Whether the button casts a small drop shadow (see paintButtonShadow below).
local SETTING_SHOW_SHADOW = "readingloc_show_shadow"

-- Corner radius of the button, in unscaled px like the offset settings above.
-- Defaults intentionally oversized - bb:paintRoundedRect/paintBorder already
-- clamp radius down to at most half the button's own height/width, so a big
-- default always resolves to a full pill, matching the button's original
-- hardcoded look, while still leaving smaller values (down to 0, i.e. square
-- corners) available to the settings submenu's spinner.
local BUTTON_RADIUS_DEFAULT = 25
local SETTING_BUTTON_RADIUS = "readingloc_button_radius"

-- Forward-declared so ReadingLocationOverlay's methods (defined next) can already
-- reference it by the time they're actually called at runtime.
local ReadingLocationTracker = {}

-- Label a page number the same way KOReader's own footer does, respecting
-- the user's real-page-numbers-vs-computed-pagination setting (page maps,
-- hidden reading flows), instead of always showing the raw internal page
-- number. This only affects the displayed text - the anchor tracking/delta
-- math below always uses the raw internal page number, since real-page
-- labels aren't guaranteed to be sequential integers.
local function getPageLabel(ui, pageno)
    local ok, label = pcall(function()
        if ui.pagemap and ui.pagemap:wantsPageLabels() then
            local xp = ui.document:getPageXPointer(pageno)
            if xp then
                return ui.pagemap:getXPointerPageLabel(xp, true)
            end
        elseif ui.document.hasHiddenFlows and ui.document:hasHiddenFlows() then
            local flow = ui.document:getPageFlow(pageno)
            local page_in_flow = ui.document:getPageNumberInFlow(pageno)
            if flow == 0 then
                return tostring(page_in_flow)
            else
                return ("[%d]%d"):format(page_in_flow, flow)
            end
        end
        return tostring(pageno)
    end)
    if ok and label then
        return tostring(label)
    end
    return tostring(pageno)
end

-- Labels a location the way the floating button/menu wording should show it:
-- a page label (see getPageLabel above), or, when percentage mode is on, the
-- position as a percentage of the total page count - falling back to the
-- page label if the page count isn't available yet.
local function getLocationLabel(ui, pageno)
    if ReadingLocationTracker.isPercentageModeEnabled() then
        local page_count = ReadingLocationTracker.getPageCount(ui)
        if page_count and page_count > 0 then
            return math.floor((pageno / page_count) * 100 + 0.5) .. "%"
        end
    end
    return getPageLabel(ui, pageno)
end

--[[ ---------------------------------------------------------------------
     Floating split-button overlay (painted as part of the page, like
     KOReader's own footer/progress bar - never a separate modal window)
----------------------------------------------------------------------- ]]

local ReadingLocationOverlay = WidgetContainer:extend{
    ui = nil,
    view = nil,
    visible = false,
    side = "bottom_right", -- or "bottom_left"
    anchor = 0,
    -- Forces the button to render on BOTH corners at once, purely so the
    -- settings submenu can preview both dockings side by side - see the
    -- "hold for settings" hold_callback. `side` still names the "real"
    -- one used for hit-testing; the mirrored one is decorative only.
    preview_both_sides = false,
}

function ReadingLocationOverlay:_getBox(side)
    side = side or self.side
    local show_full_text = ReadingLocationTracker.isFullTextEnabled()
    local show_page_number = ReadingLocationTracker.isPageNumberEnabled()
    local show_dismiss = ReadingLocationTracker.isDismissButtonEnabled()
    local percentage_mode = ReadingLocationTracker.isPercentageModeEnabled()
    local button_radius = ReadingLocationTracker.getButtonRadius()
    local key = table.concat({
        side, tostring(self.anchor),
        tostring(show_full_text), tostring(show_page_number), tostring(show_dismiss),
        tostring(percentage_mode), tostring(button_radius),
    }, ":")
    if side == self._cached_side and self._box and self._box_key == key then
        return self._box
    end

    local box = self:_getButtonBox(side, show_full_text, show_page_number, show_dismiss)

    if side == self.side then
        -- Only cache (and only let it feed hit-testing) for the "real"
        -- side - a mirrored preview box is built fresh every repaint and
        -- must never overwrite the real side's _goback_w/_cancel_w/_sep_w.
        self._box = box
        self._box_key = key
        self._cached_side = side
    end
    return box
end

-- The "Go back to page X" section (built from whichever of show_full_text/
-- show_page_number are on - if neither is, it's just the arrow), plus an
-- optional "X" section to cancel/dismiss.
function ReadingLocationOverlay:_getButtonBox(side, show_full_text, show_page_number, show_dismiss)
    local face = Font:getFace("cfont", 16)
    local pad_h = Screen:scaleBySize(14)
    local pad_v = Screen:scaleBySize(8)
    local arrow = side == "bottom_left" and "\u{2190}" or "\u{2192}"

    -- The outer frame's ends are fully rounded (see the pill radius
    -- below), but each section's own padding is symmetric - only the side
    -- of a section that actually faces an outward (curved) end needs the
    -- extra room; the side facing the flat middle separator doesn't.
    local pad_h_extra = Screen:scaleBySize(2)
    local goback_pad_left, goback_pad_right = pad_h, pad_h
    local cancel_pad_left, cancel_pad_right = pad_h, pad_h
    if show_dismiss then
        -- "Go back" sits on the screen-corner-facing edge, "X" on the
        -- content-facing edge - whichever of the two ends up outermost
        -- (left or right) gets the extra padding on that side only.
        if side == "bottom_left" then
            goback_pad_left = goback_pad_left + pad_h_extra
            cancel_pad_right = cancel_pad_right + pad_h_extra
        else
            cancel_pad_left = cancel_pad_left + pad_h_extra
            goback_pad_right = goback_pad_right + pad_h_extra
        end
    end

    -- Point the arrow toward the screen edge this button is docked to.
    local words = {}
    if show_full_text then
        -- "page" doesn't read well in front of a percentage ("page 42%"),
        -- so it's dropped from the wording in that mode.
        if ReadingLocationTracker.isPercentageModeEnabled() then
            table.insert(words, _("Go back to"))
        else
            table.insert(words, _("Go back to page"))
        end
    end
    if show_page_number then
        table.insert(words, getLocationLabel(self.ui, self.anchor))
    end
    local label = table.concat(words, " ")
    local goback_text
    if label == "" then
        -- Neither text toggle is on - just the arrow, alone or next to a
        -- separate "X" section.
        goback_text = arrow
    else
        goback_text = side == "bottom_left" and (arrow .. " " .. label) or (label .. " " .. arrow)
    end
    local goback_section = FrameContainer:new{
        bordersize = 0,
        radius = 0,
        margin = 0,
        padding_top = pad_v,
        padding_bottom = pad_v,
        padding_left = goback_pad_left,
        padding_right = goback_pad_right,
        TextWidget:new{
            text = goback_text,
            face = face,
        },
    }

    local content
    if show_dismiss then
        local cancel_section = FrameContainer:new{
            bordersize = 0,
            radius = 0,
            margin = 0,
            padding_top = pad_v,
            padding_bottom = pad_v,
            padding_left = cancel_pad_left,
            padding_right = cancel_pad_right,
            TextWidget:new{
                text = "\u{2715}", -- "X" close mark
                face = face,
            },
        }

        local row_h = math.max(goback_section:getSize().h, cancel_section:getSize().h)
        local sep_w = Screen:scaleBySize(1)
        local separator = LineWidget:new{
            background = Blitbuffer.COLOR_BLACK,
            dimen = Geom:new{ w = sep_w, h = row_h },
        }

        -- "Go back" (with its arrow) sits on the screen-corner-facing edge,
        -- "X" on the content-facing edge next to it.
        local children
        if side == "bottom_left" then
            children = { goback_section, separator, cancel_section }
        else
            children = { cancel_section, separator, goback_section }
        end
        content = HorizontalGroup:new(children)

        if side == self.side then
            self._goback_w = goback_section:getSize().w
            self._cancel_w = cancel_section:getSize().w
            self._sep_w = sep_w
        end
    else
        content = goback_section
        if side == self.side then
            self._goback_w, self._cancel_w, self._sep_w = nil, nil, nil
        end
    end

    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.thin,
        -- The configured radius gets clamped down by paintRoundedRect/
        -- paintBorder (see base/ffi/blitbuffer.lua) to at most half the
        -- button's own height - so the default (BUTTON_RADIUS_DEFAULT,
        -- intentionally oversized) always resolves to a pill shape, or a
        -- circle when the content ends up about as wide as it is tall (e.g.
        -- arrow-only, no text, no dismiss section), while a smaller value
        -- from the settings submenu's spinner yields a less rounded button,
        -- down to square corners at 0.
        radius = Screen:scaleBySize(ReadingLocationTracker.getButtonRadius()),
        padding = 0,
        margin = 0,
        content,
    }
end

-- Shared by paintButtonShadow and growRegionForShadow below, so the
-- refresh-region padding always matches how far the shadow is actually
-- offset - drifting the two apart would leave a stale sliver of shadow on
-- screen once the button's gone (see growRegionForShadow).
local SHADOW_OFFSET = 2

local function paintButtonShadow(bb, box_x, box_y, w, h, radius)
    local offset = Screen:scaleBySize(SHADOW_OFFSET)
    bb:paintRoundedRect(box_x, box_y + offset, w, h, Blitbuffer.COLOR_GRAY_9, radius)
end

-- The shadow pokes out a few pixels past the button's own bottom edge (see
-- paintButtonShadow above) - a refresh region sized to just box_dimen would
-- leave a stale sliver of it on screen once the button's gone, since e-ink
-- only actually re-flashes whatever rect it's told to. Only grows downward,
-- matching the shadow's own offset direction, and only when the shadow is
-- actually enabled.
local function growRegionForShadow(region)
    if not region or not ReadingLocationTracker.isShadowEnabled() then
        return region
    end
    local pad = Screen:scaleBySize(SHADOW_OFFSET)
    return Geom:new{ x = region.x, y = region.y, w = region.w, h = region.h + pad }
end

-- Called by our ReaderView:paintTo hook on every page repaint.
function ReadingLocationOverlay:paintTo(bb, x, y)
    if not self.visible then
        self.box_dimen = nil
        return
    end

    local ok, err = pcall(function()
        local show_dismiss = ReadingLocationTracker.isDismissButtonEnabled()
        local box = self:_getBox()
        local w, h = box:getSize().w, box:getSize().h

        local view_w = (self.view and self.view.dimen and self.view.dimen.w) or Screen:getWidth()
        local view_h = (self.view and self.view.dimen and self.view.dimen.h) or Screen:getHeight()

        local margin_x = ReadingLocationTracker.getSideMargin()
        local margin_y = ReadingLocationTracker.getBottomMargin()
        local box_x
        if self.side == "bottom_left" then
            box_x = x + margin_x
        else
            box_x = x + view_w - w - margin_x
        end
        local box_y = y + view_h - h - margin_y

        self.box_dimen = Geom:new{ x = box_x, y = box_y, w = w, h = h }

        if not show_dismiss then
            -- No visible "X": the whole button is a single hit target, tap
            -- goes back, and holding it is how you cancel/dismiss instead
            -- (see handleHold).
            self.goback_dimen = self.box_dimen
            self.cancel_dimen = nil
        else
            -- The box's own border sits between box_x/box_y and where the
            -- goback/cancel sections actually start - without this offset the
            -- computed hit-boxes drift from what's actually drawn, most
            -- noticeably on the narrow "X" section.
            local border = Size.border.thin
            local content_x = box_x + border
            local content_y = box_y + border
            local content_h = h - (2 * border)
            -- Must mirror _getButtonBox()'s children order exactly, or the
            -- hit-boxes end up swapped relative to what's actually drawn.
            if self.side == "bottom_left" then
                self.goback_dimen = Geom:new{ x = content_x, y = content_y, w = self._goback_w, h = content_h }
                self.cancel_dimen = Geom:new{ x = content_x + self._goback_w + self._sep_w, y = content_y, w = self._cancel_w, h = content_h }
            else
                self.cancel_dimen = Geom:new{ x = content_x, y = content_y, w = self._cancel_w, h = content_h }
                self.goback_dimen = Geom:new{ x = content_x + self._cancel_w + self._sep_w, y = content_y, w = self._goback_w, h = content_h }
            end
        end

        local button_radius = Screen:scaleBySize(ReadingLocationTracker.getButtonRadius())
        if ReadingLocationTracker.isShadowEnabled() then
            paintButtonShadow(bb, box_x, box_y, w, h, button_radius)
        end
        box:paintTo(bb, box_x, box_y)

        if self.preview_both_sides then
            -- Purely decorative: painted at the opposite corner so both
            -- dockings can be compared side by side, but not wired up to
            -- goback_dimen/cancel_dimen - self.side stays the only side
            -- that's actually tappable.
            local other_side = self.side == "bottom_left" and "bottom_right" or "bottom_left"
            local other_box = self:_getBox(other_side)
            local ow, oh = other_box:getSize().w, other_box:getSize().h
            -- Same margin values as the real side - they aren't per-corner.
            local other_x
            if other_side == "bottom_left" then
                other_x = x + margin_x
            else
                other_x = x + view_w - ow - margin_x
            end
            local other_y = y + view_h - oh - margin_y
            if ReadingLocationTracker.isShadowEnabled() then
                paintButtonShadow(bb, other_x, other_y, ow, oh, button_radius)
            end
            other_box:paintTo(bb, other_x, other_y)
        end
    end)
    if not ok then
        logger.warn("ReadingLocationTracker: overlay paintTo error:", err)
    end
end

-- Runs the button's action (go back / cancel) if `pos` lands on it.
function ReadingLocationOverlay:_activate(pos)
    if not self.visible or not self.box_dimen or not self.box_dimen:contains(pos) then
        return false
    end
    if self.cancel_dimen and self.cancel_dimen:contains(pos) then
        ReadingLocationTracker.onCancel(self.ui)
    elseif self.goback_dimen and self.goback_dimen:contains(pos) then
        ReadingLocationTracker.onGoBack(self.ui)
    end
    return true
end

-- Precise hit test, called from a touch zone registered on ReaderUI. Returns
-- true only when the tap actually lands on the button (consuming it and
-- preventing the underlying page-turn zone from also firing); returns a
-- falsy value otherwise so the normal page-turn/menu zone still runs.
function ReadingLocationOverlay:handleTap(ges)
    if self:_activate(ges.pos) then
        return true
    end
end

-- When there's no visible "X" section to tap, holding the button is how
-- you cancel/dismiss instead. When the dismiss button IS shown, a hold
-- here is a no-op and falls through to whatever hold zone is normally
-- underneath (e.g. the dictionary lookup on selected text).
function ReadingLocationOverlay:_activateHold(pos)
    if not self.visible or ReadingLocationTracker.isDismissButtonEnabled() then
        return false
    end
    if not self.box_dimen or not self.box_dimen:contains(pos) then
        return false
    end
    ReadingLocationTracker.onCancel(self.ui)
    return true
end

function ReadingLocationOverlay:handleHold(ges)
    if self:_activateHold(ges.pos) then
        return true
    end
end

function ReadingLocationOverlay:setupTouchZones()
    if self._zones_registered then
        return
    end
    self._zones_registered = true

    -- Take priority over every tap/hold zone already registered on the
    -- reader at this point - page-turn corners, the bottom footer bar,
    -- menu-toggle zones, etc. - so our button always gets first look at a
    -- tap/hold landing on it, regardless of which zone layout or KOReader
    -- version is in use (this is what was previously letting bottom-bar/
    -- corner taps win over the button - overriding only a few hardcoded
    -- zone ids wasn't enough).
    local zone_overrides = {
        -- Known ids, kept explicit in case they get (re-)registered later.
        "readerconfigmenu_ext_tap",
        "readerconfigmenu_tap",
        "tap_forward",
        "tap_backward",
        "readerfooter_tap",
        "readerhighlight_hold",
    }
    if self.ui._zones then
        for id in pairs(self.ui._zones) do
            table.insert(zone_overrides, id)
        end
    end
    -- The button always sits in its fixed bottom-left/bottom-right corner,
    -- so a generous bottom strip on each half is enough to reach it.
    self.ui:registerTouchZones{
        {
            id = "readingloc_tap_left",
            ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0.75, ratio_w = 0.5, ratio_h = 0.25 },
            handler = function(ges) return self:handleTap(ges) end,
            overrides = zone_overrides,
        },
        {
            id = "readingloc_tap_right",
            ges = "tap",
            screen_zone = { ratio_x = 0.5, ratio_y = 0.75, ratio_w = 0.5, ratio_h = 0.25 },
            handler = function(ges) return self:handleTap(ges) end,
            overrides = zone_overrides,
        },
        {
            id = "readingloc_hold_left",
            ges = "hold",
            screen_zone = { ratio_x = 0, ratio_y = 0.75, ratio_w = 0.5, ratio_h = 0.25 },
            handler = function(ges) return self:handleHold(ges) end,
            overrides = zone_overrides,
        },
        {
            id = "readingloc_hold_right",
            ges = "hold",
            screen_zone = { ratio_x = 0.5, ratio_y = 0.75, ratio_w = 0.5, ratio_h = 0.25 },
            handler = function(ges) return self:handleHold(ges) end,
            overrides = zone_overrides,
        },
    }
end

--[[ ---------------------------------------------------------------------
     Anchor tracking state machine
----------------------------------------------------------------------- ]]

function ReadingLocationTracker.isFloatingButtonEnabled()
    local v = G_reader_settings:readSetting(SETTING_SHOW_BUTTON)
    if v == nil then
        return true
    end
    return v == true
end

function ReadingLocationTracker.setFloatingButtonEnabled(enabled)
    G_reader_settings:saveSetting(SETTING_SHOW_BUTTON, enabled and true or false)
end

function ReadingLocationTracker.isFullTextEnabled()
    local v = G_reader_settings:readSetting(SETTING_SHOW_FULL_TEXT)
    if v == nil then
        return true
    end
    return v == true
end

function ReadingLocationTracker.setFullTextEnabled(enabled)
    G_reader_settings:saveSetting(SETTING_SHOW_FULL_TEXT, enabled and true or false)
end

function ReadingLocationTracker.isPageNumberEnabled()
    if ReadingLocationTracker.isFullTextEnabled() then
        -- "Go back to page" doesn't make sense without the page number.
        return true
    end
    local v = G_reader_settings:readSetting(SETTING_SHOW_PAGE_NUMBER)
    if v == nil then
        return true
    end
    return v == true
end

function ReadingLocationTracker.setPageNumberEnabled(enabled)
    G_reader_settings:saveSetting(SETTING_SHOW_PAGE_NUMBER, enabled and true or false)
end

function ReadingLocationTracker.isDismissButtonEnabled()
    local v = G_reader_settings:readSetting(SETTING_SHOW_DISMISS_BUTTON)
    if v == nil then
        return true
    end
    return v == true
end

function ReadingLocationTracker.setDismissButtonEnabled(enabled)
    G_reader_settings:saveSetting(SETTING_SHOW_DISMISS_BUTTON, enabled and true or false)
end

function ReadingLocationTracker.isShadowEnabled()
    local v = G_reader_settings:readSetting(SETTING_SHOW_SHADOW)
    if v == nil then
        return true
    end
    return v == true
end

function ReadingLocationTracker.setShadowEnabled(enabled)
    G_reader_settings:saveSetting(SETTING_SHOW_SHADOW, enabled and true or false)
end

function ReadingLocationTracker.isPercentageModeEnabled()
    local v = G_reader_settings:readSetting(SETTING_MODE_PERCENTAGE)
    if v == nil then
        return false
    end
    return v == true
end

function ReadingLocationTracker.setPercentageModeEnabled(enabled)
    G_reader_settings:saveSetting(SETTING_MODE_PERCENTAGE, enabled and true or false)
end

function ReadingLocationTracker.getBottomOffset()
    local v = G_reader_settings:readSetting(SETTING_OFFSET_BOTTOM)
    if type(v) ~= "number" then
        return 0
    end
    return v
end

function ReadingLocationTracker.setBottomOffset(value)
    G_reader_settings:saveSetting(SETTING_OFFSET_BOTTOM, value)
end

function ReadingLocationTracker.getSideOffset()
    local v = G_reader_settings:readSetting(SETTING_OFFSET_SIDE)
    if type(v) ~= "number" then
        return 0
    end
    return v
end

function ReadingLocationTracker.setSideOffset(value)
    G_reader_settings:saveSetting(SETTING_OFFSET_SIDE, value)
end

function ReadingLocationTracker.getButtonRadius()
    local v = G_reader_settings:readSetting(SETTING_BUTTON_RADIUS)
    if type(v) ~= "number" then
        return BUTTON_RADIUS_DEFAULT
    end
    return v
end

function ReadingLocationTracker.setButtonRadius(value)
    G_reader_settings:saveSetting(SETTING_BUTTON_RADIUS, value)
end

-- Total distance the button is docked away from the bottom edge / from
-- whichever side edge (left or right) it's currently anchored to.
function ReadingLocationTracker.getBottomMargin()
    return Screen:scaleBySize(BUTTON_BASE_MARGIN + ReadingLocationTracker.getBottomOffset())
end

function ReadingLocationTracker.getSideMargin()
    return Screen:scaleBySize(BUTTON_BASE_MARGIN + ReadingLocationTracker.getSideOffset())
end

function ReadingLocationTracker.getPageCount(ui)
    local ok, count = pcall(function() return ui.document:getPageCount() end)
    if ok and type(count) == "number" and count > 0 then
        return count
    end
    return nil
end

-- Forces a clean repaint of a screen region (used whenever we hide the
-- overlay outside of a normal page-turn, e.g. on cancel). setDirty(nil, ...)
-- only re-flashes whatever's already in the screen buffer without calling
-- any widget's paintTo again - since our button is baked directly into
-- ReaderView's own paintTo (not a separate window), that would just re-flash
-- the stale buffer with the button still in it. Passing the reader's own
-- top-level widget (ui.dialog, which ReaderUI sets to itself) marks it dirty
-- so paintTo actually reruns - skipping the button now that it's hidden -
-- before the flash. Uses a flashing refresh so no e-ink ghost is left.
local function refreshRegion(ui, region, refresh_type)
    if not region then
        return
    end
    UIManager:setDirty(ui.dialog or ui, function() return refresh_type or "flashui", region end)
end

-- Lets the settings submenu's checkboxes preview their effect on the
-- floating button immediately, without having to close the menu first.
-- Called with whether the button was visible *before* the toggle being
-- applied, since a callback may itself have just hidden it (or may be
-- about to make it visible again).
-- Refreshes a fixed, generous corner strip - matching the touch zones'
-- hit area - rather than the button's own (possibly now-stale) box_dimen,
-- since toggling a display setting can grow or shrink the button.
-- `refresh_type` defaults to a flashing refresh (to clear any e-ink ghost);
-- pass "ui" for a cheap non-flashing repaint, e.g. while a value is still
-- being dragged in a SpinWidget.
local function refreshFloatingButtonPreview(ui, was_visible, refresh_type)
    local overlay = ui._rlt_overlay
    if not was_visible and not (overlay and overlay.visible) then
        return
    end
    local region = Geom:new{
        x = 0, y = math.floor(Screen:getHeight() * 0.75),
        w = Screen:getWidth(), h = math.ceil(Screen:getHeight() * 0.25),
    }
    refreshRegion(ui, region, refresh_type)
end

-- Opens a SpinWidget to edit one of the button's offset settings, previewing
-- the change against the actual floating button as the value is dragged
-- (not just once "Apply" is tapped), and reverting it if the widget is
-- dismissed any other way (Cancel, tapping outside, the Back key).
-- `opts` (optional) overrides the spinner's bounds/default - used for the
-- button radius setting below, which needs a non-zero "reset" value (its
-- default is intentionally oversized so it resolves to a full pill - see
-- BUTTON_RADIUS_DEFAULT). Omitted entirely, this keeps its original 0-200,
-- default-0 behavior for the two offset settings.
local function showOffsetSpinWidget(ui, touchmenu_instance, title, info, get_offset, set_offset, opts)
    opts = opts or {}
    local original_value = get_offset()
    local applied = false
    local spin_widget
    spin_widget = SpinWidget:new{
        title_text = title,
        info_text = info,
        value = original_value,
        value_min = opts.value_min or 0,
        value_max = opts.value_max or 200,
        value_step = opts.value_step or 1,
        value_hold_step = opts.value_hold_step or 10,
        unit = "px",
        default_value = opts.default_value or 0,
        callback = function(spin)
            applied = true
            set_offset(spin.value)
        end,
        close_callback = function()
            if not applied then
                set_offset(original_value)
            end
            refreshFloatingButtonPreview(ui, ui._rlt_overlay and ui._rlt_overlay.visible)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }
    -- SpinWidget only runs `callback` once "Apply" is tapped; wrapping its
    -- own `update` (called on every tick, including hold-repeat) is the only
    -- way to preview it live. This live-updates the setting itself, but
    -- close_callback reverts it above if the widget wasn't actually applied.
    local orig_spin_update = spin_widget.update
    spin_widget.update = function(self, numberpicker_value, ...)
        orig_spin_update(self, numberpicker_value, ...)
        set_offset(numberpicker_value or self.value)
        refreshFloatingButtonPreview(ui, ui._rlt_overlay and ui._rlt_overlay.visible, "ui")
    end
    UIManager:show(spin_widget)
end

function ReadingLocationTracker.initOverlay(ui)
    if ui._rlt_overlay then
        return
    end
    local overlay = ReadingLocationOverlay:new{
        ui = ui,
        view = ui.view,
        visible = false,
    }
    overlay:setupTouchZones()
    ui._rlt_overlay = overlay
end

function ReadingLocationTracker.onCancel(ui)
    local overlay = ui._rlt_overlay
    local region = growRegionForShadow(overlay and overlay.box_dimen)
    -- Stop tracking the old position: accept wherever we currently are.
    ui._rlt_anchor = ui._rlt_current_page or ui._rlt_anchor
    if overlay then
        overlay.visible = false
    end
    refreshRegion(ui, region)
end

function ReadingLocationTracker.onGoBack(ui)
    local overlay = ui._rlt_overlay
    local region = growRegionForShadow(overlay and overlay.box_dimen)
    local target_page = ui._rlt_anchor
    if overlay then
        overlay.visible = false
    end
    refreshRegion(ui, region)
    if target_page then
        ui:handleEvent(Event:new("GotoPage", target_page))
    end
end

-- Standalone system action: accepts the current page as the new reference
-- point on demand, regardless of whether the floating button is currently
-- showing (unlike onCancel, which only ever runs from an active overlay tap/
-- hold, where the button vanishing is already visible feedback). Shows a
-- notification here instead, since there's otherwise no visible confirmation.
function ReadingLocationTracker.setCurrentPageAsReadingLocation(ui)
    if not ui or type(ui._rlt_current_page) ~= "number" then
        return
    end
    local overlay = ui._rlt_overlay
    local region = overlay and overlay.visible and growRegionForShadow(overlay.box_dimen)
    ui._rlt_anchor = ui._rlt_current_page
    if overlay then
        overlay.visible = false
    end
    refreshRegion(ui, region)
    UIManager:show(Notification:new{
        text = _("Current page set as reading location."),
    })
end

-- Whether the current page already IS the tracked reading location - true
-- when there's nothing to jump back to (goToFurthestReadingLocation) and
-- nothing new to set (setCurrentPageAsReadingLocation). Shared by both menu
-- entries' enabled_func, so they gray out instead of just no-op'ing/notifying
-- when tapped.
function ReadingLocationTracker.isAtReadingLocation(ui)
    local anchor = ui and ui._rlt_anchor
    local current = ui and ui._rlt_current_page
    return not anchor or anchor == current
end

function ReadingLocationTracker.goToFurthestReadingLocation(ui)
    if ReadingLocationTracker.isAtReadingLocation(ui) then
        UIManager:show(Notification:new{
            text = _("You're already at your furthest reading location."),
        })
        return
    end
    ReadingLocationTracker.onGoBack(ui)
end

-- Computes whether the floating button should currently be visible (and on
-- which side), purely from the tracked anchor/current-page state - without
-- touching the anchor itself. Shared by onPageUpdate (after a real page
-- turn) and by the settings submenu (to restore normal state once you're
-- done previewing - see the "hold for settings" hold_callback below, which
-- forces the button visible so its appearance can be previewed even when
-- you're already at the furthest reading location).
function ReadingLocationTracker.refreshOverlayVisibility(ui)
    local overlay = ui._rlt_overlay
    if not overlay then
        return
    end
    local anchor = ui._rlt_anchor
    local current = ui._rlt_current_page
    local new_side = nil
    if anchor and current then
        if anchor - current > 1 then
            new_side = "bottom_right" -- drifted backward: offer to go forward again
        elseif current - anchor > 2 then
            new_side = "bottom_left" -- jumped forward: offer to go back
        end
    end
    if new_side and ReadingLocationTracker.isFloatingButtonEnabled() then
        overlay.visible = true
        overlay.side = new_side
        overlay.anchor = anchor
    else
        overlay.visible = false
    end
end

-- Shared handler called from both ReaderPaging:onPageUpdate and
-- ReaderRolling:onPageUpdate.
function ReadingLocationTracker.onPageUpdate(reader_module, new_page_no)
    local ui = reader_module.ui
    if not ui or type(new_page_no) ~= "number" then
        return
    end

    ReadingLocationTracker.initOverlay(ui)
    ui._rlt_current_page = new_page_no

    if ui._rlt_anchor == nil then
        -- First page update seen for this book: load the saved anchor (if
        -- any), falling back to the current page. This comparison is NOT
        -- skipped below - if a pending jump was saved from a previous
        -- session, the overlay can legitimately reappear right away.
        local saved = ui.doc_settings and ui.doc_settings:readSetting("readingloc_anchor")
        if type(saved) ~= "number" then
            saved = nil
        else
            local page_count = ReadingLocationTracker.getPageCount(ui)
            if page_count and (saved < 1 or saved > page_count) then
                saved = nil
            end
        end
        ui._rlt_anchor = saved or new_page_no
    end

    local anchor = ui._rlt_anchor
    if anchor - new_page_no <= 1 and new_page_no - anchor <= 2 then
        -- Only ever advance forward. This is what makes "back one page at a
        -- time" accumulate correctly: a single page back stays inside the
        -- tolerated range, so the anchor must stay put rather than trailing
        -- one page behind on every tap.
        ui._rlt_anchor = math.max(anchor, new_page_no)
    end

    ReadingLocationTracker.refreshOverlayVisibility(ui)
end

--[[ ---------------------------------------------------------------------
     Hooks
----------------------------------------------------------------------- ]]

-- Paint the overlay as part of the normal page compositing (same spot
-- ReaderView paints its dogear/footer/page-flip overlays), so it never
-- becomes a separate top-level window that could swallow input.
local orig_view_paintTo = ReaderView.paintTo
ReaderView.paintTo = function(self, bb, x, y)
    orig_view_paintTo(self, bb, x, y)
    local ui = self.ui
    if ui and ui._rlt_overlay then
        ui._rlt_overlay:paintTo(bb, x, y)
    end
end

local function hookPageUpdate(module_name)
    local ok, Module = pcall(require, module_name)
    if not ok or not Module then
        logger.warn("ReadingLocationTracker: could not load", module_name)
        return
    end

    local orig_onPageUpdate = Module.onPageUpdate
    Module.onPageUpdate = function(self, new_page_no, ...)
        orig_onPageUpdate(self, new_page_no, ...)
        local ok_update, err = pcall(ReadingLocationTracker.onPageUpdate, self, new_page_no)
        if not ok_update then
            logger.warn("ReadingLocationTracker: onPageUpdate error:", err)
        end
    end
end

hookPageUpdate("apps/reader/modules/readerpaging")
hookPageUpdate("apps/reader/modules/readerrolling")

local orig_saveSettings = ReaderUI.saveSettings
ReaderUI.saveSettings = function(self, ...)
    if self._rlt_anchor then
        local ok, err = pcall(function()
            self.doc_settings:saveSetting("readingloc_anchor", self._rlt_anchor)
        end)
        if not ok then
            logger.warn("ReadingLocationTracker: saveSettings error:", err)
        end
    end
    return orig_saveSettings(self, ...)
end

-- Menu: "Go to furthest reading location" (tap = jump, hold = settings submenu with
-- the button-visibility toggle and its display checkboxes), right below
-- ReaderLink's own "Go forward to next location".
local orig_link_addToMainMenu = ReaderLink.addToMainMenu
ReaderLink.addToMainMenu = function(self, menu_items)
    orig_link_addToMainMenu(self, menu_items)

    local ui = self.ui
    menu_items.go_to_furthest_reading_location = {
        text = _("Go to furthest reading location (hold for settings)"),
        callback = function()
            ReadingLocationTracker.goToFurthestReadingLocation(ui)
        end,
        -- Tapping this item must run the jump directly, so the settings
        -- can't be a normal `sub_item_table` (TouchMenu always opens that
        -- on tap instead of running `callback`). Holding manually replicates
        -- what TouchMenu:onMenuSelect does for a `sub_item_table` entry, so
        -- it opens exactly like a native submenu (back navigation included).
        hold_callback = function(touchmenu_instance, item)
            local overlay = ui._rlt_overlay
            -- Force the button to show while previewing these settings -
            -- even if you're already at the furthest reading location, where it
            -- wouldn't normally appear - so changes are visible right away
            -- without needing an actual pending "go back" prompt to look at.
            if overlay then
                overlay.anchor = ui._rlt_current_page or overlay.anchor
                overlay.side = overlay.side or "bottom_right"
                overlay.visible = ReadingLocationTracker.isFloatingButtonEnabled()
                -- Also show the mirrored docking, so both corners can be
                -- compared while adjusting these settings.
                overlay.preview_both_sides = true
                refreshFloatingButtonPreview(ui, true)
            end

            -- However you leave this settings screen - going back up, or
            -- closing the whole menu outright - stop forcing the preview
            -- and let the button go back to reflecting the real page state,
            -- as if these settings had never been touched.
            local orig_backToUpperMenu = touchmenu_instance.backToUpperMenu
            local orig_closeMenu = touchmenu_instance.closeMenu
            local function exitPreview()
                touchmenu_instance.backToUpperMenu = orig_backToUpperMenu
                touchmenu_instance.closeMenu = orig_closeMenu
                if overlay then
                    overlay.preview_both_sides = false
                end
                ReadingLocationTracker.refreshOverlayVisibility(ui)
                refreshFloatingButtonPreview(ui, true)
            end
            touchmenu_instance.backToUpperMenu = function(self, ...)
                exitPreview()
                return orig_backToUpperMenu(self, ...)
            end
            touchmenu_instance.closeMenu = function(self, ...)
                exitPreview()
                return orig_closeMenu(self, ...)
            end

            local sub_item_table = {
                {
                    text = _("Show button on screen"),
                    checked_func = function()
                        return ReadingLocationTracker.isFloatingButtonEnabled()
                    end,
                    callback = function()
                        local enabled = not ReadingLocationTracker.isFloatingButtonEnabled()
                        ReadingLocationTracker.setFloatingButtonEnabled(enabled)
                        -- Directly tied to this setting while previewing, so
                        -- it appears/disappears the moment you toggle it.
                        if ui._rlt_overlay then
                            ui._rlt_overlay.visible = enabled
                        end
                        refreshFloatingButtonPreview(ui, true)
                    end,
                },
                {
                    text_func = function()
                        return T(_("Mode: %1"), ReadingLocationTracker.isPercentageModeEnabled()
                            and _("Percentage") or _("Page number"))
                    end,
                    -- No checked_func on this item (it's a cycling text
                    -- toggle, not a checkbox), so TouchMenu:onMenuSelect
                    -- would otherwise close the menu on tap - and, since it
                    -- also skips the auto-updateItems() it does for checked/
                    -- checked_func items, the text_func label needs a manual
                    -- refresh here too, or it'd keep showing the old mode.
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        ReadingLocationTracker.setPercentageModeEnabled(not ReadingLocationTracker.isPercentageModeEnabled())
                        refreshFloatingButtonPreview(ui, ui._rlt_overlay and ui._rlt_overlay.visible)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text = _("Show full text"),
                    checked_func = function()
                        return ReadingLocationTracker.isFullTextEnabled()
                    end,
                    callback = function()
                        ReadingLocationTracker.setFullTextEnabled(not ReadingLocationTracker.isFullTextEnabled())
                        refreshFloatingButtonPreview(ui, ui._rlt_overlay and ui._rlt_overlay.visible)
                    end,
                },
                {
                    text = _("Show location/page number"),
                    -- "Go back to page"/"Go back to" doesn't make sense
                    -- without a value next to it, so this is forced on (and
                    -- locked) while "Show full text" is on - see
                    -- isPageNumberEnabled().
                    enabled_func = function()
                        return not ReadingLocationTracker.isFullTextEnabled()
                    end,
                    checked_func = function()
                        return ReadingLocationTracker.isPageNumberEnabled()
                    end,
                    callback = function()
                        ReadingLocationTracker.setPageNumberEnabled(not ReadingLocationTracker.isPageNumberEnabled())
                        refreshFloatingButtonPreview(ui, ui._rlt_overlay and ui._rlt_overlay.visible)
                    end,
                },
                {
                    text_func = function()
                        return _("Show dismiss button") .. (ReadingLocationTracker.isDismissButtonEnabled() and "" or " (hold to dismiss)")
                    end,
                    checked_func = function()
                        return ReadingLocationTracker.isDismissButtonEnabled()
                    end,
                    callback = function()
                        ReadingLocationTracker.setDismissButtonEnabled(not ReadingLocationTracker.isDismissButtonEnabled())
                        refreshFloatingButtonPreview(ui, ui._rlt_overlay and ui._rlt_overlay.visible)
                    end,
                },
                {
                    text = _("Show shadow"),
                    checked_func = function()
                        return ReadingLocationTracker.isShadowEnabled()
                    end,
                    callback = function()
                        ReadingLocationTracker.setShadowEnabled(not ReadingLocationTracker.isShadowEnabled())
                        refreshFloatingButtonPreview(ui, ui._rlt_overlay and ui._rlt_overlay.visible)
                    end,
                },
                {
                    text_func = function()
                        return T(_("Bottom offset: %1"), ReadingLocationTracker.getBottomOffset())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        showOffsetSpinWidget(ui, touchmenu_instance,
                            _("Bottom offset"),
                            _("Extra distance the button is docked away from the bottom edge of the screen. Applies to both corners."),
                            ReadingLocationTracker.getBottomOffset,
                            ReadingLocationTracker.setBottomOffset)
                    end,
                },
                {
                    text_func = function()
                        return T(_("Side offset: %1"), ReadingLocationTracker.getSideOffset())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        showOffsetSpinWidget(ui, touchmenu_instance,
                            _("Side offset"),
                            _("Extra distance the button is docked away from the left/right edge of the screen, whichever corner it's currently in. Applies to both corners."),
                            ReadingLocationTracker.getSideOffset,
                            ReadingLocationTracker.setSideOffset)
                    end,
                },
                {
                    text_func = function()
                        return T(_("Button radius: %1"), ReadingLocationTracker.getButtonRadius())
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        showOffsetSpinWidget(ui, touchmenu_instance,
                            _("Button radius"),
                            _("Corner roundness of the button, from 0 (square) up to fully rounded (pill/circle)."),
                            ReadingLocationTracker.getButtonRadius,
                            ReadingLocationTracker.setButtonRadius,
                            { value_max = BUTTON_RADIUS_DEFAULT, default_value = BUTTON_RADIUS_DEFAULT })
                    end,
                },
            }
            table.insert(touchmenu_instance.item_table_stack, touchmenu_instance.item_table)
            item.menu_item_id = item.menu_item_id or tostring(item)
            touchmenu_instance.parent_id = item.menu_item_id
            touchmenu_instance.item_table = sub_item_table
            touchmenu_instance:updateItems(1)
        end,
    }

    menu_items.set_current_page_as_reading_location = {
        text = _("Set current page as reading location"),
        enabled_func = function()
            return not ReadingLocationTracker.isAtReadingLocation(ui)
        end,
        callback = function()
            ReadingLocationTracker.setCurrentPageAsReadingLocation(ui)
        end,
    }
end

-- Place the new items right after "go_to_next_location" in the reader's
-- Navigation submenu, in order: "go to furthest reading location", then
-- "set current page as reading location".
local ok_order, reader_menu_order = pcall(require, "ui/elements/reader_menu_order")
if ok_order and reader_menu_order and reader_menu_order.navi then
    local navi = reader_menu_order.navi
    local insert_at = #navi + 1
    for i, key in ipairs(navi) do
        if key == "go_to_previous_location" then
            insert_at = i
            break
        end
    end

    table.insert(navi, insert_at, "go_to_furthest_reading_location")
    table.insert(navi, insert_at + 1, "set_current_page_as_reading_location")
end

-- Register as a dispatchable action so it can be bound to a gesture, a
-- profile, or a physical button via KOReader's gesture manager.
Dispatcher:registerAction("go_to_furthest_reading_location", {
    category = "none",
    event = "GoToFurthestReadingLocation",
    title = _("Go to furthest reading location"),
    reader = true,
})

ReaderUI.onGoToFurthestReadingLocation = function(self)
    ReadingLocationTracker.goToFurthestReadingLocation(self)
    return true
end

-- Register as a second, standalone dispatchable action - not tied to any
-- menu entry - so the current page can be accepted as the new reference
-- point directly from a gesture, profile, or physical button, without first
-- needing an active "go back" prompt to dismiss.
Dispatcher:registerAction("set_current_page_as_reading_location", {
    category = "none",
    event = "SetCurrentPageAsReadingLocation",
    title = _("Set current page as reading location"),
    reader = true,
})

ReaderUI.onSetCurrentPageAsReadingLocation = function(self)
    ReadingLocationTracker.setCurrentPageAsReadingLocation(self)
    return true
end

logger.dbg("ReadingLocationTracker Patch: Loaded")
