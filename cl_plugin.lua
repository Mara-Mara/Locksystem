local PLUGIN = PLUGIN

-- Client-side UI for placement and lock interaction.

-- Font Configuration System
local LOCK_FONT_PRIMARY = "ixSmallTitleFont"   -- Major buttons (Close, Back, Install Lock)
local LOCK_FONT_SECONDARY = "ixSmallFont"      -- Minor buttons (Change Code, View Users, etc.)
local LOCK_FONT_TERTIARY = "ixSmallFont"       -- Content text (labels, entries, info)

-- Color Scheme
local LOCK_COLOR_BG = Color(40, 40, 40, 255)   -- Charcoal base
local LOCK_COLOR_BG_DARK = Color(25, 25, 25, 255) -- Darker charcoal
local LOCK_COLOR_TEXT = Color(240, 240, 240, 255) -- Light text
local LOCK_COLOR_TEXT_DIM = Color(180, 180, 180, 255) -- Dimmed text
local LOCK_COLOR_BORDER = Color(60, 60, 60, 255) -- Border color

-- Helper function to get entity center in screen space
local function GetEntityScreenCenter(entity)
    if (not IsValid(entity)) then
        return ScrW() * 0.5, ScrH() * 0.5
    end
    
    local center = entity:LocalToWorld(entity:OBBCenter())
    local screenPos = center:ToScreen()
    
    return math.Clamp(screenPos.x, 0, ScrW()), math.Clamp(screenPos.y, 0, ScrH())
end

-- Helper function to get schema color
local function GetSchemaColor()
    if (ix and ix.config and ix.config.Get) then
        return ix.config.Get("color") or Color(100, 149, 237, 255)
    end
    return Color(100, 149, 237, 255) -- Default blue
end

-- Helper function to paint a tapered divider
local function PaintTaperedDivider(panel, w, h)
    local schemaColor = GetSchemaColor()
    -- Create tapered effect - thickest in center (3px), tapers to edges
    local centerX = w * 0.5
    local maxWidth = w * 0.8 -- Actually reach 80% width
    local halfWidth = maxWidth * 0.5
    local margin = (w - maxWidth) * 0.5 -- 10% margin on each side
    
    -- Draw using filled rectangles for smoother gradient effect
    for x = math.floor(margin), math.ceil(w - margin) do
        local distanceFromCenter = math.abs(x - centerX)
        local normalizedDist = math.min(1, distanceFromCenter / halfWidth)
        
        -- Preserve full width for a few pixels in the center before tapering
        local flatRegion = 0.15 -- 15% of half-width stays at full thickness (about 3-4 pixels)
        local easedDist = 0
        
        if (normalizedDist > flatRegion) then
            -- Map the remaining distance (flatRegion to 1) to (0 to 1) for easing
            local taperDist = (normalizedDist - flatRegion) / (1 - flatRegion)
            -- Simple ease-out for smooth, continuous taper
            easedDist = 1 - math.pow(1 - taperDist, 0.375) -- Very gentle taper
        end
        
        -- Calculate thickness - ensure center is 3px, taper smoothly
        local thickness = 3 * (1 - easedDist)
        
        -- Draw if thickness is meaningful (lower threshold for smoother appearance)
        if (thickness >= 0.15) then
            -- Smooth alpha fade (less aggressive)
            local alpha = 150 * (1 - easedDist * 0.6)
            local color = Color(schemaColor.r, schemaColor.g, schemaColor.b, math.max(30, math.min(255, alpha)))
            surface.SetDrawColor(color)
            
            -- Draw filled rectangle for this column
            local yPos = (h - thickness) * 0.5
            surface.DrawRect(x, yPos, 1, math.max(0.3, thickness))
        end
    end
end

-- Custom Lock Menu Panel - using EditablePanel base (like DFrame does)
DEFINE_BASECLASS("EditablePanel")
local PANEL = {}

AccessorFunc(PANEL, "headerText", "HeaderText", FORCE_STRING)
AccessorFunc(PANEL, "entity", "Entity")

function PANEL:Init()
    -- EditablePanel's Init doesn't do much, set up manually
    self:SetDrawOnTop(true)
    self:SetMouseInputEnabled(true)
    self:SetKeyboardInputEnabled(true)
    
    self.headerText = "Locksystem"
    self.entity = nil
    self.fraction = 0
    self.bClosing = false
    
    -- Content area (for main content) - use DPanel for proper child rendering
    self.contentArea = vgui.Create("DPanel", self)
    self.contentArea:Dock(FILL)
    self.contentArea:SetMouseInputEnabled(true)
    self.contentArea:SetKeyboardInputEnabled(false) -- Don't consume keyboard input - let children handle it
    self.contentArea:SetPaintBackground(false)
    -- Allow children to receive mouse input properly
    function self.contentArea:OnMousePressed(mousecode)
        -- Let the click pass through to children
        -- Don't return false - let default behavior handle it
    end
    -- Ensure contentArea doesn't block children from receiving focus
    function self.contentArea:OnKeyCodePressed(keycode)
        -- Let children handle keyboard input
        return false
    end
    -- Allow focus to pass through to children
    function self.contentArea:OnKeyCodeReleased(keycode)
        return false
    end
    
    -- Header area
    self.headerArea = vgui.Create("Panel", self)
    self.headerArea:Dock(TOP)
    self.headerArea:SetTall(40)
    
    self.headerLabel = vgui.Create("DLabel", self.headerArea)
    self.headerLabel:Dock(TOP)
    self.headerLabel:SetContentAlignment(5) -- Center alignment
    self.headerLabel:SetTextColor(LOCK_COLOR_TEXT)
    self.headerLabel:SetFont(LOCK_FONT_PRIMARY)
    self.headerLabel:DockMargin(12, 0, 12, 0)
    self.headerLabel:SetWrap(false)
    self.headerLabel:SetAutoStretchVertical(false)
    
    -- Divider under header - tapered effect
    self.headerDivider = vgui.Create("DPanel", self.headerArea)
    self.headerDivider:Dock(TOP)
    self.headerDivider:SetTall(3) -- Match accent bar thickness
    self.headerDivider:DockMargin(0, 4, 0, 0)
    self.headerDivider:SetPaintBackground(false)
    function self.headerDivider:Paint(w, h)
        PaintTaperedDivider(self, w, h)
    end
    
    -- Button area (bottom) - positioned above the bottom accent bar
    self.buttonArea = vgui.Create("DPanel", self)
    self.buttonArea:Dock(BOTTOM)
    self.buttonArea:SetTall(50)
    self.buttonArea:DockMargin(0, 0, 0, 3) -- 3px margin to account for bottom accent bar
    self.buttonArea:SetPaintBackground(false)
    self.buttonArea:SetMouseInputEnabled(true)
    
    -- Animation
    self:CreateAnimation(0.2, {
        index = 1,
        target = {fraction = 1},
        easing = "outQuint",
        Think = function(animation, panel)
            panel:SetAlpha(panel.fraction * 255)
        end
    })
    
    self:SetAlpha(0)
end

function PANEL:SetHeaderText(text)
    self.headerText = text
    if (IsValid(self.headerLabel)) then
        self.headerLabel:SetText(text)
        self.headerLabel:SizeToContents()
        -- Auto-adjust header height if text wraps
        if (self.headerLabel:GetTall() > 40) then
            self.headerArea:SetTall(self.headerLabel:GetTall() + 8)
        end
    end
end

function PANEL:SetEntity(entity)
    self.entity = entity
end

function PANEL:PositionFromEntity()
    local w, h = self:GetSize()
    
    -- Always center panel on screen
    local x = ScrW() * 0.5 - w * 0.5
    local y = ScrH() * 0.5 - h * 0.5
    
    -- Keep it on screen
    x = math.Clamp(x, 8, ScrW() - w - 8)
    y = math.Clamp(y, 8, ScrH() - h - 8)
    
    self:SetPos(x, y)
    
    -- Store entity center for drawing trailing line
    if (IsValid(self.entity)) then
        local centerX, centerY = GetEntityScreenCenter(self.entity)
        self.entityScreenX = centerX
        self.entityScreenY = centerY
    else
        self.entityScreenX = nil
        self.entityScreenY = nil
    end
end

-- Override DFrame's PaintBackground to prevent default drawing
function PANEL:PaintBackground(w, h)
    -- Don't draw default DFrame background - we'll draw custom in Paint
end

function PANEL:Paint(w, h)
    local schemaColor = GetSchemaColor()
    
    -- Draw trailing line to entity center (like Helix tooltips)
    if (self.entityScreenX and self.entityScreenY and self.fraction > 0) then
        local panelX, panelY = self:GetPos()
        -- Convert entity screen position to local panel coordinates
        local entityX = self.entityScreenX - panelX
        local entityY = self.entityScreenY - panelY
        
        -- Determine line origin point - choose the corner that creates the shortest line
        local originX, originY = 0, 0
        
        -- Calculate distance from each corner to entity
        local corners = {
            {x = 0, y = 0, name = "top-left"},      -- Top-left
            {x = w, y = 0, name = "top-right"},     -- Top-right
            {x = 0, y = h, name = "bottom-left"},   -- Bottom-left
            {x = w, y = h, name = "bottom-right"}   -- Bottom-right
        }
        
        local shortestDistance = math.huge
        local bestCorner = corners[1]
        
        for _, corner in ipairs(corners) do
            local dx = entityX - corner.x
            local dy = entityY - corner.y
            local distance = math.sqrt(dx * dx + dy * dy)
            
            if (distance < shortestDistance) then
                shortestDistance = distance
                bestCorner = corner
            end
        end
        
        originX = bestCorner.x
        originY = bestCorner.y
        
        -- Draw line from chosen origin to entity position
        DisableClipping(true)
        surface.SetDrawColor(schemaColor)
        surface.DrawLine(originX, originY, entityX * self.fraction, entityY * self.fraction)
        -- Draw dot at entity position
        surface.DrawRect((entityX - 2) * self.fraction, (entityY - 2) * self.fraction, 4, 4)
        DisableClipping(false)
    end
    
    -- Background with gradient
    local bgColor = LOCK_COLOR_BG
    draw.RoundedBox(0, 0, 0, w, h, bgColor)
    
    -- Gradient overlay with schema color (subtle top-to-bottom)
    for i = 0, h do
        local alpha = math.max(0, 30 - (i / h * 30))
        local gradientColor = Color(schemaColor.r, schemaColor.g, schemaColor.b, alpha)
        surface.SetDrawColor(gradientColor)
        surface.DrawLine(0, i, w, i)
    end
    
    -- Border (draw first so accent bars are on top)
    surface.SetDrawColor(LOCK_COLOR_BORDER)
    surface.DrawOutlinedRect(0, 0, w, h)
    
    -- Header accent bar (top) - draw on top of background
    local accentColor = Color(schemaColor.r, schemaColor.g, schemaColor.b, 150)
    surface.SetDrawColor(accentColor)
    surface.DrawRect(0, 0, w, 3)
    
    -- Bottom accent bar (to match top and provide connection point for trace line) - draw on top
    surface.SetDrawColor(accentColor)
    surface.DrawRect(0, h - 3, w, 3)
end

function PANEL:Think()
    if (self.bClosing) then return end
    
    -- Update entity screen position for trailing line
    if (IsValid(self.entity)) then
        local centerX, centerY = GetEntityScreenCenter(self.entity)
        self.entityScreenX = centerX
        self.entityScreenY = centerY
    end
end

function PANEL:MakePopup()
    -- Use base class MakePopup (EditablePanel's MakePopup, same as DFrame uses)
    BaseClass.MakePopup(self)
    gui.EnableScreenClicker(true)
end

-- Override keyboard input to allow children to receive focus
function PANEL:OnKeyCodePressed(keycode)
    -- Let children handle keyboard input first
    local children = self:GetChildren()
    for _, child in ipairs(children) do
        if IsValid(child) and child:IsKeyboardInputEnabled() then
            -- Check if child wants to handle this
            if child.OnKeyCodePressed then
                local result = child:OnKeyCodePressed(keycode)
                if result then return true end
            end
        end
    end
    return false
end

function PANEL:Close()
    if (self.bClosing) then return end
    
    self.bClosing = true
    self:CreateAnimation(0.15, {
        target = {fraction = 0},
        easing = "outQuint",
        Think = function(animation, panel)
            panel:SetAlpha(panel.fraction * 255)
        end,
        OnComplete = function(animation, panel)
            gui.EnableScreenClicker(false)
            panel:Remove()
        end
    })
end

vgui.Register("ixLockMenu", PANEL, "EditablePanel")

-- Custom Lock Button
DEFINE_BASECLASS("DButton")
local BUTTON = {}

function BUTTON:Init()
    self:SetTextColor(LOCK_COLOR_TEXT)
    self:SetFont(LOCK_FONT_SECONDARY)
    self.hoverFraction = 0
    self.fontType = "secondary"
    self.isAdminButton = false
    self.customTextRendered = false -- Flag to track if we've rendered custom text
    self:SetContentAlignment(5) -- Center alignment
    self:SetTextInset(8, 0) -- Inset to prevent edge clipping
    -- Prevent text truncation
    self:SetWrap(false)
    -- Override SetText to ensure proper sizing
    local oldSetText = self.SetText
    function self:SetText(text)
        oldSetText(self, text)
        self.customTextRendered = false -- Reset flag when text changes
        if (self:GetWide() > 0) then
            surface.SetFont(self:GetFont())
            local textW = surface.GetTextSize(text)
            if (textW > self:GetWide() - 16) then
                -- Text might be cut off, but we'll let it display
                -- The inset should help
            end
        end
    end
end

function BUTTON:SetFontType(fontType)
    self.fontType = fontType
    if (fontType == "primary") then
        self:SetFont(LOCK_FONT_PRIMARY)
    elseif (fontType == "secondary") then
        self:SetFont(LOCK_FONT_SECONDARY)
    elseif (fontType == "admin") then
        self:SetFont(LOCK_FONT_SECONDARY) -- Use secondary font but with admin styling
        self.isAdminButton = true
        -- Hide default text rendering for admin buttons by pushing it off-screen
        self:SetTextInset(-9999, 0)
    else
        self:SetFont(LOCK_FONT_TERTIARY)
    end
end

function BUTTON:OnCursorEntered()
    self:CreateAnimation(0.1, {
        target = {hoverFraction = 1},
        easing = "outQuint"
    })
end

function BUTTON:OnCursorExited()
    self:CreateAnimation(0.1, {
        target = {hoverFraction = 0},
        easing = "outQuint"
    })
end

function BUTTON:Paint(w, h)
    local schemaColor = GetSchemaColor()
    local isHovered = self:IsHovered() and self:IsEnabled()
    
    -- Base color - same for all buttons (including admin)
    local bgColor = LOCK_COLOR_BG_DARK
    if (isHovered) then
        -- Brighten on hover
        bgColor = Color(
            math.min(bgColor.r + 20, 255),
            math.min(bgColor.g + 20, 255),
            math.min(bgColor.b + 20, 255),
            bgColor.a
        )
    end
    
    -- Background
    draw.RoundedBox(0, 0, 0, w, h, bgColor)
    
    -- Admin button accent bar at top
    if (self.isAdminButton) then
        local accentColor = Color(schemaColor.r, schemaColor.g, schemaColor.b, 180)
        surface.SetDrawColor(accentColor)
        surface.DrawRect(0, 0, w, 2)
    end
    
    -- Hover gradient with schema color (animated)
    if (isHovered and self.hoverFraction > 0) then
        local hoverAlpha = 40 * self.hoverFraction
        for i = 0, h do
            local alpha = math.max(0, hoverAlpha - (i / h * hoverAlpha * 0.5))
            local hoverColor = Color(schemaColor.r, schemaColor.g, schemaColor.b, alpha)
            surface.SetDrawColor(hoverColor)
            surface.DrawLine(0, i, w, i)
        end
    end
    
    -- Border - admin buttons have schema-colored border
    local borderColor = LOCK_COLOR_BORDER
    if (self.isAdminButton) then
        borderColor = Color(schemaColor.r, schemaColor.g, schemaColor.b, 100)
    end
    if (isHovered) then
        borderColor = Color(schemaColor.r, schemaColor.g, schemaColor.b, 120)
    end
    surface.SetDrawColor(borderColor)
    surface.DrawOutlinedRect(0, 0, w, h)
    
    -- Text rendering with custom coloring for admin buttons
    if (self.isAdminButton and self:IsEnabled()) then
        local text = self:GetText() or ""
        local prefix = "Admin:"
        
        if (string.sub(text, 1, string.len(prefix)) == prefix) then
            -- Mark that we've rendered custom text
            self.customTextRendered = true
            
            -- Split the text and draw with different colors
            local restOfText = string.sub(text, string.len(prefix) + 1)
            local font = self:GetFont()
            surface.SetFont(font)
            
            local prefixW, prefixH = surface.GetTextSize(prefix)
            local restW, restH = surface.GetTextSize(restOfText)
            
            -- Calculate centered position
            local totalW = prefixW + restW
            local startX = (w - totalW) * 0.5
            
            -- Draw "Admin:" in schema color
            draw.SimpleText(prefix, font, startX, h * 0.5, schemaColor, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            
            -- Draw rest of text in regular text color
            draw.SimpleText(restOfText, font, startX + prefixW, h * 0.5, LOCK_COLOR_TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            
            -- Prevent default text rendering by setting text color to transparent
            self:SetTextColor(Color(0, 0, 0, 0))
        else
            -- Not an admin button with prefix, use default text color
            self.customTextRendered = false
            self:SetTextColor(LOCK_COLOR_TEXT)
        end
    else
        -- Default text color adjustment
        self.customTextRendered = false
        if (not self:IsEnabled()) then
            self:SetTextColor(LOCK_COLOR_TEXT_DIM)
        else
            self:SetTextColor(LOCK_COLOR_TEXT)
        end
    end
end

function BUTTON:PaintOver(w, h)
    -- For admin buttons with custom text, we've already rendered the text in Paint
    -- So we don't need to do anything here - this prevents any default text rendering
end

vgui.Register("ixLockButton", BUTTON, "DButton")

-- Helper function to create lock buttons
local function CreateLockButton(parent, text, callback, fontType, style)
    fontType = fontType or "secondary"
    style = style or {}
    
    local button = vgui.Create("ixLockButton", parent)
    button:SetText(text)
    button:SetFontType(fontType)
    
    if (callback) then
        function button:DoClick()
            callback(self)
        end
    end
    
    -- Apply style
    if (style.width) then
        button:SetWide(style.width)
    end
    if (style.height) then
        button:SetTall(style.height)
    end
    if (style.margin) then
        button:DockMargin(style.margin[1], style.margin[2], style.margin[3], style.margin[4])
    end
    
    return button
end

-- Custom DTextEntry panel that properly extends DTextEntry
DEFINE_BASECLASS("DTextEntry")
local TEXTENTRY = {}

function TEXTENTRY:Init()
    BaseClass.Init(self)
    
    self:SetFont(LOCK_FONT_TERTIARY)
    self:SetTextColor(LOCK_COLOR_TEXT)
    self:SetHighlightColor(GetSchemaColor())
    self:SetDrawBackground(false)
    self:SetDrawBorder(false)
    self:SetPaintBackground(true) -- Enable PaintBackground
end

function TEXTENTRY:PaintBackground(w, h)
    -- Draw custom background (same charcoal grey as dropdown)
    draw.RoundedBox(0, 0, 0, w, h, LOCK_COLOR_BG_DARK)
end

function TEXTENTRY:Paint(w, h)
    -- Draw our custom background
    draw.RoundedBox(0, 0, 0, w, h, LOCK_COLOR_BG_DARK)
    
    -- Now call base class Paint which will draw text, but it might also draw background
    -- To prevent that, we need to temporarily disable background drawing
    local oldDrawBg = self.m_bBackground
    self.m_bBackground = false
    BaseClass.Paint(self, w, h)
    self.m_bBackground = oldDrawBg
end

function TEXTENTRY:PaintOver(w, h)
    -- Draw border on top
    local borderColor = LOCK_COLOR_BORDER
    if (self:HasFocus()) then
        local schemaColor = GetSchemaColor()
        borderColor = Color(schemaColor.r, schemaColor.g, schemaColor.b, 150)
    end
    surface.SetDrawColor(borderColor)
    surface.DrawOutlinedRect(0, 0, w, h)
end

function TEXTENTRY:PaintOver(w, h)
    -- DTextEntry doesn't have PaintOver by default, so we don't call BaseClass
    -- Just draw our custom border on top
    local borderColor = LOCK_COLOR_BORDER
    if (self:HasFocus()) then
        local schemaColor = GetSchemaColor()
        borderColor = Color(schemaColor.r, schemaColor.g, schemaColor.b, 150)
    end
    surface.SetDrawColor(borderColor)
    surface.DrawOutlinedRect(0, 0, w, h)
end

vgui.Register("ixLockTextEntry", TEXTENTRY, "DTextEntry")

-- Helper function to style text entries (for backwards compatibility)
-- Now just creates our custom panel type
local function StyleTextEntry(entry)
    -- If it's already our custom type, just update colors
    if (entry.ClassName == "ixLockTextEntry") then
        entry:SetTextColor(LOCK_COLOR_TEXT)
        entry:SetHighlightColor(GetSchemaColor())
        return
    end
    
    -- For regular DTextEntry, apply basic styling without overriding Paint
    entry:SetFont(LOCK_FONT_TERTIARY)
    entry:SetTextColor(LOCK_COLOR_TEXT)
    entry:SetHighlightColor(GetSchemaColor())
    entry:SetEditable(true)
    entry:SetEnabled(true)
    entry:SetMouseInputEnabled(true)
    entry:SetKeyboardInputEnabled(true)
end

-- Helper function to style combo boxes
local function StyleComboBox(combo)
    combo:SetFont(LOCK_FONT_TERTIARY)
    combo:SetTextColor(LOCK_COLOR_TEXT)
    combo:SetDrawBackground(false) -- We'll paint it ourselves
    combo:SetPaintBackground(true)
    
    -- Style the text entry part
    if (IsValid(combo.TextEntry)) then
        combo.TextEntry:SetFont(LOCK_FONT_TERTIARY)
        combo.TextEntry:SetTextColor(LOCK_COLOR_TEXT)
        combo.TextEntry:SetDrawBackground(false)
        combo.TextEntry:SetDrawBorder(false)
        
        function combo.TextEntry:Paint(w, h)
            -- Transparent background (parent will paint)
        end
    end
    
    -- Custom paint for better visibility
    function combo:Paint(w, h)
        -- Background
        draw.RoundedBox(0, 0, 0, w, h, LOCK_COLOR_BG_DARK)
        
        -- Border
        surface.SetDrawColor(LOCK_COLOR_BORDER)
        surface.DrawOutlinedRect(0, 0, w, h)
        
        -- Arrow indicator on right side
        local schemaColor = GetSchemaColor()
        surface.SetDrawColor(schemaColor)
        local arrowSize = 4
        local arrowX = w - 12
        local arrowY = h * 0.5
        -- Draw downward arrow
        surface.DrawLine(arrowX - arrowSize, arrowY - arrowSize, arrowX, arrowY)
        surface.DrawLine(arrowX + arrowSize, arrowY - arrowSize, arrowX, arrowY)
    end
    
    -- Style the dropdown menu
    function combo:OpenMenu(pControlOpener)
        if (pControlOpener and pControlOpener == self.TextEntry) then
            return
        end
        
        -- Get the menu
        local menu = DComboBox.OpenMenu(self, pControlOpener)
        if (IsValid(menu)) then
            -- Style the menu background
            menu:SetDrawBackground(true)
            function menu:Paint(w, h)
                draw.RoundedBox(0, 0, 0, w, h, LOCK_COLOR_BG)
                surface.SetDrawColor(LOCK_COLOR_BORDER)
                surface.DrawOutlinedRect(0, 0, w, h)
            end
            
            -- Style menu items
            for _, child in ipairs(menu:GetChildren()) do
                if (IsValid(child) and child:GetClassName() == "DMenuOption") then
                    child:SetTextColor(LOCK_COLOR_TEXT)
                    child:SetFont(LOCK_FONT_TERTIARY)
                    
                    function child:Paint(w, h)
                        if (self:IsHovered()) then
                            local schemaColor = GetSchemaColor()
                            local hoverColor = Color(schemaColor.r, schemaColor.g, schemaColor.b, 50)
                            draw.RoundedBox(0, 0, 0, w, h, hoverColor)
                        end
                    end
                end
            end
        end
        return menu
    end
end

local function OpenPlacementMenu(door, lockType, itemID, traceHitPos, traceHitNormal, doorIDs)
    if (not IsValid(door)) then return end

    doorIDs = doorIDs or {} -- Multi-door support
    
    local frame = vgui.Create("ixLockMenu")
    local title = "Install " .. ((lockType == "deadlock") and "Deadlock" or "Digilock")
    if (#doorIDs > 1) then
        title = title .. " (" .. #doorIDs .. " doors)"
    end
    frame:SetEntity(door)
    frame:SetHeaderText(title)
    frame:SetSize(300, 440 + (#doorIDs > 1 and 20 or 0))
    frame:PositionFromEntity()
    frame:MakePopup()
    
    -- Store trace data and doorIDs for sending back to server
    frame.traceHitPos = traceHitPos
    frame.traceHitNormal = traceHitNormal
    frame.doorIDs = doorIDs

    local modeLabel = vgui.Create("DLabel", frame.contentArea)
    modeLabel:SetText("Mode:")
    modeLabel:Dock(TOP)
    modeLabel:DockMargin(12, 4, 12, 2) -- Reduced top margin (less space above Mode)
    modeLabel:SetTextColor(LOCK_COLOR_TEXT)
    modeLabel:SetFont(LOCK_FONT_TERTIARY)
    modeLabel:SizeToContents()

    local modeCombo = vgui.Create("DComboBox", frame.contentArea)
    modeCombo:Dock(TOP)
    modeCombo:DockMargin(12, 0, 12, 4) -- Reduced bottom margin
    modeCombo:SetValue("Code")
    modeCombo:AddChoice("Code")
    modeCombo:AddChoice("Keycard")
    modeCombo:AddChoice("Biometric")
    modeCombo:SetTall(25)
    StyleComboBox(modeCombo)
    
    -- Divider after mode section - tapered effect
    local divider1 = vgui.Create("DPanel", frame.contentArea)
    divider1:Dock(TOP)
    divider1:SetTall(3) -- Match accent bar thickness
    divider1:DockMargin(0, 4, 0, 4) -- Equal spacing above and below (4px each = 8px total gap)
    divider1:SetPaintBackground(false)
    function divider1:Paint(w, h)
        PaintTaperedDivider(divider1, w, h)
    end

    local userCodeEntry = vgui.Create("ixLockTextEntry", frame.contentArea)
    userCodeEntry:Dock(TOP)
    userCodeEntry:DockMargin(12, 4, 12, 4) -- Top margin matches divider bottom margin
    userCodeEntry:SetPlaceholderText("User Code (required)")
    userCodeEntry:SetTall(25)
    userCodeEntry:SetVisible(true)
    userCodeEntry:SetEnabled(true)
    userCodeEntry:SetMouseInputEnabled(true)
    userCodeEntry:SetKeyboardInputEnabled(true)

    local masterCodeEntry = vgui.Create("ixLockTextEntry", frame.contentArea)
    masterCodeEntry:Dock(TOP)
    masterCodeEntry:DockMargin(12, 4, 12, 4)
    masterCodeEntry:SetPlaceholderText("Manager Code (optional)")
    masterCodeEntry:SetTall(25)
    masterCodeEntry:SetVisible(true)
    masterCodeEntry:SetEnabled(true)
    masterCodeEntry:SetMouseInputEnabled(true)
    masterCodeEntry:SetKeyboardInputEnabled(true)

    -- Override code entry for keycard mode
    local overrideCodeEntry = vgui.Create("ixLockTextEntry", frame.contentArea)
    overrideCodeEntry:Dock(TOP)
    overrideCodeEntry:DockMargin(12, 4, 12, 4)
    overrideCodeEntry:SetPlaceholderText("Override Code (optional)")
    overrideCodeEntry:SetTall(25)
    overrideCodeEntry:SetVisible(false)
    overrideCodeEntry:SetEnabled(true)
    overrideCodeEntry:SetMouseInputEnabled(true)
    overrideCodeEntry:SetKeyboardInputEnabled(true)

    -- Update code entry visibility based on mode selection
    function modeCombo:OnSelect(index, value, data)
        local isCode = string.lower(value) == "code"
        local isKeycard = string.lower(value) == "keycard"
        userCodeEntry:SetVisible(isCode)
        masterCodeEntry:SetVisible(isCode)
        overrideCodeEntry:SetVisible(isKeycard)
        if (not isCode) then
            userCodeEntry:SetText("")
            masterCodeEntry:SetText("")
        end
        if (not isKeycard) then
            overrideCodeEntry:SetText("")
        end
    end

    local confirm = CreateLockButton(frame.buttonArea, "Install Lock", function()
        local modeText = modeCombo:GetSelected() or modeCombo:GetValue() or "Code"
        local userCode = userCodeEntry:GetText() or ""
        local masterCode = masterCodeEntry:GetText() or ""
        local overrideCode = overrideCodeEntry:GetText() or ""

        net.Start("ixDoorLocks_ConfirmPlacement")
            net.WriteEntity(door)
            net.WriteString(string.lower(lockType or ""))
            net.WriteString(string.lower(modeText))
            net.WriteUInt(itemID or 0, 32)
            net.WriteString(userCode)
            net.WriteString(masterCode)
            net.WriteString(overrideCode)
            -- Send trace data for deadlocks
            if (lockType == "deadlock" and frame.traceHitPos and frame.traceHitNormal) then
                net.WriteBool(true)
                net.WriteVector(frame.traceHitPos)
                net.WriteVector(frame.traceHitNormal)
            else
                net.WriteBool(false)
            end
            -- Send multi-door selection
            net.WriteBool(#frame.doorIDs > 0)
            if (#frame.doorIDs > 0) then
                net.WriteUInt(#frame.doorIDs, 8)
                for _, doorID in ipairs(frame.doorIDs) do
                    net.WriteUInt(doorID, 32)
                end
            end
        net.SendToServer()
        frame:Close()
    end, "primary")
    confirm:Dock(FILL)
    confirm:DockMargin(0, 0, 0, 0)
end

net.Receive("ixDoorLocks_OpenPlacement", function()
    local door = net.ReadEntity()
    local lockType = net.ReadString()
    local itemID = net.ReadUInt(32)
    local hasTraceData = net.ReadBool()
    local traceHitPos = hasTraceData and net.ReadVector() or nil
    local traceHitNormal = hasTraceData and net.ReadVector() or nil
    
    -- Read multi-door selection (if present)
    local doorCount = net.ReadUInt(8)
    local doorIDs = {}
    if (doorCount > 0) then
        for i = 1, doorCount do
            table.insert(doorIDs, net.ReadUInt(32))
        end
    end

    OpenPlacementMenu(door, lockType, itemID, traceHitPos, traceHitNormal, doorIDs)
end)

-- Main action menu -----------------------------------------------------------

-- Track open menus to prevent duplicates
local activeLockMenu = nil
local shouldOpenOverrideManagement = false
local shouldOpenLockSettings = false
local activeBiometricMenu = nil
local activeKeycardMenu = nil
local activeKeycardPrintMenu = nil
local activeStoryCardMenu = nil

-- Helper function to close all open menus
local function CloseAllMenus()
    local anyMenuOpen = false
    
    if (IsValid(activeLockMenu)) then
        activeLockMenu:Close()
        activeLockMenu = nil
        anyMenuOpen = true
    end
    if (IsValid(activeBiometricMenu)) then
        activeBiometricMenu:Close()
        activeBiometricMenu = nil
        anyMenuOpen = true
    end
    if (IsValid(activeKeycardMenu)) then
        activeKeycardMenu:Close()
        activeKeycardMenu = nil
        anyMenuOpen = true
    end
    if (IsValid(activeKeycardPrintMenu)) then
        activeKeycardPrintMenu:Close()
        activeKeycardPrintMenu = nil
        anyMenuOpen = true
    end
    if (IsValid(activeStoryCardMenu)) then
        activeStoryCardMenu:Close()
        activeStoryCardMenu = nil
        anyMenuOpen = true
    end
    
    return anyMenuOpen
end

local function OpenLockMenu(door, lockID, isDeadlock, lockType, mode, isLocked, isManager, isBio, isBioManager, hasManager, hasMaster, hasKeycard, isKeycardMaster, isKeycardManager, isAdmin, isAdminDeactivated, hasOverrideCode, overrideModeEnabled, hasPersonalOverrideCode, hasGroupOverrideCode)
    if (not IsValid(door)) then return end

    -- Close existing menu if open
    if (IsValid(activeLockMenu)) then
        activeLockMenu:Close()
        activeLockMenu = nil
    end

    -- Admins always see the config menu
    -- Regular users only see it if they have config options available
    if (not isAdmin) then
        -- Check if there are any config options available for non-admins
        local hasConfigOptions = false
        if (mode == "code" and hasManager) then
            hasConfigOptions = true
        elseif (mode == "biometric" and (isBioManager or hasMaster)) then
            hasConfigOptions = true
        elseif (mode == "keycard" and (isKeycardManager or hasKeycard)) then
            hasConfigOptions = true
        elseif (hasMaster) then
            hasConfigOptions = true
        end

        -- If no config options, show message and return (only for non-admins)
        --[[
        if (not hasConfigOptions) then
            LocalPlayer():Notify("No config menu to display!")
            return
        end
        --]]
    end

    -- If admin is deactivated (only for biometric locks), only show "Admin: Reactivate Own User" button
    -- Check this FIRST before calculating button count and creating frame
    if (isAdminDeactivated and mode == "biometric") then
        local frame = vgui.Create("ixLockMenu")
        frame:SetEntity(door)
        frame:SetHeaderText("Locksystem")
        frame:SetSize(320, 200) -- Fixed size for deactivated admin menu
        frame:PositionFromEntity()
        frame:MakePopup()

        activeLockMenu = frame
        function frame:OnClose()
            if (activeLockMenu == self) then
                activeLockMenu = nil
            end
        end

        -- Capitalize first letter of type and mode
        local capitalizedType = string.upper(string.sub(lockType, 1, 1)) .. string.sub(lockType, 2)
        local capitalizedMode = string.upper(string.sub(mode, 1, 1)) .. string.sub(mode, 2)
        
        -- Sleek Type/Mode bar with 2x2 grid layout
        local typeModeBar = vgui.Create("DPanel", frame.contentArea)
        typeModeBar:Dock(TOP)
        typeModeBar:DockMargin(12, 12, 12, 8)
        typeModeBar:SetTall(48) -- Twice as tall for 2x2 grid
        typeModeBar.Paint = function(self, w, h)
            local schemaColor = GetSchemaColor()
            
            -- Draw background bar
            draw.RoundedBox(0, 0, 0, w, h, LOCK_COLOR_BG_DARK)
            
            -- Draw schema color border around the whole grid
            surface.SetDrawColor(schemaColor)
            surface.DrawOutlinedRect(0, 0, w, h)
            
            -- Draw vertical separator in the middle
            local separatorX = w * 0.5
            surface.SetDrawColor(LOCK_COLOR_BORDER)
            surface.DrawLine(separatorX, 0, separatorX, h)
            
            -- Draw horizontal separator in the middle
            local separatorY = h * 0.5
            surface.SetDrawColor(LOCK_COLOR_BORDER)
            surface.DrawLine(0, separatorY, w, separatorY)
        end
        
        -- Type label (top left) - centered in its quadrant
        local typeHeaderLabel = vgui.Create("DLabel", typeModeBar)
        typeHeaderLabel:SetText("Type:")
        typeHeaderLabel:SetTextColor(LOCK_COLOR_TEXT_DIM)
        typeHeaderLabel:SetFont(LOCK_FONT_TERTIARY)
        typeHeaderLabel:SetContentAlignment(5) -- Center alignment
        function typeHeaderLabel:PerformLayout()
            local parentW = self:GetParent():GetWide()
            local parentH = self:GetParent():GetTall()
            local boxW = parentW * 0.5
            local boxH = parentH * 0.5
            self:SetSize(boxW, boxH)
            self:SetPos(0, 0)
        end
        
        -- Type value (bottom left) - centered in its quadrant
        local typeValueLabel = vgui.Create("DLabel", typeModeBar)
        typeValueLabel:SetText(capitalizedType)
        typeValueLabel:SetTextColor(LOCK_COLOR_TEXT)
        typeValueLabel:SetFont(LOCK_FONT_TERTIARY)
        typeValueLabel:SetContentAlignment(5) -- Center alignment
        function typeValueLabel:PerformLayout()
            local parentW = self:GetParent():GetWide()
            local parentH = self:GetParent():GetTall()
            local boxW = parentW * 0.5
            local boxH = parentH * 0.5
            self:SetSize(boxW, boxH)
            self:SetPos(0, parentH * 0.5)
        end
        
        -- Mode label (top right) - centered in its quadrant
        local modeHeaderLabel = vgui.Create("DLabel", typeModeBar)
        modeHeaderLabel:SetText("Mode:")
        modeHeaderLabel:SetTextColor(LOCK_COLOR_TEXT_DIM)
        modeHeaderLabel:SetFont(LOCK_FONT_TERTIARY)
        modeHeaderLabel:SetContentAlignment(5) -- Center alignment
        function modeHeaderLabel:PerformLayout()
            local parentW = self:GetParent():GetWide()
            local parentH = self:GetParent():GetTall()
            local boxW = parentW * 0.5
            local boxH = parentH * 0.5
            self:SetSize(boxW, boxH)
            self:SetPos(parentW * 0.5, 0)
        end
        
        -- Mode value (bottom right) - centered in its quadrant
        local modeValueLabel = vgui.Create("DLabel", typeModeBar)
        modeValueLabel:SetText(capitalizedMode)
        modeValueLabel:SetTextColor(LOCK_COLOR_TEXT)
        modeValueLabel:SetFont(LOCK_FONT_TERTIARY)
        modeValueLabel:SetContentAlignment(5) -- Center alignment
        function modeValueLabel:PerformLayout()
            local parentW = self:GetParent():GetWide()
            local parentH = self:GetParent():GetTall()
            local boxW = parentW * 0.5
            local boxH = parentH * 0.5
            self:SetSize(boxW, boxH)
            self:SetPos(parentW * 0.5, parentH * 0.5)
        end

        -- Admin: Reactivate Own User
        local adminReactivate = CreateLockButton(frame.contentArea, "Admin: Reactivate Own User", function()
            net.Start("ixDoorLocks_DoAction")
                net.WriteString("admin_reactivate_own_user")
                net.WriteString(lockID)
            net.SendToServer()
            frame:Close()
        end, "admin")
        adminReactivate:Dock(TOP)
        adminReactivate:DockMargin(12, 8, 12, 8)

        -- Full-width close button
        local closeBtn = CreateLockButton(frame.buttonArea, "Close", function()
            frame:Close()
        end, "primary")
        closeBtn:Dock(FILL)
        closeBtn:DockMargin(12, 8, 12, 8)

        return -- Don't create any other buttons
    end

    local frame = vgui.Create("ixLockMenu")
    frame:SetEntity(door)
    frame:SetHeaderText("Locksystem")
    
    -- Calculate approximate height needed based on buttons
    local buttonCount = 0
    if (showToggle) then
        buttonCount = buttonCount + 1 -- toggle
    end
    
    -- Code mode specific buttons (only visible to manager code users)
    if (mode == "code" and hasManager) then
        buttonCount = buttonCount + 3 -- Change User Code, Change Manager Code, Clear User List
    end
    
    -- Biometric mode buttons
    if (mode == "biometric") then
        if (isBioManager or hasMaster) then
            buttonCount = buttonCount + 4 -- Start Regular Pairing, Start Manager Pairing, View User List, Clear User List
        end
    end
    
    -- Keycard mode buttons
    if (mode == "keycard") then
        if (isKeycardManager) then
            buttonCount = buttonCount + 2 -- Print Keycard, View Keycards
        end
        if (isKeycardMaster) then
            buttonCount = buttonCount + 1 -- Override Management
        end
    end
    
    -- Group Management button (masters only)
    local canManageGroup = false
    if (mode == "keycard") then
        canManageGroup = isKeycardMaster
    else
        canManageGroup = hasMaster
    end
    if (canManageGroup) then
        buttonCount = buttonCount + 1
    end
    
    -- Remove Lock button
    local canRemoveLock = false
    if (mode == "keycard") then
        canRemoveLock = isKeycardMaster
    else
        canRemoveLock = hasMaster
    end
    if (canRemoveLock) then
        buttonCount = buttonCount + 1
    end
    
    -- Admin buttons
    if (isAdmin) then
        if (mode == "code" or mode == "biometric") then
            buttonCount = buttonCount + 2 -- Admin: Master on Self, Admin: Remove Lock
        elseif (mode == "keycard") then
            buttonCount = buttonCount + 3 -- Admin: Print Story Card, Admin: Print Master Card, Admin: Remove Lock
        end
    end
    
    local height = 100 + (buttonCount * 38) + 60 -- header (100px) + buttons (38px each for better spacing) + button area (60px)
    frame:SetSize(320, math.max(height, 250))
    frame:PositionFromEntity()
    frame:MakePopup()

    -- Store reference and clean up on close
    activeLockMenu = frame
    function frame:OnClose()
        if (activeLockMenu == self) then
            activeLockMenu = nil
        end
    end

    -- Capitalize first letter of type and mode
    local capitalizedType = string.upper(string.sub(lockType, 1, 1)) .. string.sub(lockType, 2)
    local capitalizedMode = string.upper(string.sub(mode, 1, 1)) .. string.sub(mode, 2)
    
    -- Sleek Type/Mode bar with 2x2 grid layout
    local typeModeBar = vgui.Create("DPanel", frame.contentArea)
    typeModeBar:Dock(TOP)
    typeModeBar:DockMargin(12, 12, 12, 8)
    typeModeBar:SetTall(48) -- Twice as tall for 2x2 grid
    typeModeBar.Paint = function(self, w, h)
        local schemaColor = GetSchemaColor()
        
        -- Draw background bar
        draw.RoundedBox(0, 0, 0, w, h, LOCK_COLOR_BG_DARK)
        
        -- Draw schema color border around the whole grid
        surface.SetDrawColor(schemaColor)
        surface.DrawOutlinedRect(0, 0, w, h)
        
        -- Draw vertical separator in the middle
        local separatorX = w * 0.5
        surface.SetDrawColor(LOCK_COLOR_BORDER)
        surface.DrawLine(separatorX, 0, separatorX, h)
        
        -- Draw horizontal separator in the middle
        local separatorY = h * 0.5
        surface.SetDrawColor(LOCK_COLOR_BORDER)
        surface.DrawLine(0, separatorY, w, separatorY)
    end
    
    -- Type label (top left) - centered in its quadrant
    local typeHeaderLabel = vgui.Create("DLabel", typeModeBar)
    typeHeaderLabel:SetText("Type:")
    typeHeaderLabel:SetTextColor(LOCK_COLOR_TEXT_DIM)
    typeHeaderLabel:SetFont(LOCK_FONT_TERTIARY)
    typeHeaderLabel:SetContentAlignment(5) -- Center alignment
    function typeHeaderLabel:PerformLayout()
        local parentW = self:GetParent():GetWide()
        local parentH = self:GetParent():GetTall()
        local boxW = parentW * 0.5
        local boxH = parentH * 0.5
        self:SetSize(boxW, boxH)
        self:SetPos(0, 0)
    end
    
    -- Type value (bottom left) - centered in its quadrant
    local typeValueLabel = vgui.Create("DLabel", typeModeBar)
    typeValueLabel:SetText(capitalizedType)
    typeValueLabel:SetTextColor(LOCK_COLOR_TEXT)
    typeValueLabel:SetFont(LOCK_FONT_TERTIARY)
    typeValueLabel:SetContentAlignment(5) -- Center alignment
    function typeValueLabel:PerformLayout()
        local parentW = self:GetParent():GetWide()
        local parentH = self:GetParent():GetTall()
        local boxW = parentW * 0.5
        local boxH = parentH * 0.5
        self:SetSize(boxW, boxH)
        self:SetPos(0, parentH * 0.5)
    end
    
    -- Mode label (top right) - centered in its quadrant
    local modeHeaderLabel = vgui.Create("DLabel", typeModeBar)
    modeHeaderLabel:SetText("Mode:")
    modeHeaderLabel:SetTextColor(LOCK_COLOR_TEXT_DIM)
    modeHeaderLabel:SetFont(LOCK_FONT_TERTIARY)
    modeHeaderLabel:SetContentAlignment(5) -- Center alignment
    function modeHeaderLabel:PerformLayout()
        local parentW = self:GetParent():GetWide()
        local parentH = self:GetParent():GetTall()
        local boxW = parentW * 0.5
        local boxH = parentH * 0.5
        self:SetSize(boxW, boxH)
        self:SetPos(parentW * 0.5, 0)
    end
    
    -- Mode value (bottom right) - centered in its quadrant
    local modeValueLabel = vgui.Create("DLabel", typeModeBar)
    modeValueLabel:SetText(capitalizedMode)
    modeValueLabel:SetTextColor(LOCK_COLOR_TEXT)
    modeValueLabel:SetFont(LOCK_FONT_TERTIARY)
    modeValueLabel:SetContentAlignment(5) -- Center alignment
    function modeValueLabel:PerformLayout()
        local parentW = self:GetParent():GetWide()
        local parentH = self:GetParent():GetTall()
        local boxW = parentW * 0.5
        local boxH = parentH * 0.5
        self:SetSize(boxW, boxH)
        self:SetPos(parentW * 0.5, parentH * 0.5)
    end

    -- For keycard locks, users need a keycard OR override code to see the toggle button
    -- For biometric locks, users need to be authorized to see the toggle button
    local showToggle = true
    if (mode == "keycard") then
        if (not hasKeycard and not (hasOverrideCode and overrideModeEnabled)) then
            showToggle = false -- Users without keycards or override code (with override mode enabled) don't see toggle
        end
    elseif (mode == "biometric") then
        -- For biometric locks, only show toggle if user is authorized (not just admin)
        if (not isBio and not hasMaster) then
            showToggle = false -- Users not authorized don't see toggle
        end
    end

    if (showToggle) then
        local toggle = CreateLockButton(frame.contentArea, isLocked and "Unlock" or "Lock", function()
            if (mode == "code" and isLocked and not hasMaster and not isManager) then
                -- prompt for code to unlock (user code or master code)
                local codeFrame = vgui.Create("ixLockMenu")
                codeFrame:SetEntity(door)
                codeFrame:SetHeaderText("Enter Code")
                codeFrame:SetSize(280, 140)
                codeFrame:PositionFromEntity()
                codeFrame:MakePopup()

                local entry = vgui.Create("DTextEntry", codeFrame.contentArea)
                entry:Dock(TOP)
                entry:DockMargin(12, 12, 12, 8)
                entry:SetPlaceholderText("Code")
                entry:SetTall(25)
                -- StyleTextEntry(entry) -- Disabled for testing

                local ok = CreateLockButton(codeFrame.buttonArea, "Submit", function()
                    local code = entry:GetText() or ""
                    net.Start("ixDoorLocks_SubmitCode")
                        net.WriteString(lockID)
                        net.WriteString("unlock")
                        net.WriteString(code)
                    net.SendToServer()
                    codeFrame:Close()
                    frame:Close()
                end, "primary")
                ok:Dock(FILL)
                ok:DockMargin(12, 8, 12, 8)

                return
            elseif (mode == "keycard" and not hasKeycard and hasOverrideCode and overrideModeEnabled) then
                -- prompt for override code if user doesn't have keycard but override code exists and override mode is enabled
                -- Close the config menu first
                frame:Close()
                
                local codeFrame = vgui.Create("ixLockMenu")
                codeFrame:SetEntity(door)
                codeFrame:SetHeaderText("Override Code")
                codeFrame:SetSize(280, 160) -- Increased from 140 to 160 for more breathing room
                codeFrame:PositionFromEntity()
                codeFrame:MakePopup()

                local entry = vgui.Create("ixLockTextEntry", codeFrame.contentArea)
                entry:Dock(TOP)
                entry:DockMargin(12, 12, 12, 8)
                entry:SetPlaceholderText("Override Code")
                entry:SetTall(27) -- Increased from 25 to 27 (2 pixels more)

                -- Back button on the left (takes up half the width)
                local backBtn = CreateLockButton(codeFrame.buttonArea, "Back", function()
                    codeFrame:Close()
                    -- Reopen the config menu
                    net.Start("ixDoorLocks_RequestMenu")
                        net.WriteEntity(door)
                    net.SendToServer()
                end, "primary")
                backBtn:Dock(LEFT)
                backBtn:DockMargin(0, 0, 0, 0)
                function backBtn:PerformLayout()
                    self:SetWide(self:GetParent():GetWide() * 0.5)
                end

                -- Submit button on the right (takes up remaining half)
                local submitBtn = CreateLockButton(codeFrame.buttonArea, "Submit", function()
                    local code = entry:GetText() or ""
                    net.Start("ixDoorLocks_SubmitOverrideCode")
                        net.WriteString(lockID)
                        net.WriteString(isLocked and "unlock" or "lock")
                        net.WriteString(code)
                    net.SendToServer()
                    codeFrame:Close()
                end, "primary")
                submitBtn:Dock(FILL)
                submitBtn:DockMargin(0, 0, 0, 0)

                return
            end

            net.Start("ixDoorLocks_DoAction")
                net.WriteString("toggle")
                net.WriteString(lockID)
            net.SendToServer()
            frame:Close()
        end, "secondary")
        toggle:Dock(TOP)
        toggle:DockMargin(12, 4, 12, 0)
    end

    -- Code mode specific buttons (only visible to manager code users)
    if (mode == "code" and hasManager) then
        local changeUserCode = CreateLockButton(frame.contentArea, "Change User Code", function()
            local codeFrame = vgui.Create("ixLockMenu")
            codeFrame:SetEntity(door)
            codeFrame:SetHeaderText("Change User Code")
            codeFrame:SetSize(300, 200)
            codeFrame:PositionFromEntity()
            codeFrame:MakePopup()

            local entry1 = vgui.Create("DTextEntry", codeFrame.contentArea)
            entry1:Dock(TOP)
            entry1:DockMargin(12, 12, 12, 4)
            entry1:SetPlaceholderText("New User Code")
            entry1:SetTall(25)
            -- StyleTextEntry(entry1) -- Disabled for testing

            local entry2 = vgui.Create("DTextEntry", codeFrame.contentArea)
            entry2:Dock(TOP)
            entry2:DockMargin(12, 4, 12, 4)
            entry2:SetPlaceholderText("Retype User Code")
            entry2:SetTall(25)
            -- StyleTextEntry(entry2) -- Disabled for testing

            local ok = CreateLockButton(codeFrame.buttonArea, "Set Code", function()
                local code1 = entry1:GetText() or ""
                local code2 = entry2:GetText() or ""
                if (code1 ~= code2) then
                    LocalPlayer():Notify("Codes do not match. Please retype the code.")
                    return
                end
                if (code1 == "") then
                    LocalPlayer():Notify("Code cannot be empty.")
                    return
                end
                net.Start("ixDoorLocks_SubmitCode")
                    net.WriteString(lockID)
                    net.WriteString("change_user")
                    net.WriteString(code1)
                net.SendToServer()
                codeFrame:Close()
                frame:Close()
            end, "primary")
            ok:Dock(FILL)
            ok:DockMargin(12, 8, 12, 8)
        end, "secondary")
        changeUserCode:Dock(TOP)
        changeUserCode:DockMargin(12, 4, 12, 0)

        local changeManagerCode = CreateLockButton(frame.contentArea, "Change Manager Code", function()
            local codeFrame = vgui.Create("ixLockMenu")
            codeFrame:SetEntity(door)
            codeFrame:SetHeaderText("Change Manager Code")
            codeFrame:SetSize(300, 200)
            codeFrame:PositionFromEntity()
            codeFrame:MakePopup()

            local entry1 = vgui.Create("DTextEntry", codeFrame.contentArea)
            entry1:Dock(TOP)
            entry1:DockMargin(12, 12, 12, 4)
            entry1:SetPlaceholderText("New Manager Code")
            entry1:SetTall(25)
            -- StyleTextEntry(entry1) -- Disabled for testing

            local entry2 = vgui.Create("DTextEntry", codeFrame.contentArea)
            entry2:Dock(TOP)
            entry2:DockMargin(12, 4, 12, 4)
            entry2:SetPlaceholderText("Retype Manager Code")
            entry2:SetTall(25)
            -- StyleTextEntry(entry2) -- Disabled for testing

            local ok = CreateLockButton(codeFrame.buttonArea, "Set Code", function()
                local code1 = entry1:GetText() or ""
                local code2 = entry2:GetText() or ""
                if (code1 ~= code2) then
                    LocalPlayer():Notify("Codes do not match. Please retype the code.")
                    return
                end
                if (code1 == "") then
                    LocalPlayer():Notify("Code cannot be empty.")
                    return
                end
                net.Start("ixDoorLocks_SubmitCode")
                    net.WriteString(lockID)
                    net.WriteString("change_manager")
                    net.WriteString(code1)
                net.SendToServer()
                codeFrame:Close()
                frame:Close()
            end, "primary")
            ok:Dock(FILL)
            ok:DockMargin(12, 8, 12, 8)
        end, "secondary")
        changeManagerCode:Dock(TOP)
        changeManagerCode:DockMargin(12, 4, 12, 0)

        local clearUsers = CreateLockButton(frame.contentArea, "Clear User List", function()
            Derma_Query("Are you sure you wish to clear the user list?", "Confirm Clear Users",
                "Yes", function()
                    net.Start("ixDoorLocks_SubmitCode")
                        net.WriteString(lockID)
                        net.WriteString("clear_users")
                        net.WriteString("")
                    net.SendToServer()
                    frame:Close()
                end,
                "No", function() end
            )
        end, "secondary")
        clearUsers:Dock(TOP)
        clearUsers:DockMargin(12, 4, 12, 0)
    end

    -- Mode action button for non-code modes
    if (mode ~= "code") then
        if (mode == "biometric") then
            -- Regular pairing button (for managers or masters)
            if (isBioManager or hasMaster) then
                local regularPairing = CreateLockButton(frame.contentArea, "Start Regular Pairing", function()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("mode_action")
                        net.WriteString(lockID)
                    net.SendToServer()
                    frame:Close()
                end, "secondary")
                regularPairing:Dock(TOP)
                regularPairing:DockMargin(12, 4, 12, 0)
            end

            -- Manager-only buttons (for managers or masters)
            if (isBioManager or hasMaster) then
                local managerPairing = CreateLockButton(frame.contentArea, "Start Manager Pairing", function()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("biometric_manager_pairing")
                        net.WriteString(lockID)
                    net.SendToServer()
                    frame:Close()
                end, "secondary")
                managerPairing:Dock(TOP)
                managerPairing:DockMargin(12, 4, 12, 0)

                local viewUsers = CreateLockButton(frame.contentArea, "View User List", function()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("biometric_view_users")
                        net.WriteString(lockID)
                    net.SendToServer()
                    frame:Close()
                end, "secondary")
                viewUsers:Dock(TOP)
                viewUsers:DockMargin(12, 4, 12, 0)

                local clearUsers = CreateLockButton(frame.contentArea, "Clear User List", function()
                    Derma_Query("Are you sure you wish to clear the biometric user list?", "Confirm Clear Users",
                        "Yes", function()
                            net.Start("ixDoorLocks_DoAction")
                                net.WriteString("biometric_clear_users")
                                net.WriteString(lockID)
                            net.SendToServer()
                            frame:Close()
                        end,
                        "No", function() end
                    )
                end, "secondary")
                clearUsers:Dock(TOP)
                clearUsers:DockMargin(12, 4, 12, 0)
            end
        elseif (mode == "keycard") then
            -- For keycard locks, non-admins only see buttons if they have manager/master keycard
            -- Print Keycard button (for master/manager keycard holders)
            if (isKeycardManager) then
                local modeButton = CreateLockButton(frame.contentArea, "Print Keycard", function()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("mode_action")
                        net.WriteString(lockID)
                    net.SendToServer()
                    frame:Close()
                end, "secondary")
                modeButton:Dock(TOP)
                modeButton:DockMargin(12, 4, 12, 0)
            end

            -- View Keycards button (for master/manager keycard holders)
            if (isKeycardManager) then
                local viewKeycards = CreateLockButton(frame.contentArea, "View Keycards", function()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("keycard_view")
                        net.WriteString(lockID)
                    net.SendToServer()
                    frame:Close()
                end, "secondary")
                viewKeycards:Dock(TOP)
                viewKeycards:DockMargin(12, 4, 12, 0)
            end
            
            -- Lock Settings button (for masters only)
            local canManageSettings = false
            if (mode == "keycard") then
                canManageSettings = isKeycardMaster
            else
                canManageSettings = hasMaster
            end
            
            if (canManageSettings) then
                local lockSettings = CreateLockButton(frame.contentArea, "Lock Settings", function()
                    frame:Close()
                    shouldOpenLockSettings = true
                    -- Request fresh menu data, which will trigger opening Lock Settings
                    net.Start("ixDoorLocks_RequestMenu")
                        net.WriteEntity(door)
                    net.SendToServer()
                end, "secondary")
                lockSettings:Dock(TOP)
                lockSettings:DockMargin(12, 4, 12, 0)
            end
            
            -- Override Management button (for master keycard holders only)
            if (isKeycardMaster) then
                local overrideManagement = CreateLockButton(frame.contentArea, "Override Management", function()
                    frame:Close()
                    
                    -- Create Override Management window
                    local overrideFrame = vgui.Create("ixLockMenu")
                    overrideFrame:SetEntity(door)
                    overrideFrame:SetHeaderText("Override Management")
                    overrideFrame:SetSize(560, 200) -- 75% wider (320 * 1.75 = 560)
                    overrideFrame:PositionFromEntity()
                    overrideFrame:MakePopup()
                    
                    -- Manage Personal Override Code button
                    local managePersonalOverride = CreateLockButton(overrideFrame.contentArea, "Manage Personal Override Code", function()
                        local codeFrame = vgui.Create("ixLockMenu")
                        codeFrame:SetEntity(door)
                        codeFrame:SetHeaderText("Change Personal Override Code")
                        codeFrame:SetSize(600, 240)
                        codeFrame:PositionFromEntity()
                        codeFrame:MakePopup()
                        
                        -- Show current code status
                        local statusLabel = vgui.Create("DLabel", codeFrame.contentArea)
                        statusLabel:Dock(TOP)
                        statusLabel:DockMargin(12, 12, 12, 4)
                        if (hasPersonalOverrideCode) then
                            statusLabel:SetText("Current: Override code is set (cannot display)")
                        else
                            statusLabel:SetText("Current: No override code set")
                        end
                        statusLabel:SetTextColor(LOCK_COLOR_TEXT_DIM)
                        statusLabel:SetFont(LOCK_FONT_TERTIARY)
                        statusLabel:SizeToContents()
                        
                        local entry1 = vgui.Create("ixLockTextEntry", codeFrame.contentArea)
                        entry1:Dock(TOP)
                        entry1:DockMargin(12, 4, 12, 4)
                        entry1:SetPlaceholderText("New Override Code (leave empty to clear)")
                        entry1:SetTall(25)
                        
                        local entry2 = vgui.Create("ixLockTextEntry", codeFrame.contentArea)
                        entry2:Dock(TOP)
                        entry2:DockMargin(12, 4, 12, 4)
                        entry2:SetPlaceholderText("Retype Override Code")
                        entry2:SetTall(25)
                        
                        -- Back button on the left
                        local backBtn = CreateLockButton(codeFrame.buttonArea, "Back", function()
                            codeFrame:Close()
                        end, "primary")
                        backBtn:Dock(LEFT)
                        backBtn:DockMargin(0, 0, 0, 0)
                        function backBtn:PerformLayout()
                            self:SetWide(self:GetParent():GetWide() * 0.5)
                        end
                        
                        -- Submit button on the right
                        local submitBtn = CreateLockButton(codeFrame.buttonArea, "Submit", function()
                            local code1 = entry1:GetText() or ""
                            local code2 = entry2:GetText() or ""
                            if (code1 ~= "" and code1 ~= code2) then
                                LocalPlayer():Notify("Codes do not match. Please retype the code.")
                                return
                            end
                            net.Start("ixDoorLocks_ChangePersonalOverrideCode")
                                net.WriteString(lockID)
                                net.WriteString(code1)
                            net.SendToServer()
                            codeFrame:Close()
                            overrideFrame:Close()
                        end, "primary")
                        submitBtn:Dock(FILL)
                        submitBtn:DockMargin(0, 0, 0, 0)
                    end, "secondary")
                    managePersonalOverride:Dock(TOP)
                    managePersonalOverride:DockMargin(12, 12, 12, 0)
                    
                    -- Manage Group Override Code button
                    local manageGroupOverride = CreateLockButton(overrideFrame.contentArea, "Manage Group Override Code", function()
                        local codeFrame = vgui.Create("ixLockMenu")
                        codeFrame:SetEntity(door)
                        codeFrame:SetHeaderText("Change Group Override Code")
                        codeFrame:SetSize(600, 264)
                        codeFrame:PositionFromEntity()
                        codeFrame:MakePopup()
                        
                        -- Warning label
                        local warningLabel = vgui.Create("DLabel", codeFrame.contentArea)
                        warningLabel:Dock(TOP)
                        warningLabel:DockMargin(12, 12, 12, 4)
                        warningLabel:SetText("WARNING: This will affect ALL locks in the group!")
                        warningLabel:SetTextColor(Color(255, 200, 100, 255))
                        warningLabel:SetFont(LOCK_FONT_TERTIARY)
                        warningLabel:SizeToContents()
                        
                        -- Show current code status
                        local statusLabel = vgui.Create("DLabel", codeFrame.contentArea)
                        statusLabel:Dock(TOP)
                        statusLabel:DockMargin(12, 4, 12, 4)
                        if (hasGroupOverrideCode) then
                            statusLabel:SetText("Current: Group override code is set (cannot display)")
                        else
                            statusLabel:SetText("Current: No group override code set")
                        end
                        statusLabel:SetTextColor(LOCK_COLOR_TEXT_DIM)
                        statusLabel:SetFont(LOCK_FONT_TERTIARY)
                        statusLabel:SizeToContents()
                        
                        local entry1 = vgui.Create("ixLockTextEntry", codeFrame.contentArea)
                        entry1:Dock(TOP)
                        entry1:DockMargin(12, 4, 12, 4)
                        entry1:SetPlaceholderText("New Group Override Code (leave empty to clear)")
                        entry1:SetTall(25)
                        
                        local entry2 = vgui.Create("ixLockTextEntry", codeFrame.contentArea)
                        entry2:Dock(TOP)
                        entry2:DockMargin(12, 4, 12, 4)
                        entry2:SetPlaceholderText("Retype Group Override Code")
                        entry2:SetTall(25)
                        
                        -- Back button on the left
                        local backBtn = CreateLockButton(codeFrame.buttonArea, "Back", function()
                            codeFrame:Close()
                        end, "primary")
                        backBtn:Dock(LEFT)
                        backBtn:DockMargin(0, 0, 0, 0)
                        function backBtn:PerformLayout()
                            self:SetWide(self:GetParent():GetWide() * 0.5)
                        end
                        
                        -- Submit button on the right
                        local submitBtn = CreateLockButton(codeFrame.buttonArea, "Submit", function()
                            local code1 = entry1:GetText() or ""
                            local code2 = entry2:GetText() or ""
                            if (code1 ~= "" and code1 ~= code2) then
                                LocalPlayer():Notify("Codes do not match. Please retype the code.")
                                return
                            end
                            net.Start("ixDoorLocks_ChangeGroupOverrideCode")
                                net.WriteString(lockID)
                                net.WriteString(code1)
                            net.SendToServer()
                            codeFrame:Close()
                            overrideFrame:Close()
                        end, "primary")
                        submitBtn:Dock(FILL)
                        submitBtn:DockMargin(0, 0, 0, 0)
                    end, "secondary")
                    manageGroupOverride:Dock(TOP)
                    manageGroupOverride:DockMargin(12, 4, 12, 0)
                    
                    -- Override Mode toggle button
                    local overrideModeText = overrideModeEnabled and "Override Mode: Enabled" or "Override Mode: Disabled"
                    local overrideModeButton = CreateLockButton(overrideFrame.contentArea, overrideModeText, function()
                        net.Start("ixDoorLocks_ToggleOverrideMode")
                            net.WriteString(lockID)
                        net.SendToServer()
                        -- Refresh the Override Management menu instead of closing it
                        shouldOpenOverrideManagement = true
                        overrideFrame:Close()
                        -- Request fresh menu data, which will trigger reopening Override Management
                        net.Start("ixDoorLocks_RequestMenu")
                            net.WriteEntity(door)
                        net.SendToServer()
                    end, "secondary")
                    overrideModeButton:Dock(TOP)
                    overrideModeButton:DockMargin(12, 4, 12, 0)
                    
                    -- Back/Close buttons at bottom
                    local backBtn = CreateLockButton(overrideFrame.buttonArea, "Back", function()
                        overrideFrame:Close()
                        -- Reopen the config menu
                        net.Start("ixDoorLocks_RequestMenu")
                            net.WriteEntity(door)
                        net.SendToServer()
                    end, "primary")
                    backBtn:Dock(LEFT)
                    backBtn:DockMargin(0, 0, 0, 0)
                    function backBtn:PerformLayout()
                        self:SetWide(self:GetParent():GetWide() * 0.5)
                    end
                    
                    local closeBtn = CreateLockButton(overrideFrame.buttonArea, "Close", function()
                        overrideFrame:Close()
                    end, "primary")
                    closeBtn:Dock(FILL)
                    closeBtn:DockMargin(0, 0, 0, 0)
                end, "secondary")
                overrideManagement:Dock(TOP)
                overrideManagement:DockMargin(12, 4, 12, 0)
            end
        end
    end

    -- Group Management button (masters only)
    -- For keycard locks, require master tier keycard; for other locks, require master access
    local canManageGroup = false
    if (mode == "keycard") then
        canManageGroup = isKeycardMaster
    else
        canManageGroup = hasMaster
    end
    
    if (canManageGroup) then
        local groupManagement = CreateLockButton(frame.contentArea, "Group Management", function()
            frame:Close()
            -- Request group management data from server
            net.Start("ixDoorLocks_ViewGroupLocks")
                net.WriteString(lockID)
            net.SendToServer()
        end, "secondary")
        groupManagement:Dock(TOP)
        groupManagement:DockMargin(12, 4, 12, 0)
    end

    -- Remove Lock button
    -- For keycard locks: master tier keycard holders can remove
    -- For other locks: masters (installers/admins) can remove
    local canRemoveLock = false
    if (mode == "keycard") then
        canRemoveLock = isKeycardMaster
    else
        canRemoveLock = hasMaster
    end

    if (canRemoveLock) then
        local remove = CreateLockButton(frame.contentArea, "Remove Lock", function()
            Derma_Query("Are you sure you wish to remove this lock?", "Confirm Removal",
                "Yes", function()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("remove")
                        net.WriteString(lockID)
                    net.SendToServer()
                    frame:Close()
                end,
                "No", function() end
            )
        end, "secondary")
        remove:Dock(TOP)
        remove:DockMargin(12, 4, 12, 0)
    end

    -- Admin buttons (mode-specific)
    if (isAdmin) then
        if (mode == "code") then
            local adminMaster = CreateLockButton(frame.contentArea, "Admin: Master on Self", function()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("admin_master_self")
                    net.WriteString(lockID)
                net.SendToServer()
                frame:Close()
            end, "admin")
            adminMaster:Dock(TOP)
            adminMaster:DockMargin(12, 4, 12, 0)
        elseif (mode == "keycard") then
            -- Admin buttons for keycard locks: Print Story Card, Print Master Card, Remove Lock
            local storyCardButton = CreateLockButton(frame.contentArea, "Admin: Print Story Card", function()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("keycard_story_menu")
                    net.WriteString(lockID)
                net.SendToServer()
                frame:Close()
            end, "admin")
            storyCardButton:Dock(TOP)
            storyCardButton:DockMargin(12, 4, 12, 0)

            local adminPrintMaster = CreateLockButton(frame.contentArea, "Admin: Print Master Card", function()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("admin_print_master")
                    net.WriteString(lockID)
                net.SendToServer()
                frame:Close()
            end, "admin")
            adminPrintMaster:Dock(TOP)
            adminPrintMaster:DockMargin(12, 4, 12, 0)
        elseif (mode == "biometric") then
            local adminMaster = CreateLockButton(frame.contentArea, "Admin: Master on Self", function()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("admin_master_self")
                    net.WriteString(lockID)
                net.SendToServer()
                frame:Close()
            end, "admin")
            adminMaster:Dock(TOP)
            adminMaster:DockMargin(12, 4, 12, 0)
        end

        local adminRemove = CreateLockButton(frame.contentArea, "Admin: Remove Lock", function()
            Derma_Query("Are you sure you wish to remove this lock with admin commands?", "Confirm Admin Removal",
                "Yes", function()
                    net.Start("ixDoorLocks_DoAction")
                        net.WriteString("admin_remove")
                        net.WriteString(lockID)
                    net.SendToServer()
                    frame:Close()
                end,
                "No", function() end
            )
        end, "admin")
        adminRemove:Dock(TOP)
        adminRemove:DockMargin(12, 4, 12, 0)
    end

    -- Full-width close button at bottom (truly full width, no margins)
    local closeBtn = CreateLockButton(frame.buttonArea, "Close", function()
        frame:Close()
    end, "primary")
    closeBtn:Dock(FILL)
    closeBtn:DockMargin(0, 0, 0, 0)
    
    -- Force layout update to ensure all buttons are properly rendered
    frame:InvalidateLayout(true)
    timer.Simple(0, function()
        if (IsValid(frame)) then
            frame:InvalidateLayout(true)
        end
    end)
end

net.Receive("ixDoorLocks_OpenMenu", function()
    local door = net.ReadEntity()
    local lockID = net.ReadString()
    local isDeadlock = net.ReadBool()
    local lockType = net.ReadString()
    local mode = net.ReadString()
    local isLocked = net.ReadBool()
    local isManager = net.ReadBool()
    local isBio = net.ReadBool()
    local isBioManager = net.ReadBool()
    local hasManager = net.ReadBool()
    local hasMaster = net.ReadBool()
    local hasKeycard = net.ReadBool()
    local isKeycardMaster = net.ReadBool()
    local isKeycardManager = net.ReadBool()
    local hasOverrideCode = net.ReadBool() -- Whether lock has override code available
    local overrideModeEnabled = net.ReadBool() -- Override mode enabled state
    local hasPersonalOverrideCode = net.ReadBool() -- Whether personal override code exists
    local hasGroupOverrideCode = net.ReadBool() -- Whether group override code exists
    local isAdmin = net.ReadBool()
    local isAdminDeactivated = net.ReadBool()
    local autolockEnabled = net.ReadBool() -- Autolock setting
    local retainDoorState = net.ReadBool() -- Retain door state setting

    -- Check if we should open Lock Settings instead of main menu
    if (shouldOpenLockSettings) then
        shouldOpenLockSettings = false
        -- Close any existing menu
        if (IsValid(activeLockMenu)) then
            activeLockMenu:Close()
        end
        
        -- Create Lock Settings window
        local settingsFrame = vgui.Create("ixLockMenu")
        settingsFrame:SetEntity(door)
        settingsFrame:SetHeaderText("Lock Settings")
        settingsFrame:SetSize(320, 200)
        settingsFrame:PositionFromEntity()
        settingsFrame:MakePopup()
        
        activeLockMenu = settingsFrame
        
        -- Autolock toggle button
        local autolockText = autolockEnabled and "Autolock: On" or "Autolock: Off"
        local autolockButton = CreateLockButton(settingsFrame.contentArea, autolockText, function()
            net.Start("ixDoorLocks_ToggleAutolock")
                net.WriteString(lockID)
            net.SendToServer()
            -- Refresh the Lock Settings menu
            shouldOpenLockSettings = true
            settingsFrame:Close()
            net.Start("ixDoorLocks_RequestMenu")
                net.WriteEntity(door)
            net.SendToServer()
        end, "secondary")
        autolockButton:Dock(TOP)
        autolockButton:DockMargin(12, 12, 12, 0)
        
        -- Retain Door State toggle button
        local retainStateText = retainDoorState and "Retain Door State: On" or "Retain Door State: Off"
        local retainStateButton = CreateLockButton(settingsFrame.contentArea, retainStateText, function()
            net.Start("ixDoorLocks_ToggleRetainDoorState")
                net.WriteString(lockID)
            net.SendToServer()
            -- Refresh the Lock Settings menu
            shouldOpenLockSettings = true
            settingsFrame:Close()
            net.Start("ixDoorLocks_RequestMenu")
                net.WriteEntity(door)
            net.SendToServer()
        end, "secondary")
        retainStateButton:Dock(TOP)
        retainStateButton:DockMargin(12, 4, 12, 0)
        
        -- Back button on the left
        local backBtn = CreateLockButton(settingsFrame.buttonArea, "Back", function()
            settingsFrame:Close()
            -- Reopen the config menu
            net.Start("ixDoorLocks_RequestMenu")
                net.WriteEntity(door)
            net.SendToServer()
        end, "primary")
        backBtn:Dock(LEFT)
        backBtn:DockMargin(0, 0, 0, 0)
        function backBtn:PerformLayout()
            self:SetWide(self:GetParent():GetWide() * 0.5)
        end
        
        -- Close button on the right
        local closeBtn = CreateLockButton(settingsFrame.buttonArea, "Close", function()
            settingsFrame:Close()
        end, "primary")
        closeBtn:Dock(FILL)
        closeBtn:DockMargin(0, 0, 0, 0)
        
        return -- Don't create main menu
    end
    
    -- Check if we should open Override Management instead of main menu
    if (shouldOpenOverrideManagement) then
        shouldOpenOverrideManagement = false
        -- Close any existing menu
        if (IsValid(activeLockMenu)) then
            activeLockMenu:Close()
        end
        
        -- Create Override Management window
        local overrideFrame = vgui.Create("ixLockMenu")
        overrideFrame:SetEntity(door)
        overrideFrame:SetHeaderText("Override Management")
        overrideFrame:SetSize(560, 200) -- 75% wider (320 * 1.75 = 560)
        overrideFrame:PositionFromEntity()
        overrideFrame:MakePopup()
        
        activeLockMenu = overrideFrame
        
        -- Manage Personal Override Code button
        local managePersonalOverride = CreateLockButton(overrideFrame.contentArea, "Manage Personal Override Code", function()
            local codeFrame = vgui.Create("ixLockMenu")
            codeFrame:SetEntity(door)
            codeFrame:SetHeaderText("Change Personal Override Code")
            codeFrame:SetSize(600, 240)
            codeFrame:PositionFromEntity()
            codeFrame:MakePopup()
            
            -- Show current code status
            local statusLabel = vgui.Create("DLabel", codeFrame.contentArea)
            statusLabel:Dock(TOP)
            statusLabel:DockMargin(12, 12, 12, 4)
            if (hasPersonalOverrideCode) then
                statusLabel:SetText("Current: Override code is set (cannot display)")
            else
                statusLabel:SetText("Current: No override code set")
            end
            statusLabel:SetTextColor(LOCK_COLOR_TEXT_DIM)
            statusLabel:SetFont(LOCK_FONT_TERTIARY)
            statusLabel:SizeToContents()
            
            local entry1 = vgui.Create("ixLockTextEntry", codeFrame.contentArea)
            entry1:Dock(TOP)
            entry1:DockMargin(12, 4, 12, 4)
            entry1:SetPlaceholderText("New Override Code (leave empty to clear)")
            entry1:SetTall(25)
            
            local entry2 = vgui.Create("ixLockTextEntry", codeFrame.contentArea)
            entry2:Dock(TOP)
            entry2:DockMargin(12, 4, 12, 4)
            entry2:SetPlaceholderText("Retype Override Code")
            entry2:SetTall(25)
            
            -- Back button on the left
            local backBtn = CreateLockButton(codeFrame.buttonArea, "Back", function()
                codeFrame:Close()
            end, "primary")
            backBtn:Dock(LEFT)
            backBtn:DockMargin(0, 0, 0, 0)
            function backBtn:PerformLayout()
                self:SetWide(self:GetParent():GetWide() * 0.5)
            end
            
            -- Submit button on the right
            local submitBtn = CreateLockButton(codeFrame.buttonArea, "Submit", function()
                local code1 = entry1:GetText() or ""
                local code2 = entry2:GetText() or ""
                if (code1 ~= "" and code1 ~= code2) then
                    LocalPlayer():Notify("Codes do not match. Please retype the code.")
                    return
                end
                net.Start("ixDoorLocks_ChangePersonalOverrideCode")
                    net.WriteString(lockID)
                    net.WriteString(code1)
                net.SendToServer()
                codeFrame:Close()
                overrideFrame:Close()
            end, "primary")
            submitBtn:Dock(FILL)
            submitBtn:DockMargin(0, 0, 0, 0)
        end, "secondary")
        managePersonalOverride:Dock(TOP)
        managePersonalOverride:DockMargin(12, 12, 12, 0)
        
        -- Manage Group Override Code button
        local manageGroupOverride = CreateLockButton(overrideFrame.contentArea, "Manage Group Override Code", function()
            local codeFrame = vgui.Create("ixLockMenu")
            codeFrame:SetEntity(door)
            codeFrame:SetHeaderText("Change Group Override Code")
            codeFrame:SetSize(600, 264)
            codeFrame:PositionFromEntity()
            codeFrame:MakePopup()
            
            -- Warning label
            local warningLabel = vgui.Create("DLabel", codeFrame.contentArea)
            warningLabel:Dock(TOP)
            warningLabel:DockMargin(12, 12, 12, 4)
            warningLabel:SetText("WARNING: This will affect ALL locks in the group!")
            warningLabel:SetTextColor(Color(255, 200, 100, 255))
            warningLabel:SetFont(LOCK_FONT_TERTIARY)
            warningLabel:SizeToContents()
            
            -- Show current code status
            local statusLabel = vgui.Create("DLabel", codeFrame.contentArea)
            statusLabel:Dock(TOP)
            statusLabel:DockMargin(12, 4, 12, 4)
            if (hasGroupOverrideCode) then
                statusLabel:SetText("Current: Group override code is set (cannot display)")
            else
                statusLabel:SetText("Current: No group override code set")
            end
            statusLabel:SetTextColor(LOCK_COLOR_TEXT_DIM)
            statusLabel:SetFont(LOCK_FONT_TERTIARY)
            statusLabel:SizeToContents()
            
            local entry1 = vgui.Create("ixLockTextEntry", codeFrame.contentArea)
            entry1:Dock(TOP)
            entry1:DockMargin(12, 4, 12, 4)
            entry1:SetPlaceholderText("New Group Override Code (leave empty to clear)")
            entry1:SetTall(25)
            
            local entry2 = vgui.Create("ixLockTextEntry", codeFrame.contentArea)
            entry2:Dock(TOP)
            entry2:DockMargin(12, 4, 12, 4)
            entry2:SetPlaceholderText("Retype Group Override Code")
            entry2:SetTall(25)
            
            -- Back button on the left
            local backBtn = CreateLockButton(codeFrame.buttonArea, "Back", function()
                codeFrame:Close()
            end, "primary")
            backBtn:Dock(LEFT)
            backBtn:DockMargin(0, 0, 0, 0)
            function backBtn:PerformLayout()
                self:SetWide(self:GetParent():GetWide() * 0.5)
            end
            
            -- Submit button on the right
            local submitBtn = CreateLockButton(codeFrame.buttonArea, "Submit", function()
                local code1 = entry1:GetText() or ""
                local code2 = entry2:GetText() or ""
                if (code1 ~= "" and code1 ~= code2) then
                    LocalPlayer():Notify("Codes do not match. Please retype the code.")
                    return
                end
                net.Start("ixDoorLocks_ChangeGroupOverrideCode")
                    net.WriteString(lockID)
                    net.WriteString(code1)
                net.SendToServer()
                codeFrame:Close()
                overrideFrame:Close()
            end, "primary")
            submitBtn:Dock(FILL)
            submitBtn:DockMargin(0, 0, 0, 0)
        end, "secondary")
        manageGroupOverride:Dock(TOP)
        manageGroupOverride:DockMargin(12, 4, 12, 0)
        
        -- Override Mode toggle button
        local overrideModeText = overrideModeEnabled and "Override Mode: Enabled" or "Override Mode: Disabled"
        local overrideModeButton = CreateLockButton(overrideFrame.contentArea, overrideModeText, function()
            net.Start("ixDoorLocks_ToggleOverrideMode")
                net.WriteString(lockID)
            net.SendToServer()
            -- Refresh the Override Management menu instead of closing it
            shouldOpenOverrideManagement = true
            overrideFrame:Close()
            -- Request fresh menu data, which will trigger reopening Override Management
            net.Start("ixDoorLocks_RequestMenu")
                net.WriteEntity(door)
            net.SendToServer()
        end, "secondary")
        overrideModeButton:Dock(TOP)
        overrideModeButton:DockMargin(12, 4, 12, 0)
        
        -- Back/Close buttons at bottom
        local backBtn = CreateLockButton(overrideFrame.buttonArea, "Back", function()
            overrideFrame:Close()
            -- Reopen the config menu
            net.Start("ixDoorLocks_RequestMenu")
                net.WriteEntity(door)
            net.SendToServer()
        end, "primary")
        backBtn:Dock(LEFT)
        backBtn:DockMargin(0, 0, 0, 0)
        function backBtn:PerformLayout()
            self:SetWide(self:GetParent():GetWide() * 0.5)
        end
        
        local closeBtn = CreateLockButton(overrideFrame.buttonArea, "Close", function()
            overrideFrame:Close()
        end, "primary")
        closeBtn:Dock(FILL)
        closeBtn:DockMargin(0, 0, 0, 0)
        
        return
    end

    OpenLockMenu(door, lockID, isDeadlock, lockType, mode, isLocked, isManager, isBio, isBioManager, hasManager, hasMaster, hasKeycard, isKeycardMaster, isKeycardManager, isAdmin, isAdminDeactivated, hasOverrideCode, overrideModeEnabled, hasPersonalOverrideCode, hasGroupOverrideCode)
end)

-- Play sound from server
net.Receive("ixDoorLocks_PlaySound", function()
    local soundPath = net.ReadString()
    if (soundPath) then
        surface.PlaySound(soundPath)
    end
end)

-- Group management data receiver
net.Receive("ixDoorLocks_GroupManagementData", function()
    local door = net.ReadEntity() -- Door entity for reopening config menu
    local lockID = net.ReadString()
    local groupCode = net.ReadString()
    local lockCount = net.ReadUInt(8)
    
    local locks = {}
    for i = 1, lockCount do
        table.insert(locks, {
            lockID = net.ReadString(),
            mode = net.ReadString(),
            doorName = net.ReadString()
        })
    end
    
    -- Close the config menu if it's open
    if (IsValid(activeLockMenu)) then
        activeLockMenu:Close()
        activeLockMenu = nil
    end
    
    -- Calculate window height procedurally
    -- Base height: 250px, max height: 750px (3x base)
    -- Each lock entry: 40px height + 4px margin = 44px
    -- Header area: ~50px, code label: ~20px, locks label: ~20px, margins: ~40px = ~130px base content
    -- Increased by 30% for breathing room: ~169px
    -- Button area: 50px
    local baseContentHeight = 169
    local buttonAreaHeight = 50
    local lockEntryHeight = 44
    local maxContentHeight = 750 - buttonAreaHeight -- 700px max for content area
    local scrollThreshold = math.floor((maxContentHeight - baseContentHeight) / lockEntryHeight) -- How many locks before scrolling
    
    local contentHeight = baseContentHeight + (math.min(lockCount, scrollThreshold) * lockEntryHeight)
    local windowHeight = contentHeight + buttonAreaHeight
    local useScroll = (lockCount > scrollThreshold)
    
    -- Create group management window
    local mgmtFrame = vgui.Create("ixLockMenu")
    mgmtFrame:SetEntity(door)
    mgmtFrame:SetHeaderText("Group Management")
    mgmtFrame:SetSize(720, windowHeight) -- 20% wider (600 * 1.2 = 720)
    mgmtFrame:PositionFromEntity()
    mgmtFrame:MakePopup()
    
    activeLockMenu = mgmtFrame
    
    -- Current group code label
    local codeLabel = vgui.Create("DLabel", mgmtFrame.contentArea)
    codeLabel:Dock(TOP)
    codeLabel:DockMargin(12, 12, 12, 4)
    if (groupCode and groupCode ~= "") then
        codeLabel:SetText("Current Group Code: " .. groupCode)
    else
        codeLabel:SetText("Current Group Code: None")
    end
    codeLabel:SetTextColor(LOCK_COLOR_TEXT)
    codeLabel:SetFont(LOCK_FONT_TERTIARY)
    codeLabel:SizeToContents()
    
    -- Locks in group label
    local locksLabel = vgui.Create("DLabel", mgmtFrame.contentArea)
    locksLabel:Dock(TOP)
    locksLabel:DockMargin(12, 8, 12, 4)
    locksLabel:SetText("Locks in group (" .. lockCount .. "):")
    locksLabel:SetTextColor(LOCK_COLOR_TEXT)
    locksLabel:SetFont(LOCK_FONT_TERTIARY)
    locksLabel:SizeToContents()
    
    -- List of locks (scrollable if needed)
    local scroll = nil
    local listContainer = nil
    if (useScroll) then
        scroll = vgui.Create("DScrollPanel", mgmtFrame.contentArea)
        scroll:Dock(FILL)
        scroll:DockMargin(12, 4, 12, 12)
        listContainer = scroll
    else
        listContainer = mgmtFrame.contentArea
    end
    
    if (#locks == 0) then
        local noLocks = vgui.Create("DLabel", listContainer)
        noLocks:Dock(TOP)
        noLocks:DockMargin(8, 8, 8, 8)
        noLocks:SetText("No locks in group.")
        noLocks:SetTextColor(LOCK_COLOR_TEXT_DIM)
        noLocks:SetFont(LOCK_FONT_TERTIARY)
        noLocks:SizeToContents()
    else
        for _, lockData in ipairs(locks) do
            local panel = vgui.Create("DPanel", listContainer)
            panel:Dock(TOP)
            panel:SetHeight(40)
            if (useScroll) then
                panel:DockMargin(0, 0, 0, 4)
            else
                panel:DockMargin(12, 4, 12, 4)
            end
            
            -- Style the panel with background
            function panel:Paint(w, h)
                draw.RoundedBox(0, 0, 0, w, h, LOCK_COLOR_BG_DARK)
                surface.SetDrawColor(LOCK_COLOR_BORDER)
                surface.DrawOutlinedRect(0, 0, w, h)
            end
            
            local isCurrent = (lockData.lockID == lockID)
            local displayText = string.format("%s (%s) - %s", lockData.lockID, lockData.mode, lockData.doorName)
            if (isCurrent) then
                displayText = displayText .. " (Current)"
            end
            
            local label = vgui.Create("DLabel", panel)
            label:Dock(LEFT)
            label:DockMargin(8, 0, 0, 0)
            label:SetText(displayText)
            label:SetTextColor(isCurrent and LOCK_COLOR_TEXT or LOCK_COLOR_TEXT_DIM)
            label:SetFont(LOCK_FONT_TERTIARY)
            label:SizeToContents()
        end
    end
    
    -- Back/Change Group Code buttons in button area
    -- Back button on the left - reopens config menu
    local backBtn = CreateLockButton(mgmtFrame.buttonArea, "Back", function()
        mgmtFrame:Close()
        -- Reopen the config menu
        net.Start("ixDoorLocks_RequestMenu")
            net.WriteEntity(door)
        net.SendToServer()
    end, "primary")
    backBtn:Dock(LEFT)
    backBtn:DockMargin(0, 0, 0, 0)
    function backBtn:PerformLayout()
        self:SetWide(self:GetParent():GetWide() * 0.5)
    end
    
    -- Change Group Code button on the right
    local changeCodeBtn = CreateLockButton(mgmtFrame.buttonArea, "Change Group Code", function()
        -- Close the group management window
        mgmtFrame:Close()
        
        local changeFrame = vgui.Create("ixLockMenu")
        changeFrame:SetEntity(door)
        changeFrame:SetHeaderText("Change Group Code")
        changeFrame:SetSize(720, 150) -- Match width with group management window
        changeFrame:PositionFromEntity()
        changeFrame:MakePopup()
        
        local entry = vgui.Create("ixLockTextEntry", changeFrame.contentArea)
        entry:Dock(TOP)
        entry:DockMargin(12, 12, 12, 4)
        entry:SetPlaceholderText("Group Code (leave empty to clear)")
        entry:SetTall(25)
        if (groupCode and groupCode ~= "") then
            entry:SetText(groupCode)
        end
        
        -- Back button on the left - reopens group management window
        local changeBackBtn = CreateLockButton(changeFrame.buttonArea, "Back", function()
            changeFrame:Close()
            -- Reopen the group management window
            net.Start("ixDoorLocks_ViewGroupLocks")
                net.WriteString(lockID)
            net.SendToServer()
        end, "primary")
        changeBackBtn:Dock(LEFT)
        changeBackBtn:DockMargin(0, 0, 0, 0)
        function changeBackBtn:PerformLayout()
            self:SetWide(self:GetParent():GetWide() * 0.5)
        end
        
        -- Submit button on the right
        local submitBtn = CreateLockButton(changeFrame.buttonArea, "Submit", function()
            local newCode = entry:GetText() or ""
            net.Start("ixDoorLocks_SetGroupCode")
                net.WriteString(lockID)
                net.WriteString(newCode)
            net.SendToServer()
            changeFrame:Close()
            -- Reopen the group management window
            net.Start("ixDoorLocks_ViewGroupLocks")
                net.WriteString(lockID)
            net.SendToServer()
        end, "primary")
        submitBtn:Dock(FILL)
        submitBtn:DockMargin(0, 0, 0, 0)
    end, "primary")
    changeCodeBtn:Dock(FILL)
    changeCodeBtn:DockMargin(0, 0, 0, 0)
end)

-- Biometric user list viewer
net.Receive("ixDoorLocks_BiometricUserList", function()
    local lockID = net.ReadString()
    local door = net.ReadEntity() -- Door entity for Back button
    local canRemoveMasters = net.ReadBool() -- All masters can remove other masters
    local currentUserID = net.ReadUInt(32) -- Current user's ID to prevent self-removal
    local isAdmin = net.ReadBool() -- Admin status
    local users = net.ReadTable()

    -- Close existing menu if open
    if (IsValid(activeBiometricMenu)) then
        activeBiometricMenu:Close()
        activeBiometricMenu = nil
    end

    local frame = vgui.Create("ixLockMenu")
    frame:SetEntity(door)
    frame:SetHeaderText("Biometric User List")
    frame:SetSize(520, 470)
    frame:PositionFromEntity()
    frame:MakePopup()
    
    -- Store reference and clean up on close
    activeBiometricMenu = frame
    function frame:OnClose()
        if (activeBiometricMenu == self) then
            activeBiometricMenu = nil
        end
    end

    local scroll = vgui.Create("DScrollPanel", frame.contentArea)
    scroll:Dock(FILL)
    scroll:DockMargin(12, 12, 12, 12)

    if (#users == 0) then
        local noUsers = vgui.Create("DLabel", scroll)
        noUsers:Dock(TOP)
        noUsers:DockMargin(8, 8, 8, 8)
        noUsers:SetText("No biometric users registered.")
        noUsers:SetTextColor(LOCK_COLOR_TEXT_DIM)
        noUsers:SetFont(LOCK_FONT_TERTIARY)
        noUsers:SizeToContents()
    end

    for _, user in ipairs(users) do
        local panel = vgui.Create("DPanel", scroll)
        panel:Dock(TOP)
        panel:SetHeight(35)
        panel:DockMargin(0, 0, 0, 4)

        local isSelf = (user.id == currentUserID)
        
        -- Name label with color coding
        local label = vgui.Create("DLabel", panel)
        label:Dock(LEFT)
        local tierText = ""
        local tierColor = LOCK_COLOR_TEXT
        
        if (user.isMaster) then
            tierText = " (Master)"
            tierColor = Color(255, 215, 0) -- Gold for master
        elseif (user.isManager) then
            tierText = " (Manager)"
            tierColor = Color(100, 149, 237) -- Cornflower blue for manager
        elseif (user.isInactive) then
            tierText = " (Inactive)"
            tierColor = LOCK_COLOR_TEXT_DIM -- Gray for inactive
        else
            tierText = " (User)"
            tierColor = LOCK_COLOR_TEXT -- Light text for user
        end
        
        label:SetText(user.name .. tierText)
        label:SetTextColor(tierColor)
        label:SetFont(LOCK_FONT_TERTIARY)
        label:SizeToContents()
        label:DockMargin(8, 0, 0, 0)

        -- Remove button (rightmost)
        -- Show remove button if: can remove masters (installer), or if target is not a manager/master, or if admin
        local canRemove = canRemoveMasters or (not user.isManager and not user.isMaster) or isAdmin
        if (canRemove) then
            local remove = CreateLockButton(panel, "Remove", function()
                Derma_Query("Are you sure you wish to delete this user?", "Confirm User Removal",
                    "Yes", function()
                        net.Start("ixDoorLocks_DoAction")
                            net.WriteString("biometric_remove_user")
                            net.WriteString(lockID)
                            net.WriteUInt(user.id, 32)
                        net.SendToServer()
                    end,
                    "No", function() end
                )
            end, "secondary", {width = 60})
            remove:Dock(RIGHT)
            -- Allow managers to remove themselves, but not masters
            remove:SetEnabled(not isSelf or (isSelf and user.isManager and not user.isMaster))
        end

        -- Activate/Deactivate button (always visible, but enabled based on permissions)
        -- Admins can always use it, others need proper permissions
        local toggleActive = CreateLockButton(panel, user.isInactive and "Activate" or "Deactivate", function()
            net.Start("ixDoorLocks_DoAction")
                net.WriteString("biometric_toggle_active")
                net.WriteString(lockID)
                net.WriteUInt(user.id, 32)
            net.SendToServer()
        end, "secondary", {width = 90})
        toggleActive:Dock(RIGHT)
        -- Enable if: admin, or not self, or has proper permissions (handled server-side)
        toggleActive:SetEnabled(not isSelf or isAdmin)

        -- Demote button (only for masters, only if target is manager or master)
        if (canRemoveMasters and (user.isManager or user.isMaster)) then
            local demote = CreateLockButton(panel, "Demote", function()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("biometric_demote_user")
                    net.WriteString(lockID)
                    net.WriteUInt(user.id, 32)
                net.SendToServer()
            end, "secondary", {width = 70})
            demote:Dock(RIGHT)
            demote:SetEnabled(not isSelf and not user.isMaster) -- Can't demote masters (installers)
        end

        -- Promote button (only for non-masters and non-managers)
        if (canRemoveMasters and not user.isManager and not user.isMaster) then
            local promote = CreateLockButton(panel, "Promote", function()
                net.Start("ixDoorLocks_DoAction")
                    net.WriteString("biometric_promote_user")
                    net.WriteString(lockID)
                    net.WriteUInt(user.id, 32)
                net.SendToServer()
            end, "secondary", {width = 70})
            promote:Dock(RIGHT)
            promote:SetEnabled(not isSelf)
        end

    end

    -- Split bottom buttons: Back (left half) and Close (right half)
    local back = CreateLockButton(frame.buttonArea, "Back", function()
        frame:Close()
        -- Request main menu again by sending the door entity
        if (IsValid(door)) then
            net.Start("ixDoorLocks_RequestMenu")
                net.WriteEntity(door)
            net.SendToServer()
        end
    end, "primary")
    back:Dock(LEFT)
    back:SetWide(frame:GetWide() * 0.5)
    back:DockMargin(0, 0, 0, 0)

    local close = CreateLockButton(frame.buttonArea, "Close", function()
        frame:Close()
    end, "primary")
    close:Dock(RIGHT)
    close:SetWide(frame:GetWide() * 0.5)
    close:DockMargin(0, 0, 0, 0)
end)

-- Keycard print menu
net.Receive("ixDoorLocks_KeycardPrintMenu", function()
    local lockID = net.ReadString()
    local canPrintInstaller = net.ReadBool()
    local door = net.ReadEntity() -- Get door entity from server (or NULL)

    -- Close existing menu if open
    if (IsValid(activeKeycardPrintMenu)) then
        activeKeycardPrintMenu:Close()
        activeKeycardPrintMenu = nil
    end

    local frame = vgui.Create("ixLockMenu")
    if (IsValid(door)) then
        frame:SetEntity(door)
    end
    frame:SetHeaderText("Print Keycard")
    frame:SetSize(320, 336) -- 40% taller (240 * 1.4 = 336)
    if (IsValid(door)) then
        frame:PositionFromEntity()
    else
        frame:Center()
    end
    frame:MakePopup()
    
    -- Store reference and clean up on close
    activeKeycardPrintMenu = frame
    function frame:OnClose()
        if (activeKeycardPrintMenu == self) then
            activeKeycardPrintMenu = nil
        end
    end

    -- Count blank keycards in inventory
    local blankKeycardCount = 0
    local char = LocalPlayer():GetCharacter()
    if (char) then
        local inventory = char:GetInventory()
        if (inventory) then
            for _, item in pairs(inventory:GetItemsByUniqueID("doorlock_keycard") or {}) do
                local itemLockID = item:GetData("lockID", nil)
                if (not itemLockID) then
                    blankKeycardCount = blankKeycardCount + 1
                end
            end
        end
    end
    
    -- Blank keycard counter (split into two labels for different colors)
    local blankCounterContainer = vgui.Create("DPanel", frame.contentArea)
    blankCounterContainer:Dock(TOP)
    blankCounterContainer:DockMargin(0, 12, 0, 0)
    blankCounterContainer:SetTall(22) -- Increased to prevent text cutoff
    blankCounterContainer:SetMouseInputEnabled(false)
    blankCounterContainer.Paint = function() end -- Invisible
    
    local requireBlank = ix.config.Get("requireBlankKeycard", true)
    local countText = ""
    local countColor = LOCK_COLOR_TEXT
    
    if (blankKeycardCount == 0) then
        countText = "None!"
        if (requireBlank) then
            countColor = Color(255, 0, 0) -- Red if required
        else
            countColor = Color(0, 255, 0) -- Green if not required
        end
    else
        countText = tostring(blankKeycardCount)
        countColor = LOCK_COLOR_TEXT
    end
    
    local prefixLabel = vgui.Create("DLabel", blankCounterContainer)
    prefixLabel:SetText("Keycard Blanks: ")
    prefixLabel:SetTextColor(LOCK_COLOR_TEXT)
    prefixLabel:SetFont(LOCK_FONT_TERTIARY)
    prefixLabel:SizeToContents()
    
    local countLabel = vgui.Create("DLabel", blankCounterContainer)
    countLabel:SetText(countText)
    countLabel:SetTextColor(countColor)
    countLabel:SetFont(LOCK_FONT_TERTIARY)
    countLabel:SizeToContents()
    
    -- Center the labels
    function blankCounterContainer:PerformLayout()
        -- Ensure container takes full width
        self:SetWide(self:GetParent():GetWide())
        
        -- Center the labels
        local totalWidth = prefixLabel:GetWide() + countLabel:GetWide()
        local parentWidth = self:GetWide()
        if (parentWidth > 0 and totalWidth > 0) then
            local startX = math.floor((parentWidth - totalWidth) * 0.5)
            prefixLabel:SetPos(startX, 0)
            countLabel:SetPos(startX + prefixLabel:GetWide(), 0)
        end
    end
    
    -- Force layout update after a short delay to ensure parent width is available
    timer.Simple(0.01, function()
        if (IsValid(blankCounterContainer)) then
            blankCounterContainer:InvalidateLayout()
        end
    end)

    -- Divider between blank keycards and access level
    local divider1 = vgui.Create("DPanel", frame.contentArea)
    divider1:Dock(TOP)
    divider1:SetTall(3)
    divider1:DockMargin(0, 12, 0, 12) -- Equidistant spacing (12px above and below)
    divider1.Paint = function(self, w, h)
        PaintTaperedDivider(self, w, h)
    end

    local accessLabel = vgui.Create("DLabel", frame.contentArea)
    accessLabel:SetText("Access Level:")
    accessLabel:Dock(TOP)
    accessLabel:DockMargin(12, 8, 12, 4)
    accessLabel:SetTextColor(LOCK_COLOR_TEXT)
    accessLabel:SetFont(LOCK_FONT_TERTIARY)
    accessLabel:SizeToContents()

    local accessCombo = vgui.Create("DComboBox", frame.contentArea)
    accessCombo:Dock(TOP)
    accessCombo:DockMargin(12, 0, 12, 4)
    accessCombo:SetValue("User")
    accessCombo:AddChoice("User")
    accessCombo:AddChoice("Manager")
    if (canPrintInstaller) then
        accessCombo:AddChoice("Master")
    end
    accessCombo:SetTall(25)
    StyleComboBox(accessCombo)

    -- Divider between access level dropdown and card name
    local divider2 = vgui.Create("DPanel", frame.contentArea)
    divider2:Dock(TOP)
    divider2:SetTall(3)
    divider2:DockMargin(0, 4, 0, 4)
    divider2.Paint = function(self, w, h)
        PaintTaperedDivider(self, w, h)
    end

    local nameLabel = vgui.Create("DLabel", frame.contentArea)
    nameLabel:SetText("Card Name:")
    nameLabel:Dock(TOP)
    nameLabel:DockMargin(12, 4, 12, 4)
    nameLabel:SetTextColor(LOCK_COLOR_TEXT)
    nameLabel:SetFont(LOCK_FONT_TERTIARY)
    nameLabel:SizeToContents()

    local nameEntry = vgui.Create("ixLockTextEntry", frame.contentArea)
    nameEntry:Dock(TOP)
    nameEntry:DockMargin(12, 0, 12, 4)
    nameEntry:SetPlaceholderText("Enter card name (optional)")
    nameEntry:SetTall(25)
    
    -- Ensure text entry can receive focus
    timer.Simple(0.1, function()
        if (IsValid(nameEntry)) then
            nameEntry:RequestFocus()
        end
    end)

    -- Split bottom buttons: Back (left half) and Print (right half)
    local back = CreateLockButton(frame.buttonArea, "Back", function()
        frame:Close()
        -- Reopen the config menu
        if (IsValid(door)) then
            net.Start("ixDoorLocks_RequestMenu")
                net.WriteEntity(door)
            net.SendToServer()
        end
    end, "primary")
    back:Dock(LEFT)
    back:SetWide(frame:GetWide() * 0.5)
    back:DockMargin(0, 0, 0, 0)

    local confirm = CreateLockButton(frame.buttonArea, "Print", function()
        local cardType = string.lower(accessCombo:GetSelected() or accessCombo:GetValue() or "user")
        local cardName = nameEntry:GetText() or ""
        net.Start("ixDoorLocks_KeycardPrintConfirm")
            net.WriteString(lockID)
            net.WriteString(cardType)
            net.WriteString(cardName)
        net.SendToServer()
        -- Refresh the print menu instead of closing
        frame:Close()
        timer.Simple(0.1, function()
            net.Start("ixDoorLocks_DoAction")
                net.WriteString("mode_action")
                net.WriteString(lockID)
            net.SendToServer()
        end)
    end, "primary")
    confirm:Dock(RIGHT)
    confirm:SetWide(frame:GetWide() * 0.5)
    confirm:DockMargin(0, 0, 0, 0)
end)

-- Keycard view menu
net.Receive("ixDoorLocks_KeycardView", function()
    local lockID = net.ReadString()
    local door = net.ReadEntity() -- Door entity for Back button
    local isMaster = net.ReadBool() -- Changed from isInstaller to isMaster
    local userKeyUID = net.ReadString() -- User's keyUID to prevent self-disable
    local cards = net.ReadTable()

    -- Close existing menu if open
    if (IsValid(activeKeycardMenu)) then
        activeKeycardMenu:Close()
        activeKeycardMenu = nil
    end

    local frame = vgui.Create("ixLockMenu")
    frame:SetEntity(door)
    frame:SetHeaderText("Keycard List")
    frame:SetSize(735, 470) -- 25% wider than previous (588 * 1.25 = 735)
    frame:PositionFromEntity()
    frame:MakePopup()
    
    -- Store reference and clean up on close
    activeKeycardMenu = frame
    function frame:OnClose()
        if (activeKeycardMenu == self) then
            activeKeycardMenu = nil
        end
    end

    local scroll = vgui.Create("DScrollPanel", frame.contentArea)
    scroll:Dock(FILL)
    scroll:DockMargin(12, 12, 12, 12)

    for _, card in ipairs(cards) do
        local panel = vgui.Create("DPanel", scroll)
        panel:Dock(TOP)
        panel:SetHeight(40)
        panel:DockMargin(0, 0, 0, 4)

        local cardName = card.cardName and card.cardName ~= "" and card.cardName or ""
        local displayName = string.format("Serial %d", card.serialNumber)
        if (cardName ~= "") then
            displayName = displayName .. " - " .. cardName
        end
        
        -- Handle old "installer" type as "master" for display
        local cardType = card.cardType == "installer" and "master" or card.cardType
        local typeName = string.upper(string.sub(cardType, 1, 1)) .. string.sub(cardType, 2)
        
        -- Color coding for tiers
        local tierColor = Color(255, 255, 255) -- Default white
        if (cardType == "master") then
            tierColor = Color(255, 215, 0) -- Gold for master
        elseif (cardType == "manager") then
            tierColor = Color(100, 149, 237) -- Cornflower blue for manager
        else
            tierColor = Color(200, 200, 200) -- Light gray for user
        end
        
        displayName = displayName .. " (" .. typeName .. ")"

        local label = vgui.Create("DLabel", panel)
        label:Dock(LEFT)
        label:SetText(displayName)
        label:SetTextColor(tierColor)
        label:SetFont(LOCK_FONT_TERTIARY)
        label:SizeToContents()
        label:DockMargin(8, 0, 0, 0)

        local statusLabel = vgui.Create("DLabel", panel)
        statusLabel:Dock(LEFT)
        statusLabel:SetText(card.active and " [Active]" or " [Inactive]")
        statusLabel:SetTextColor(card.active and Color(0, 255, 0) or Color(255, 0, 0))
        statusLabel:SetFont(LOCK_FONT_TERTIARY)
        statusLabel:SizeToContents()
        statusLabel:DockMargin(8, 0, 0, 0)
        
        -- Show [GROUP] marker for keycards from other locks in the group
        if (card.isFromGroup) then
            local groupLabel = vgui.Create("DLabel", panel)
            groupLabel:Dock(LEFT)
            groupLabel:SetText(" [GROUP]")
            groupLabel:SetTextColor(Color(255, 20, 147)) -- Hot pink
            groupLabel:SetFont(LOCK_FONT_TERTIARY)
            groupLabel:SizeToContents()
            groupLabel:DockMargin(8, 0, 0, 0)
        end

        -- Handle old "installer" type as "master"
        local cardType = card.cardType == "installer" and "master" or card.cardType
        
        -- Prevent disabling your own card
        local isSelfCard = (card.keyUID == userKeyUID)
        
        -- Button container for right-aligned buttons
        local buttonContainer = vgui.Create("DPanel", panel)
        buttonContainer:Dock(RIGHT)
        buttonContainer:SetWide(250) -- Space for both buttons with margin (increased for wider deactivate button)
        buttonContainer:SetMouseInputEnabled(true) -- Enable mouse input for buttons
        buttonContainer.Paint = function() end -- Invisible
        
        -- Deactivate/Reactivate button (20% wider: 108 * 1.2 = 130)
        local actionBtn = CreateLockButton(buttonContainer, card.active and "Deactivate" or "Reactivate", function()
            local action = card.active and "deactivate" or "reactivate"
            net.Start("ixDoorLocks_KeycardManage")
                net.WriteString(lockID)
                net.WriteString(card.keyUID)
                net.WriteString(action)
            net.SendToServer()
        end, "secondary", {width = 130}) -- 20% wider (108 * 1.2 = 130)
        actionBtn:Dock(RIGHT)
        actionBtn:DockMargin(0, 0, 4, 0)
        actionBtn:SetContentAlignment(5) -- Center text
        
        -- Only master card holders can reactivate
        if (not card.active) then
            actionBtn:SetEnabled(isMaster) -- Only master card holders can reactivate
        else
            -- Masters can deactivate other masters and managers, but not themselves
            if (isSelfCard) then
                actionBtn:SetEnabled(false) -- Cannot deactivate your own card
            elseif (cardType == "master" or cardType == "manager") then
                actionBtn:SetEnabled(isMaster) -- Only masters can deactivate master/manager cards
            else
                actionBtn:SetEnabled(isMaster) -- Only masters can deactivate user cards
            end
        end
        
        -- Delete button (only for masters, cannot delete own card, cannot delete group cards)
        if (isMaster and not isSelfCard and not card.isFromGroup) then
            local deleteBtn = CreateLockButton(buttonContainer, "Delete", function()
                -- Confirmation dialog
                local confirmFrame = vgui.Create("ixLockMenu")
                confirmFrame:SetEntity(door)
                confirmFrame:SetHeaderText("Delete Keycard")
                confirmFrame:SetSize(400, 180)
                confirmFrame:PositionFromEntity()
                confirmFrame:MakePopup()
                
                local warningLabel = vgui.Create("DLabel", confirmFrame.contentArea)
                warningLabel:Dock(TOP)
                warningLabel:DockMargin(12, 12, 12, 8)
                warningLabel:SetText("Are you sure you want to permanently delete this keycard?\n\nThis action cannot be undone.")
                warningLabel:SetTextColor(LOCK_COLOR_TEXT)
                warningLabel:SetFont(LOCK_FONT_TERTIARY)
                warningLabel:SetWrap(true)
                warningLabel:SetAutoStretchVertical(true)
                
                -- Cancel button on the left
                local cancelBtn = CreateLockButton(confirmFrame.buttonArea, "Cancel", function()
                    confirmFrame:Close()
                end, "primary")
                cancelBtn:Dock(LEFT)
                cancelBtn:DockMargin(0, 0, 0, 0)
                function cancelBtn:PerformLayout()
                    self:SetWide(self:GetParent():GetWide() * 0.5)
                end
                
                -- Confirm button on the right
                local confirmBtn = CreateLockButton(confirmFrame.buttonArea, "Delete", function()
                    net.Start("ixDoorLocks_KeycardManage")
                        net.WriteString(lockID)
                        net.WriteString(card.keyUID)
                        net.WriteString("delete")
                    net.SendToServer()
                    confirmFrame:Close()
                end, "primary")
                confirmBtn:Dock(FILL)
                confirmBtn:DockMargin(0, 0, 0, 0)
            end, "secondary", {width = 108})
            deleteBtn:Dock(RIGHT)
            deleteBtn:DockMargin(0, 0, 0, 0)
            deleteBtn:SetContentAlignment(5) -- Center text
        end
    end

    -- Split bottom buttons: Back (left half) and Close (right half)
    local back = CreateLockButton(frame.buttonArea, "Back", function()
        frame:Close()
        -- Request main menu again by sending the door entity
        if (IsValid(door)) then
            net.Start("ixDoorLocks_RequestMenu")
                net.WriteEntity(door)
            net.SendToServer()
        end
    end, "primary")
    back:Dock(LEFT)
    back:SetWide(frame:GetWide() * 0.5)
    back:DockMargin(0, 0, 0, 0)

    local close = CreateLockButton(frame.buttonArea, "Close", function()
        frame:Close()
    end, "primary")
    close:Dock(RIGHT)
    close:SetWide(frame:GetWide() * 0.5)
    close:DockMargin(0, 0, 0, 0)
end)

-- Story card print menu
net.Receive("ixDoorLocks_KeycardStoryMenu", function()
    local lockID = net.ReadString()
    local door = net.ReadEntity() or nil -- Try to get door if available

    -- Close existing menu if open
    if (IsValid(activeStoryCardMenu)) then
        activeStoryCardMenu:Close()
        activeStoryCardMenu = nil
    end

    local frame = vgui.Create("ixLockMenu")
    if (IsValid(door)) then
        frame:SetEntity(door)
    end
    frame:SetHeaderText("Print Story Card")
    frame:SetSize(320, 300)
    if (IsValid(door)) then
        frame:PositionFromEntity()
    else
        frame:Center()
    end
    frame:MakePopup()
    
    -- Store reference and clean up on close
    activeStoryCardMenu = frame
    function frame:OnClose()
        if (activeStoryCardMenu == self) then
            activeStoryCardMenu = nil
        end
    end

    local typeLabel = vgui.Create("DLabel", frame.contentArea)
    typeLabel:SetText("Story Card Type:")
    typeLabel:Dock(TOP)
    typeLabel:DockMargin(12, 12, 12, 4)
    typeLabel:SetTextColor(LOCK_COLOR_TEXT)
    typeLabel:SetFont(LOCK_FONT_TERTIARY)
    typeLabel:SizeToContents()

    local typeCombo = vgui.Create("DComboBox", frame.contentArea)
    typeCombo:Dock(TOP)
    typeCombo:DockMargin(12, 0, 12, 4)
    typeCombo:SetValue("Air Key")
    typeCombo:AddChoice("Air Key")
    typeCombo:AddChoice("Earth Key")
    typeCombo:AddChoice("Fire Key")
    typeCombo:AddChoice("Water Key")
    typeCombo:AddChoice("Gold Key")
    typeCombo:SetTall(25)
    StyleComboBox(typeCombo)

    local confirm = CreateLockButton(frame.buttonArea, "Print Story Card", function()
        local selected = typeCombo:GetSelected() or typeCombo:GetValue() or "Air Key"
        local storyCardType = string.lower(string.match(selected, "^(%w+)")) -- Extract first word and lowercase
        net.Start("ixDoorLocks_KeycardStoryConfirm")
            net.WriteString(lockID)
            net.WriteString(storyCardType)
        net.SendToServer()
        frame:Close()
    end, "primary")
    confirm:Dock(FILL)
    confirm:DockMargin(12, 8, 12, 8)
end)

-- R key handler for doors with locks (reload key to open lock menu - double tap only)
-- Track last R key press/release time for double-tap detection
local lastReloadPress = 0
local lastReloadRelease = 0
local lastReloadAction = 0 -- Track last action time to prevent spam
local RELOAD_DOUBLE_TAP_TIME = 0.3 -- 300ms window for double-tap
local RELOAD_DEBOUNCE_TIME = 0.1 -- 100ms debounce to prevent spam

-- Track press time to detect quick taps vs holds
hook.Add("KeyPress", "ixDoorLocks_ReloadKeyPress", function(client, key)
    if (key ~= IN_RELOAD) then return end
    if (not IsValid(client) or client ~= LocalPlayer()) then return end
    
    lastReloadPress = CurTime()
end)

-- Handle releases to detect double-tap for config menu or close menu
hook.Add("KeyRelease", "ixDoorLocks_ReloadKeyRelease", function(client, key)
    if (key ~= IN_RELOAD) then return end
    if (not IsValid(client) or client ~= LocalPlayer()) then return end

    local currentTime = CurTime()
    
    -- Debounce to prevent spam
    if (currentTime - lastReloadAction < RELOAD_DEBOUNCE_TIME) then
        return
    end

    local timeSinceLastRelease = currentTime - lastReloadRelease
    
    -- Check if this is a double-tap (within 300ms)
    if (timeSinceLastRelease < RELOAD_DOUBLE_TAP_TIME and timeSinceLastRelease > 0) then
        -- Double-tap: check if any menu is open, if so close it, otherwise open config menu
        local anyMenuOpen = CloseAllMenus()
        
        -- If no menu was open, try to open config menu
        if (not anyMenuOpen) then
            local trace = client:GetEyeTrace()
            if (trace and trace.Hit) then
                local door = trace.Entity
                if (IsValid(door) and door:IsDoor()) then
                    net.Start("ixDoorLocks_RequestMenu")
                        net.WriteEntity(door)
                    net.SendToServer()
                end
            end
        end
        
        lastReloadRelease = 0 -- Reset to prevent triple-tap
        lastReloadAction = currentTime
    else
        -- Single tap - do nothing (quick toggle removed for now)
        lastReloadRelease = currentTime
    end
end)

-- Knock-to-Toggle: Client-side handlers for opening code entry UIs directly
-- Handler for code entry UI (for code locks)
net.Receive("ixDoorLocks_OpenCodeEntry", function()
    local door = net.ReadEntity()
    local lockID = net.ReadString()
    
    if (not IsValid(door)) then return end
    
    -- Create code entry frame directly (same as button click does)
    local codeFrame = vgui.Create("ixLockMenu")
    if (not IsValid(codeFrame)) then return end
    
    codeFrame:SetEntity(door)
    codeFrame:SetHeaderText("Enter Code")
    codeFrame:SetSize(280, 140)
    codeFrame:PositionFromEntity()
    codeFrame:MakePopup()
    
    local entry = vgui.Create("DTextEntry", codeFrame.contentArea)
    if (IsValid(entry)) then
        entry:Dock(TOP)
        entry:DockMargin(12, 12, 12, 8)
        entry:SetPlaceholderText("Code")
        entry:SetTall(25)
    end
    
    local ok = CreateLockButton(codeFrame.buttonArea, "Submit", function()
        local code = entry and entry:GetText() or ""
        net.Start("ixDoorLocks_SubmitCode")
            net.WriteString(lockID)
            net.WriteString("unlock")
            net.WriteString(code)
        net.SendToServer()
        codeFrame:Close()
    end, "primary")
    ok:Dock(FILL)
    ok:DockMargin(12, 8, 12, 8)
end)

-- Handler for override code entry UI (for keycard locks)
net.Receive("ixDoorLocks_OpenOverrideCodeEntry", function()
    local door = net.ReadEntity()
    local lockID = net.ReadString()
    local isLocked = net.ReadBool()
    
    if (not IsValid(door)) then return end
    
    -- Create override code entry frame directly (same as button click does)
    local codeFrame = vgui.Create("ixLockMenu")
    if (not IsValid(codeFrame)) then return end
    
    codeFrame:SetEntity(door)
    codeFrame:SetHeaderText("Override Code")
    codeFrame:SetSize(280, 160)
    codeFrame:PositionFromEntity()
    codeFrame:MakePopup()
    
    local entry = vgui.Create("ixLockTextEntry", codeFrame.contentArea)
    if (not IsValid(entry)) then
        -- Fallback to DTextEntry if ixLockTextEntry doesn't exist
        entry = vgui.Create("DTextEntry", codeFrame.contentArea)
    end
    if (IsValid(entry)) then
        entry:Dock(TOP)
        entry:DockMargin(12, 12, 12, 8)
        entry:SetPlaceholderText("Override Code")
        entry:SetTall(27)
    end
    
    -- Back button on the left
    local backBtn = CreateLockButton(codeFrame.buttonArea, "Back", function()
        codeFrame:Close()
    end, "primary")
    backBtn:Dock(LEFT)
    backBtn:DockMargin(0, 0, 0, 0)
    function backBtn:PerformLayout()
        self:SetWide(self:GetParent():GetWide() * 0.5)
    end
    
    -- Submit button on the right
    local submitBtn = CreateLockButton(codeFrame.buttonArea, "Submit", function()
        local code = entry and entry:GetText() or ""
        net.Start("ixDoorLocks_SubmitOverrideCode")
            net.WriteString(lockID)
            net.WriteString(isLocked and "unlock" or "lock")
            net.WriteString(code)
        net.SendToServer()
        codeFrame:Close()
    end, "primary")
    submitBtn:Dock(FILL)
    submitBtn:DockMargin(0, 0, 0, 0)
end)




