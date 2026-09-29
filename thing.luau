--[[
    Win95.lua
    =========
    A faithful Windows 95/98 UI library for Roblox, in a single file.

    Designed for exploit UIs, but runs anywhere a LocalScript can run
    (StarterPlayerScripts, StarterGui, plugin context, ...). It parents
    everything into CoreGui when available and falls back to PlayerGui.

    ------------------------------------------------------------------
    Quick start
    ------------------------------------------------------------------
        local Win95 = loadstring(game:HttpGet(".../Win95.lua"))()
        -- or: local Win95 = require(script.Win95)

        local win = Win95.Window({
            Title = "My Application",
            Size  = UDim2.fromOffset(420, 320),
        })

        Win95.Button({
            Text = "OK",
            Parent = win.Content,
            Position = UDim2.fromOffset(12, 12),
            OnClick = function() print("clicked") end,
        })

    ------------------------------------------------------------------
    Design notes
    ------------------------------------------------------------------
    * Authentic look: layered 1px bevels, canonical gray (#C0C0C0),
      navy title bars, MS-Sans-Serif-style bitmap font, dotted drag
      outlines, segmented progress bars, sunken fields.
    * Every component returns a small object with :Destroy() and
      (usually) :Get()/:Set() accessors. Windows also return :Close().
    * All event connections are tracked per-component and disconnected
      on Destroy — no leaks when you create/destroy UI at runtime.
    * All input handling (dragging, sliders, scrollbars) supports both
      mouse and touch.
    * Thread-safe callbacks: every user callback is wrapped in pcall.

    ------------------------------------------------------------------
    Components
    ------------------------------------------------------------------
        Win95.Window(opts)         -> window with title bar, drag, close
        Win95.Button(opts)         -> push button (default / disabled OK)
        Win95.Checkbox(opts)       -> check box with label
        Win95.RadioButton(opts)    -> radio button with label
        Win95.Slider(opts)         -> horizontal slider w/ tick marks
        Win95.ProgressBar(opts)    -> segmented or smooth bar
        Win95.Label(opts)          -> static text
        Win95.GroupBox(opts)       -> etched group frame w/ title notch
        Win95.TextBox(opts)        -> sunken text field (optional label)
        Win95.ListBox(opts)        -> scrollable selection list
        Win95.StatusBar(opts)      -> paneled status strip (auto-dock)
        Win95.TabStrip(opts)       -> tab control w/ page switching

    Shared option keys:
        Parent   : where to put it (for windows: ignored, see ParentGui)
        Position : UDim2
        Size     : UDim2
        Visible  : bool
        ZIndex   : number   (base z-layer; children stack above)

    Window-specific options:
        Title                      : string
        Draggable                  : bool (default true)
        ShowContentsWhileDragging  : bool (default false -> dotted outline)
        Closable                   : bool (default true)
        OnClose                    : function()
        ParentGui                  : Instance (default: auto CoreGui/PlayerGui)

    See each constructor's comment block for its full options.

    ------------------------------------------------------------------
    Utilities
    ------------------------------------------------------------------
        Win95.Colors          : the palette
        Win95.SetFont(path)   : use a custom TTF (e.g. MS Sans Serif)
        Win95.DefaultParent() : the gui host all windows attach to
        Win95.Version         : string
]]

local Win95 = {}
Win95.Version = "1.0.0"

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

--====================================================================
-- PALETTE (canonical Win95 system colors)
--====================================================================
local C = {
    Face      = Color3.fromRGB(192, 192, 192), -- window / button face
    LightHi   = Color3.fromRGB(255, 255, 255), -- raised top-left highlight
    LightSh   = Color3.fromRGB(223, 223, 223), -- raised inner highlight
    DarkSh    = Color3.fromRGB(128, 128, 128), -- sunken top-left shadow
    Darkest   = Color3.fromRGB(0, 0, 0),       -- sunken outer shadow
    TitleBar  = Color3.fromRGB(0, 0, 128),     -- active title bar
    TitleText = Color3.fromRGB(255, 255, 255),
    Text      = Color3.fromRGB(0, 0, 0),
    TextDis   = Color3.fromRGB(128, 128, 128), -- disabled text
    FieldBg   = Color3.fromRGB(255, 255, 255), -- sunken edit fields
    Select    = Color3.fromRGB(0, 0, 128),     -- selection highlight
    SelectTxt = Color3.fromRGB(255, 255, 255),
    Desktop   = Color3.fromRGB(0, 128, 128),   -- classic teal desktop
}
Win95.Colors = C

--====================================================================
-- FONT
--====================================================================
-- Ships with the closest built-in match. Call Win95.SetFont(path)
-- before creating components to use a custom font, e.g.:
--     Win95.SetFont("win95/ms_sans_serif.ttf")   -- exploit workspace
--     Win95.SetFont("rbxassetid://123456789")    -- uploaded font
local FONT = Enum.Font.Legacy
local FONT_SIZE = 12
local BOLD = Enum.Font.LegacyBold

--- Provide a custom font. `path` may be a workspace-relative file
--- (exploit environments), an rbxassetid:// string, or an rbxasset://
--- string. Returns true on success.
function Win95.SetFont(path)
    local resolved = path

    -- If it's a workspace file and we're in an exploit environment,
    -- convert it to a custom-asset URL.
    if not path:find("^rbxasset") and getcustomasset and isfile and isfile(path) then
        resolved = getcustomasset(path)
    end

    local ok = pcall(function()
        FONT = Font.new(resolved)
        BOLD = Font.new(resolved, Enum.FontWeight.Bold, Enum.FontStyle.Normal)
    end)
    if not ok then
        warn("[Win95] Failed to load font:", path)
        return false
    end
    return true
end

local function styleText(gui)
    gui.FontFace = FONT
    gui.TextSize = FONT_SIZE
    gui.TextColor3 = C.Text
    gui.TextXAlignment = Enum.TextXAlignment.Left
    gui.TextYAlignment = Enum.TextYAlignment.Center
    gui.BackgroundTransparency = 1
    gui.BorderSizePixel = 0
end

--====================================================================
-- INTERNAL HELPERS
--====================================================================

-- Roblox ZIndex is shared per-ScreenGui (Sibling behavior), so every
-- component gets a high base layer and stacks children above it.
local Z_BASE = 10

--- Instance.new with a property table. Parent is applied last.
local function new(class, props)
    local inst = Instance.new(class)
    local parent
    for k, v in pairs(props or {}) do
        if k == "Parent" then
            parent = v
        else
            inst[k] = v
        end
    end
    if parent then inst.Parent = parent end
    return inst
end

--- Component bookkeeping: owns its Instance, child components and a
--- list of connections that are all torn down by Destroy().
local function component(inst)
    local comp = {
        Instance = inst,
        _children = {},
        _connections = {},
    }
    function comp:_track(connection)
        table.insert(self._connections, connection)
        return connection
    end
    function comp:_addChild(child)
        table.insert(self._children, child)
        return child
    end
    function comp:_unparent()
        for _, c in ipairs(self._children) do
            if c.Destroy then pcall(c.Destroy, c) end
        end
        self._children = {}
    end
    function comp:Destroy()
        if self._destroyed then return end
        self._destroyed = true
        self:_unparent()
        for _, cn in ipairs(self._connections) do
            cn:Disconnect()
        end
        self._connections = {}
        if self.Instance and self.Instance.Parent then
            self.Instance:Destroy()
        end
    end
    return comp
end

--- Call a user callback safely.
local function fire(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, err = pcall(fn, ...)
    if not ok then warn("[Win95] callback error:", err) end
end

--- Best gui host for new windows: CoreGui in exploit environments,
--- PlayerGui everywhere else.
local function defaultGuiHost()
    -- gethui() (if present) is preferred by most executors
    if gethui then
        local ok, h = pcall(gethui)
        if ok and h then return h end
    end
    -- CoreGui, if we're actually allowed to write to it
    local ok, host = pcall(function()
        local cg = game:GetService("CoreGui")
        local test = Instance.new("Folder")
        test.Parent = cg
        test:Destroy()
        return cg
    end)
    if ok and host then return host end
    local player = Players.LocalPlayer
    if player then return player:WaitForChild("PlayerGui") end
    return game:GetService("StarterGui")
end
Win95.DefaultParent = defaultGuiHost

--====================================================================
-- BEVELS
--====================================================================
-- mode: "raised" | "sunken" | "thin-raised" | "thin-sunken" | "groove"
-- Returns an array of the border frames (so they can be redrawn).
local function bevel(parent, mode)
    mode = mode or "raised"
    local layers
    if mode == "raised" or mode == "sunken" then
        layers = {
            { 0, mode == "raised" and C.LightHi or C.DarkSh,  mode == "raised" and C.DarkSh  or C.LightHi },
            { 1, mode == "raised" and C.LightSh or C.Darkest, mode == "raised" and C.Darkest or C.LightSh },
        }
    elseif mode == "thin-raised" or mode == "thin-sunken" then
        layers = {
            { 0, mode == "thin-raised" and C.LightHi or C.DarkSh,
                 mode == "thin-raised" and C.Darkest or C.LightHi },
        }
    elseif mode == "groove" then
        layers = {
            { 0, C.DarkSh,  C.LightHi },
            { 1, C.LightHi, C.DarkSh },
        }
    else
        layers = {}
    end

    local frames = {}
    local z = (parent.ZIndex or 0) + 1
    for i, L in ipairs(layers) do
        local inset, tl, br = L[1], L[2], L[3]
        frames[#frames + 1] = new("Frame", {
            Name = "BevelT" .. i, BackgroundColor3 = tl, BorderSizePixel = 0,
            Position = UDim2.new(0, inset, 0, inset),
            Size = UDim2.new(1, -inset * 2, 0, 1), ZIndex = z + i, Parent = parent,
        })
        frames[#frames + 1] = new("Frame", {
            Name = "BevelL" .. i, BackgroundColor3 = tl, BorderSizePixel = 0,
            Position = UDim2.new(0, inset, 0, inset),
            Size = UDim2.new(0, 1, 1, -inset * 2), ZIndex = z + i, Parent = parent,
        })
        frames[#frames + 1] = new("Frame", {
            Name = "BevelB" .. i, BackgroundColor3 = br, BorderSizePixel = 0,
            Position = UDim2.new(0, inset, 1, -inset - 1),
            Size = UDim2.new(1, -inset * 2, 0, 1), ZIndex = z + i, Parent = parent,
        })
        frames[#frames + 1] = new("Frame", {
            Name = "BevelR" .. i, BackgroundColor3 = br, BorderSizePixel = 0,
            Position = UDim2.new(1, -inset - 1, 0, inset),
            Size = UDim2.new(0, 1, 1, -inset * 2), ZIndex = z + i, Parent = parent,
        })
    end
    return frames
end

--- Redraw helper: destroy old bevel frames and draw a new mode.
local function rebevel(frames, parent, mode)
    for _, f in ipairs(frames) do f:Destroy() end
    return bevel(parent, mode)
end

--====================================================================
-- DRAG OUTLINE (dotted Win95-style rectangle)
--====================================================================
local function makeDragOutline(parent)
    local root = new("Frame", {
        Name = "DragOutline", BackgroundTransparency = 1, BorderSizePixel = 0,
        Visible = false, ZIndex = 99999, Parent = parent,
    })

    local DASH = 2

    local function side(name, pos, size, horizontal)
        return new("Frame", {
            Name = name, BackgroundTransparency = 1, BorderSizePixel = 0,
            Position = pos, Size = size, ClipsDescendants = true,
            ZIndex = 99999, Parent = root,
        }), horizontal
    end

    local sides = {}
    local top,    hTop    = side("Top",    UDim2.new(0, 0, 0, 0),          UDim2.new(1, 0, 0, 1), true)
    local bottom, hBottom = side("Bottom", UDim2.new(0, 0, 1, -1),          UDim2.new(1, 0, 0, 1), true)
    local left,   hLeft   = side("Left",   UDim2.new(0, 0, 0, 0),          UDim2.new(0, 1, 1, 0), false)
    local right,  hRight  = side("Right",  UDim2.new(1, -1, 0, 0),         UDim2.new(0, 1, 1, 0), false)
    sides = { {top, hTop}, {bottom, hBottom}, {left, hLeft}, {right, hRight} }

    local function rebuild()
        for _, s in ipairs(sides) do
            local holder, horizontal = s[1], s[2]
            for _, ch in ipairs(holder:GetChildren()) do ch:Destroy() end
            local length = horizontal and holder.AbsoluteSize.X or holder.AbsoluteSize.Y
            for offset = 0, math.max(0, length - 1), DASH * 2 do
                if horizontal then
                    new("Frame", {
                        BackgroundColor3 = C.Text, BorderSizePixel = 0,
                        Size = UDim2.new(0, DASH, 1, 0),
                        Position = UDim2.new(0, offset, 0, 0),
                        ZIndex = 99999, Parent = holder,
                    })
                else
                    new("Frame", {
                        BackgroundColor3 = C.Text, BorderSizePixel = 0,
                        Size = UDim2.new(1, 0, 0, DASH),
                        Position = UDim2.new(0, 0, 0, offset),
                        ZIndex = 99999, Parent = holder,
                    })
                end
            end
        end
    end

    root:GetPropertyChangedSignal("AbsoluteSize"):Connect(rebuild)
    task.defer(rebuild)

    return {
        Instance = root,
        Show = function(pos, size)
            if pos then root.Position = pos end
            if size then root.Size = size end
            root.Visible = true
            task.defer(rebuild)
        end,
        Hide = function() root.Visible = false end,
        Destroy = function() root:Destroy() end,
    }
end

--====================================================================
-- WINDOW
--====================================================================
--[[
    Win95.Window(opts) -> window

    opts:
        Title                     string   default "Window"
        Size                      UDim2    default 400x300
        Position                  UDim2    default screen center
        Draggable                 bool     default true
        ShowContentsWhileDragging bool     default false (dotted outline)
        Closable                  bool     default true
        OnClose                   function called when the window closes
        ParentGui                 Instance host gui (default auto)

    returns:
        .Instance   the window frame
        .Gui        the ScreenGui wrapping it
        .Content    frame for placing children (inside the bevels)
        :SetTitle(text)
        :SetPosition(pos) / :SetSize(size)
        :Focus()    bring to front of all Win95 windows
        :Close() / :Destroy()
]]
local windowRegistry = {} -- for focus/z ordering
local zTop = Z_BASE

function Win95.Window(opts)
    opts = opts or {}

    local gui = new("ScreenGui", {
        Name = "Win95_" .. (opts.Title or "Window"),
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = opts.DisplayOrder or 1,
        Parent = opts.ParentGui or defaultGuiHost(),
    })

    local size = opts.Size or UDim2.fromOffset(400, 300)
    local frame = new("Frame", {
        Name = "Window",
        Size = size,
        Position = opts.Position or UDim2.new(0.5, -size.X.Offset / 2, 0.5, -size.Y.Offset / 2),
        BackgroundColor3 = C.Face, BorderSizePixel = 0,
        ZIndex = Z_BASE, Parent = gui,
    })
    local bevels = bevel(frame, "raised")

    local win = component(frame)
    win.Gui = gui

    -- Title bar -----------------------------------------------------
    local titleBar = new("Frame", {
        Name = "TitleBar",
        Size = UDim2.new(1, -6, 0, 20),
        Position = UDim2.new(0, 3, 0, 3),
        BackgroundColor3 = C.TitleBar, BorderSizePixel = 0,
        ZIndex = Z_BASE + 3, Parent = frame,
    })

    local titleLbl = new("TextLabel", {
        Name = "Title",
        Size = UDim2.new(1, -46, 1, 0),
        Position = UDim2.new(0, 4, 0, 0),
        Text = opts.Title or "Window",
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = Z_BASE + 4, Parent = titleBar,
    })
    styleText(titleLbl)
    titleLbl.TextColor3 = C.TitleText

    -- Close button ---------------------------------------------------
    if opts.Closable ~= false then
        local close = new("TextButton", {
            Name = "Close",
            Size = UDim2.fromOffset(18, 16),
            Position = UDim2.new(1, -21, 0, 2),
            BackgroundColor3 = C.Face, BorderSizePixel = 0,
            Text = "", AutoButtonColor = false,
            ZIndex = Z_BASE + 5, Parent = titleBar,
        })
        local closeBevels = bevel(close, "raised")

        -- the classic X glyph
        local g1 = new("Frame", {
            Size = UDim2.fromOffset(9, 2), Position = UDim2.fromOffset(4, 7),
            Rotation = 45, BackgroundColor3 = C.Text, BorderSizePixel = 0,
            ZIndex = Z_BASE + 7, Parent = close,
        })
        local g2 = new("Frame", {
            Size = UDim2.fromOffset(9, 2), Position = UDim2.fromOffset(4, 7),
            Rotation = -45, BackgroundColor3 = C.Text, BorderSizePixel = 0,
            ZIndex = Z_BASE + 7, Parent = close,
        })

        local function drawClose(down)
            closeBevels = rebevel(closeBevels, close, down and "sunken" or "raised")
            local off = down and 1 or 0
            g1.Position = UDim2.fromOffset(4 + off, 7 + off)
            g2.Position = UDim2.fromOffset(4 + off, 7 + off)
        end

        local down = false
        win:_track(close.MouseButton1Down:Connect(function()
            down = true; drawClose(true)
        end))
        win:_track(close.MouseButton1Up:Connect(function()
            if down then down = false; drawClose(false) end
        end))
        win:_track(close.MouseLeave:Connect(function()
            if down then down = false; drawClose(false) end
        end))
        win:_track(close.Activated:Connect(function()
            win:Close()
        end))
    end

    -- Content area ----------------------------------------------------
    local content = new("Frame", {
        Name = "Content",
        Size = UDim2.new(1, -12, 1, -31),
        Position = UDim2.new(0, 6, 0, 26),
        BackgroundTransparency = 1, BorderSizePixel = 0,
        ZIndex = Z_BASE + 3, Parent = frame,
    })
    win.Content = content

    -- Focus (bring to front) ------------------------------------------
    table.insert(windowRegistry, win)
    function win:Focus()
        if win._destroyed then return end
        zTop = zTop + 100
        gui.DisplayOrder = zTop
    end
    win:_track(frame.InputBegan:Connect(function()
        win:Focus()
    end))

    -- Close / destroy ---------------------------------------------------
    win._onClose = opts.OnClose
    function win:Close()
        if win._closed then return end
        win._closed = true
        fire(win._onClose)
        win:Destroy()
        for i, w in ipairs(windowRegistry) do
            if w == win then table.remove(windowRegistry, i) break end
        end
    end
    local baseDestroy = win.Destroy
    function win:Destroy()
        baseDestroy(win)
        if gui.Parent then gui:Destroy() end
    end

    -- Dragging ------------------------------------------------------------
    if opts.Draggable ~= false then
        local outlineMode = opts.ShowContentsWhileDragging ~= true
        local outline = outlineMode and makeDragOutline(gui) or nil

        local dragging, dragStart, startPos, moved, shown = false

        win:_track(titleBar.InputBegan:Connect(function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseButton1
                and input.UserInputType ~= Enum.UserInputType.Touch then return end
            dragging, moved, shown = true, false, false
            dragStart = input.Position
            startPos = frame.Position
        end))

        win:_track(UIS.InputChanged:Connect(function(input)
            if not dragging then return end
            if input.UserInputType ~= Enum.UserInputType.MouseMovement
                and input.UserInputType ~= Enum.UserInputType.Touch then return end
            local d = input.Position - dragStart
            if not moved and math.abs(d.X) < 3 and math.abs(d.Y) < 3 then return end
            moved = true
            local newPos = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + d.X,
                startPos.Y.Scale, startPos.Y.Offset + d.Y
            )
            if outlineMode then
                -- hide contents, show dotted ghost
                if not shown then
                    shown = true
                    frame.BackgroundTransparency = 1
                    for _, f in ipairs(bevels) do f.Visible = false end
                    titleBar.BackgroundTransparency = 1
                    titleLbl.Visible = false
                    content.Visible = false
                    outline.Show(newPos, frame.Size)
                else
                    outline.Instance.Position = newPos
                end
            else
                frame.Position = newPos
            end
        end))

        win:_track(UIS.InputEnded:Connect(function(input)
            if not dragging then return end
            if input.UserInputType ~= Enum.UserInputType.MouseButton1
                and input.UserInputType ~= Enum.UserInputType.Touch then return end
            dragging = false
            if outlineMode and moved and shown then
                frame.Position = outline.Instance.Position
                outline.Hide()
                frame.BackgroundTransparency = 0
                for _, f in ipairs(bevels) do f.Visible = true end
                titleBar.BackgroundTransparency = 0
                titleLbl.Visible = true
                content.Visible = true
            end
        end))

        if outline then
            local baseClose = win.Close
            function win:Close()
                outline.Destroy()
                baseClose()
            end
        end
    end

    -- Public accessors
    function win:SetTitle(t) titleLbl.Text = tostring(t) end
    function win:GetTitle() return titleLbl.Text end
    function win:SetPosition(p) frame.Position = p end
    function win:SetSize(s) frame.Size = s end

    win:Focus()
    return win
end

--====================================================================
-- BUTTON
--====================================================================
--[[
    Win95.Button(opts)
        Text     string
        Size     UDim2  default 75x23 (the canonical size)
        Position UDim2
        Parent   Instance
        Enabled  bool    default true
        Default  bool    draws the extra "default button" black ring
        OnClick  function(btn)

    returns: .Instance, :SetText(t), :GetText(), :SetEnabled(b),
             :GetEnabled(), :Destroy()
]]
function Win95.Button(opts)
    opts = opts or {}
    local btn = new("TextButton", {
        Name = "Button",
        Size = opts.Size or UDim2.fromOffset(75, 23),
        Position = opts.Position or UDim2.new(),
        BackgroundColor3 = C.Face, BorderSizePixel = 0,
        Text = "", AutoButtonColor = false,
        ZIndex = (opts.ZIndex or Z_BASE) + 20,
        Visible = opts.Visible ~= false,
        Parent = opts.Parent,
    })
    local comp = component(btn)

    -- the extra black ring Win95 draws around the default button
    if opts.Default then
        new("UIStroke", {
            Color = C.Darkest, Thickness = 1,
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            Parent = btn,
        })
    end

    local label = new("TextLabel", {
        Name = "Label",
        Size = UDim2.new(1, -8, 1, -4),
        Position = UDim2.fromOffset(4, 2),
        Text = opts.Text or "Button",
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex = btn.ZIndex + 4, Parent = btn,
    })
    styleText(label)

    local enabled = opts.Enabled ~= false
    if not enabled then label.TextColor3 = C.TextDis end

    local bevels = bevel(btn, "raised")

    local function draw(down)
        bevels = rebevel(bevels, btn, down and "sunken" or "raised")
        label.Position = down and UDim2.fromOffset(5, 3) or UDim2.fromOffset(4, 2)
    end

    local pressed = false
    comp:_track(btn.MouseButton1Down:Connect(function()
        if not enabled then return end
        pressed = true; draw(true)
    end))
    comp:_track(btn.MouseButton1Up:Connect(function()
        if pressed then pressed = false; draw(false) end
    end))
    comp:_track(btn.MouseLeave:Connect(function()
        if pressed then pressed = false; draw(false) end
    end))
    comp:_track(btn.Activated:Connect(function()
        if enabled then fire(opts.OnClick, comp) end
    end))

    function comp:SetText(t) label.Text = tostring(t) end
    function comp:GetText() return label.Text end
    function comp:SetEnabled(e)
        enabled = e and true or false
        btn.AutoButtonColor = false
        label.TextColor3 = enabled and C.Text or C.TextDis
        if not enabled and pressed then pressed = false; draw(false) end
    end
    function comp:GetEnabled() return enabled end
    return comp
end

--====================================================================
-- CHECKBOX
--====================================================================
--[[
    Win95.Checkbox(opts)
        Text     string
        Position UDim2
        Size     UDim2   default 13 tall, auto width
        Parent   Instance
        Checked  bool
        OnChanged function(checked)

    returns: .Instance, :SetChecked(v), :GetChecked(), :SetText(t), :Destroy()
]]
function Win95.Checkbox(opts)
    opts = opts or {}
    local checked = opts.Checked == true

    local root = new("TextButton", {
        Name = "Checkbox",
        Size = opts.Size or UDim2.fromOffset(150, 16),
        Position = opts.Position or UDim2.new(),
        BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
        ZIndex = (opts.ZIndex or Z_BASE) + 20,
        Visible = opts.Visible ~= false,
        Parent = opts.Parent,
    })
    local comp = component(root)

    local box = new("Frame", {
        Size = UDim2.fromOffset(13, 13),
        Position = UDim2.fromOffset(0, 1),
        BackgroundColor3 = C.FieldBg, BorderSizePixel = 0,
        ZIndex = root.ZIndex + 1, Parent = root,
    })
    bevel(box, "sunken")

    -- Checkmark: two rotated bars make an authentic tick.
    local tick = new("Frame", {
        Name = "Tick", BackgroundTransparency = 1,
        Size = UDim2.new(1, 0, 1, 0), ZIndex = root.ZIndex + 3, Parent = box,
    })
    local t1 = new("Frame", {
        Size = UDim2.fromOffset(7, 2), Position = UDim2.fromOffset(1, 6),
        Rotation = 45, BackgroundColor3 = C.Text, BorderSizePixel = 0,
        ZIndex = root.ZIndex + 3, Parent = tick,
    })
    local t2 = new("Frame", {
        Size = UDim2.fromOffset(10, 2), Position = UDim2.fromOffset(3, 3),
        Rotation = -45, BackgroundColor3 = C.Text, BorderSizePixel = 0,
        ZIndex = root.ZIndex + 3, Parent = tick,
    })

    local label = new("TextLabel", {
        Size = UDim2.new(1, -20, 1, 0),
        Position = UDim2.fromOffset(18, 0),
        Text = opts.Text or "Checkbox",
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = root.ZIndex + 1, Parent = root,
    })
    styleText(label)

    local function render()
        tick.Visible = checked
    end
    render()

    comp:_track(root.Activated:Connect(function()
        checked = not checked
        render()
        fire(opts.OnChanged, checked)
    end))

    function comp:SetChecked(v)
        checked = v and true or false
        render()
    end
    function comp:GetChecked() return checked end
    function comp:SetText(t) label.Text = tostring(t) end
    return comp
end

--====================================================================
-- RADIO BUTTON
--====================================================================
--[[
    Win95.RadioButton(opts)
        Text, Position, Parent, Selected (bool)
        OnChanged function(selected)

    Grouping is manual: call :SetSelected(false) on siblings, or use
    Win95.RadioGroup (below).

    returns: .Instance, :SetSelected(b), :GetSelected(), :SetText(t), :Destroy()
]]
function Win95.RadioButton(opts)
    opts = opts or {}
    local selected = opts.Selected == true

    local root = new("TextButton", {
        Name = "RadioButton",
        Size = opts.Size or UDim2.fromOffset(150, 16),
        Position = opts.Position or UDim2.new(),
        BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
        ZIndex = (opts.ZIndex or Z_BASE) + 20,
        Visible = opts.Visible ~= false,
        Parent = opts.Parent,
    })
    local comp = component(root)

    -- The circle: a white disc with a manually-drawn ring.
    local SIZE = 12
    local disc = new("Frame", {
        Size = UDim2.fromOffset(SIZE, SIZE),
        Position = UDim2.fromOffset(0, 2),
        BackgroundColor3 = C.FieldBg, BorderSizePixel = 0,
        ZIndex = root.ZIndex + 1, Parent = root,
    })
    new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = disc })

    -- ring segments (top-left dark, bottom-right light = sunken look)
    local ring = new("Frame", {
        Size = UDim2.fromOffset(SIZE, SIZE),
        BackgroundTransparency = 1, ZIndex = root.ZIndex + 2, Parent = disc,
    })
    new("UIStroke", {
        Color = C.DarkSh, Thickness = 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = ring,
    })
    new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = ring })

    -- selected dot
    local dot = new("Frame", {
        Size = UDim2.fromOffset(4, 4),
        Position = UDim2.new(0.5, -2, 0.5, -2),
        BackgroundColor3 = C.Text, BorderSizePixel = 0,
        ZIndex = root.ZIndex + 3, Parent = disc,
    })
    new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = dot })

    local label = new("TextLabel", {
        Size = UDim2.new(1, -20, 1, 0),
        Position = UDim2.fromOffset(19, 0),
        Text = opts.Text or "Radio",
        ZIndex = root.ZIndex + 1, Parent = root,
    })
    styleText(label)

    local function render() dot.Visible = selected end
    render()

    comp:_track(root.Activated:Connect(function()
        if selected then return end  -- radios don't un-toggle themselves
        selected = true
        render()
        fire(opts.OnChanged, true)
    end))

    function comp:SetSelected(v)
        selected = v and true or false
        render()
    end
    function comp:GetSelected() return selected end
    function comp:SetText(t) label.Text = tostring(t) end
    return comp
end

--- Helper: given an array of radio components, make them exclusive.
function Win95.RadioGroup(radios, onChanged)
    for _, r in ipairs(radios) do
        local oldChanged = r:GetSelected() -- no-op read to keep API simple
        local btn = r.Instance
        btn.Activated:Connect(function()
            for _, other in ipairs(radios) do
                if other ~= r then other:SetSelected(false) end
            end
            fire(onChanged, r)
        end)
    end
end

--====================================================================
-- SLIDER
--====================================================================
--[[
    Win95.Slider(opts)
        Min, Max, Value  numbers (default 0..100)
        Step             number   snap increment (0 = free)
        Size             UDim2    default 200x28
        Position, Parent
        ShowTicks        bool     draw tick marks below the groove
        TickEvery        number   tick interval in value units
        OnChanged        function(value)

    returns: .Instance, :SetValue(v), :GetValue(), :Destroy()
]]
function Win95.Slider(opts)
    opts = opts or {}
    local min = opts.Min or 0
    local max = opts.Max or 100
    local step = opts.Step or 0
    local value = math.clamp(opts.Value or min, min, max)

    local root = new("Frame", {
        Name = "Slider",
        Size = opts.Size or UDim2.fromOffset(200, 28),
        Position = opts.Position or UDim2.new(),
        BackgroundTransparency = 1, BorderSizePixel = 0,
        ZIndex = (opts.ZIndex or Z_BASE) + 20,
        Visible = opts.Visible ~= false,
        Parent = opts.Parent,
    })
    local comp = component(root)

    local PAD = 10          -- half-thumb travel margin
    local THUMB_W, THUMB_H = 11, 21
    local GROOVE_H = 4

    local groove = new("Frame", {
        Size = UDim2.new(1, -PAD * 2, 0, GROOVE_H),
        Position = UDim2.new(0, PAD, 0, 4),
        BackgroundColor3 = C.Face, BorderSizePixel = 0,
        ZIndex = root.ZIndex + 1, Parent = root,
    })
    bevel(groove, "thin-sunken")

    -- tick marks
    if opts.ShowTicks then
        local every = opts.TickEvery or math.max(1, (max - min) / 10)
        local tickHolder = new("Frame", {
            Size = UDim2.new(1, -PAD * 2, 0, 4),
            Position = UDim2.new(0, PAD, 0, 11),
            BackgroundTransparency = 1, BorderSizePixel = 0,
            ZIndex = root.ZIndex + 1, Parent = root,
        })
        local range = max - min
        if range > 0 then
            local n = math.floor(range / every)
            for i = 0, math.min(n, 200) do
                new("Frame", {
                    BackgroundColor3 = C.DarkSh, BorderSizePixel = 0,
                    Size = UDim2.fromOffset(1, 4),
                    Position = UDim2.new(i * every / range, 0, 0, 0),
                    ZIndex = root.ZIndex + 1, Parent = tickHolder,
                })
            end
        end
    end

    local thumb = new("TextButton", {
        Size = UDim2.fromOffset(THUMB_W, THUMB_H),
        Position = UDim2.new(0, 0, 0, 0),
        BackgroundColor3 = C.Face, BorderSizePixel = 0,
        Text = "", AutoButtonColor = false,
        ZIndex = root.ZIndex + 3, Parent = root,
    })
    bevel(thumb, "raised")

    local function trackWidth()
        return math.max(1, root.AbsoluteSize.X - PAD * 2)
    end
    local function valueToX(v)
        local t = (v - min) / math.max(1e-9, max - min)
        return t * (trackWidth() - THUMB_W)
    end
    local function xToValue(x)
        local t = math.clamp(x / math.max(1, trackWidth() - THUMB_W), 0, 1)
        return min + t * (max - min)
    end
    local function snap(v)
        if step > 0 then
            v = math.floor((v - min) / step + 0.5) * step + min
        end
        return math.clamp(v, min, max)
    end

    local function render()
        thumb.Position = UDim2.new(0, PAD + valueToX(value), 0, 0)
    end
    render()
    comp:_track(root:GetPropertyChangedSignal("AbsoluteSize"):Connect(render))

    local dragging = false
    local function applyFromInput(input)
        local relX = input.Position.X - (root.AbsolutePosition.X + PAD)
        local v = snap(xToValue(relX))
        if v ~= value then
            value = v
            render()
            fire(opts.OnChanged, value)
        end
    end

    comp:_track(thumb.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
        end
    end))
    -- clicking anywhere on the track jumps the thumb there
    comp:_track(root.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            applyFromInput(input)
        end
    end))
    comp:_track(UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        applyFromInput(input)
    end))
    comp:_track(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    function comp:SetValue(v)
        value = snap(v)
        render()
    end
    function comp:GetValue() return value end
    return comp
end

--====================================================================
-- PROGRESS BAR
--====================================================================
--[[
    Win95.ProgressBar(opts)
        Size, Position, Parent
        Value        number 0..1
        Segmented    bool (default true, the classic chunky blocks)
        SegmentCount number (default derived from width)
        Smooth       bool    shorthand for Segmented=false

    returns: .Instance, :SetValue(v), :GetValue(), :Destroy()
]]
function Win95.ProgressBar(opts)
    opts = opts or {}
    local value = math.clamp(opts.Value or 0, 0, 1)
    local segmented = opts.Segmented ~= false and opts.Smooth ~= true

    local root = new("Frame", {
        Name = "ProgressBar",
        Size = opts.Size or UDim2.fromOffset(250, 20),
        Position = opts.Position or UDim2.new(),
        BackgroundColor3 = C.Face, BorderSizePixel = 0,
        ZIndex = (opts.ZIndex or Z_BASE) + 20,
        Visible = opts.Visible ~= false,
        Parent = opts.Parent,
    })
    local comp = component(root)
    bevel(root, "sunken")

    local inner = new("Frame", {
        Size = UDim2.new(1, -4, 1, -4),
        Position = UDim2.fromOffset(2, 2),
        BackgroundColor3 = C.Face, BorderSizePixel = 0,
        ClipsDescendants = true,
        ZIndex = root.ZIndex + 3, Parent = root,
    })

    local fill
    if not segmented then
        fill = new("Frame", {
            Size = UDim2.new(value, 0, 1, 0),
            BackgroundColor3 = C.TitleBar, BorderSizePixel = 0,
            ZIndex = root.ZIndex + 4, Parent = inner,
        })
    end

    local SEG_W, GAP = 10, 2
    local blocks = {}

    local function render()
        local w = inner.AbsoluteSize.X
        if w <= 1 then return end
        if segmented then
            -- rebuild block count if width changed meaningfully
            local count = math.floor((w + GAP) / (SEG_W + GAP))
            if #blocks ~= count then
                for _, b in ipairs(blocks) do b:Destroy() end
                blocks = {}
                for i = 1, count do
                    blocks[i] = new("Frame", {
                        BackgroundColor3 = C.TitleBar, BorderSizePixel = 0,
                        Size = UDim2.fromOffset(SEG_W, 1),
                        Position = UDim2.fromOffset((i - 1) * (SEG_W + GAP), 0),
                        ZIndex = root.ZIndex + 4, Parent = inner,
                    })
                    blocks[i].Size = UDim2.fromOffset(SEG_W, inner.AbsoluteSize.Y)
                end
                -- keep blocks full height
                for _, b in ipairs(blocks) do
                    b.Size = UDim2.new(0, SEG_W, 1, 0)
                end
            end
            local active = math.floor(value * #blocks + 0.5)
            for i, b in ipairs(blocks) do
                b.Visible = i <= active
            end
        else
            fill.Size = UDim2.new(value, 0, 1, 0)
        end
    end

    comp:_track(inner:GetPropertyChangedSignal("AbsoluteSize"):Connect(render))
    task.defer(render)

    function comp:SetValue(v)
        value = math.clamp(v, 0, 1)
        render()
    end
    function comp:GetValue() return value end
    return comp
end

--====================================================================
-- LABEL
--====================================================================
--[[
    Win95.Label(opts)
        Text, Size, Position, Parent, TextColor, Align (TextXAlignment)

    returns: .Instance, :SetText(t), :GetText(), :Destroy()
]]
function Win95.Label(opts)
    opts = opts or {}
    local label = new("TextLabel", {
        Name = "Label",
        Size = opts.Size or UDim2.fromOffset(120, 16),
        Position = opts.Position or UDim2.new(),
        Text = opts.Text or "",
        TextXAlignment = opts.Align or Enum.TextXAlignment.Left,
        TextWrapped = opts.Wrapped == true,
        ZIndex = (opts.ZIndex or Z_BASE) + 20,
        Visible = opts.Visible ~= false,
        Parent = opts.Parent,
    })
    local comp = component(label)
    styleText(label)
    if opts.TextColor then label.TextColor3 = opts.TextColor end
    function comp:SetText(t) label.Text = tostring(t) end
    function comp:GetText() return label.Text end
    return comp
end

--====================================================================
-- GROUP BOX
--====================================================================
--[[
    Win95.GroupBox(opts)
        Text, Size, Position, Parent

    The etched border has the classic notch where the title sits.
    returns: .Instance, :SetText(t), :Destroy()
]]
function Win95.GroupBox(opts)
    opts = opts or {}

    local root = new("Frame", {
        Name = "GroupBox",
        Size = opts.Size or UDim2.fromOffset(200, 100),
        Position = opts.Position or UDim2.new(),
        BackgroundColor3 = C.Face, BorderSizePixel = 0,
        ZIndex = (opts.ZIndex or Z_BASE) + 10,
        Visible = opts.Visible ~= false,
        Parent = opts.Parent,
    })
    local comp = component(root)

    local function bfr(name, color, pos, size, z)
        return new("Frame", {
            Name = name, BackgroundColor3 = color, BorderSizePixel = 0,
            Position = pos, Size = size, ZIndex = z, Parent = root,
        })
    end
    local z = root.ZIndex

    -- left, right, bottom etch (dark then light = groove)
    bfr("gL0", C.DarkSh,  UDim2.new(0, 0, 0, 4), UDim2.new(0, 1, 1, -4), z + 1)
    bfr("gL1", C.LightHi, UDim2.new(0, 1, 0, 4), UDim2.new(0, 1, 1, -6), z + 1)
    bfr("gR0", C.DarkSh,  UDim2.new(1, -2, 0, 4), UDim2.new(0, 1, 1, -6), z + 1)
    bfr("gR1", C.LightHi, UDim2.new(1, -1, 0, 4), UDim2.new(0, 1, 1, -4), z + 1)
    bfr("gB0", C.DarkSh,  UDim2.new(0, 0, 1, -2), UDim2.new(1, 0, 0, 1), z + 1)
    bfr("gB1", C.LightHi, UDim2.new(0, 0, 1, -1), UDim2.new(1, 0, 0, 1), z + 1)

    -- top border comes in two segments, split around the title
    local topL0 = bfr("gTL0", C.DarkSh,  UDim2.new(0, 2, 0, 4), UDim2.new(0, 0, 0, 1), z + 1)
    local topL1 = bfr("gTL1", C.LightHi, UDim2.new(0, 2, 0, 5), UDim2.new(0, 0, 0, 1), z + 1)
    local topR0 = bfr("gTR0", C.DarkSh,  UDim2.new(0, 0, 0, 4), UDim2.new(0, 0, 0, 1), z + 1)
    local topR1 = bfr("gTR1", C.LightHi, UDim2.new(0, 0, 0, 5), UDim2.new(0, 0, 0, 1), z + 1)

    local title = new("TextLabel", {
        Size = UDim2.new(0, 0, 0, 12),
        Position = UDim2.new(0, 9, 0, -2),
        Text = " " .. (opts.Text or "Group") .. " ",
        BackgroundColor3 = C.Face,
        AutomaticSize = Enum.AutomaticSize.X,
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex = z + 2, Parent = root,
    })
    styleText(title)
    title.BackgroundTransparency = 0

    local function layout()
        local w = root.AbsoluteSize.X
        if w <= 1 then return end
        local titleRight = 9 + title.AbsoluteSize.X
        local lw = math.max(0, 9 - 2)
        topL0.Position = UDim2.new(0, 2, 0, 4); topL0.Size = UDim2.new(0, lw, 0, 1)
        topL1.Position = UDim2.new(0, 2, 0, 5); topL1.Size = UDim2.new(0, lw, 0, 1)
        local rw = math.max(0, w - titleRight - 2)
        topR0.Position = UDim2.new(0, titleRight, 0, 4); topR0.Size = UDim2.new(0, rw, 0, 1)
        topR1.Position = UDim2.new(0, titleRight, 0, 5); topR1.Size = UDim2.new(0, rw, 0, 1)
    end
    comp:_track(root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout))
    comp:_track(title:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout))
    task.defer(layout)

    function comp:SetText(t)
        title.Text = " " .. tostring(t) .. " "
    end
    return comp
end

--====================================================================
-- TEXT BOX
--====================================================================
--[[
    Win95.TextBox(opts)
        PlaceholderText, Text, Size, Position, Parent
        Label    string  optional caption drawn to the left (auto-width)
        Password bool
        ClearOnFocus bool (default false)
        OnChanged function(text)
        OnSubmit  function(text)   -- Enter pressed

    returns: .Instance, :SetText(t), :GetText(), :Clear(), :Destroy()
]]
function Win95.TextBox(opts)
    opts = opts or {}

    local root = new("Frame", {
        Name = "TextBox",
        Size = opts.Size or UDim2.fromOffset(160, 21),
        Position = opts.Position or UDim2.new(),
        BackgroundColor3 = C.FieldBg, BorderSizePixel = 0,
        ZIndex = (opts.ZIndex or Z_BASE) + 20,
        Visible = opts.Visible ~= false,
        Parent = opts.Parent,
    })
    local comp = component(root)
    bevel(root, "sunken")

    -- optional caption
    if opts.Label then
        local lbl = new("TextLabel", {
            Size = UDim2.new(0, 0, 0, 16),
            Position = UDim2.new(0, -8, 0.5, -8),
            Text = opts.Label,
            AutomaticSize = Enum.AutomaticSize.X,
            TextXAlignment = Enum.TextXAlignment.Right,
            ZIndex = root.ZIndex, Parent = root,
        })
        styleText(lbl)
        -- shift the box right by the label width once it measures
        task.defer(function()
            if lbl.Parent then
                local w = lbl.AbsoluteSize.X
                root.Position = root.Position + UDim2.fromOffset(w + 12, 0)
                lbl.Position = UDim2.new(0, -(w + 12), 0.5, -8)
            end
        end)
    end

    local box = new("TextBox", {
        Name = "Field",
        Size = UDim2.new(1, -8, 1, -6),
        Position = UDim2.fromOffset(4, 3),
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Text = opts.Text or "",
        PlaceholderText = opts.PlaceholderText or "",
        PlaceholderColor3 = C.TextDis,
        ClearTextOnFocus = opts.ClearOnFocus == true,
        ZIndex = root.ZIndex + 3, Parent = root,
    })
    styleText(box)
    box.TextXAlignment = Enum.TextXAlignment.Left
    if opts.Password then
        box.PasswordVisible = false
        -- Roblox TextBox has no password mode; mask manually.
        local real = opts.Text or ""
        box.Text = string.rep("*", #real)
        comp:_track(box:GetPropertyChangedSignal("Text"):Connect(function()
            local t = box.Text
            if #t < #real and real:sub(1, #t) == string.rep("*", #t) then
                -- deletion
                real = real:sub(1, #t)
            else
                local added = t:sub(#real + 1)
                real = real .. added:gsub("%*", "")
            end
            box.Text = string.rep("*", #real)
            fire(opts.OnChanged, real)
        end))
        function comp:GetText() return real end
    else
        comp:_track(box:GetPropertyChangedSignal("Text"):Connect(function()
            fire(opts.OnChanged, box.Text)
        end))
        function comp:GetText() return box.Text end
    end

    comp:_track(box.FocusLost:Connect(function(enterPressed)
        if enterPressed then fire(opts.OnSubmit, comp:GetText()) end
    end))

    function comp:SetText(t)
        box.Text = tostring(t)
    end
    function comp:Clear() box.Text = "" end
    function comp:Focus() box:CaptureFocus() end
    return comp
end

--====================================================================
-- LISTBOX
--====================================================================
--[[
    Win95.ListBox(opts)
        Items    array of strings
        Size, Position, Parent
        SelectedIndex number (1-based, 0/nil = none)
        OnChanged function(index, text)
        OnDoubleClick function(index, text)

    returns: .Instance, :SetItems(arr), :GetItems(),
             :SetSelectedIndex(i), :GetSelectedIndex(), :GetSelectedText(),
             :Clear(), :Destroy()
]]
function Win95.ListBox(opts)
    opts = opts or {}
    local items = {}
    local selected = opts.SelectedIndex or 0

    local root = new("Frame", {
        Name = "ListBox",
        Size = opts.Size or UDim2.fromOffset(160, 120),
        Position = opts.Position or UDim2.new(),
        BackgroundColor3 = C.FieldBg, BorderSizePixel = 0,
        ClipsDescendants = false,
        ZIndex = (opts.ZIndex or Z_BASE) + 20,
        Visible = opts.Visible ~= false,
        Parent = opts.Parent,
    })
    local comp = component(root)
    bevel(root, "sunken")

    local viewport = new("ScrollingFrame", {
        Size = UDim2.new(1, -6, 1, -6),
        Position = UDim2.fromOffset(3, 3),
        BackgroundColor3 = C.FieldBg, BorderSizePixel = 0,
        ScrollBarThickness = 14,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ZIndex = root.ZIndex + 3, Parent = root,
    })
    -- Win95-style scrollbar (gray with beveled thumb)
    viewport.ScrollBarImageColor3 = C.Face
    viewport.VerticalScrollBarPosition = Enum.VerticalScrollBarPosition.Right

    local layout = new("UIListLayout", {
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 0),
        Parent = viewport,
    })

    local rows = {}

    local function render()
        for _, r in ipairs(rows) do r:Destroy() end
        rows = {}
        for i, text in ipairs(items) do
            local row = new("TextButton", {
                Size = UDim2.new(1, -14, 0, 16),
                BackgroundColor3 = (i == selected) and C.Select or C.FieldBg,
                BorderSizePixel = 0, AutoButtonColor = false,
                Text = "  " .. text,
                LayoutOrder = i,
                ZIndex = root.ZIndex + 4, Parent = viewport,
            })
            styleText(row)
            row.TextColor3 = (i == selected) and C.SelectTxt or C.Text
            row.TextXAlignment = Enum.TextXAlignment.Left

            comp:_track(row.Activated:Connect(function()
                selected = i
                render()
                fire(opts.OnChanged, i, text)
            end))
            rows[i] = row
        end
    end

    function comp:SetItems(arr)
        items = {}
        for _, v in ipairs(arr or {}) do table.insert(items, tostring(v)) end
        selected = 0
        render()
    end
    function comp:GetItems() return table.clone(items) end
    function comp:SetSelectedIndex(i)
        selected = math.clamp(i or 0, 0, #items)
        render()
    end
    function comp:GetSelectedIndex() return selected end
    function comp:GetSelectedText() return items[selected] end
    function comp:Clear() items = {}; selected = 0; render() end

    if #items or opts.Items then end -- no-op guard
    comp:SetItems(opts.Items or {})
    if opts.SelectedIndex then comp:SetSelectedIndex(opts.SelectedIndex) end
    return comp
end

--====================================================================
-- STATUS BAR
--====================================================================
--[[
    Win95.StatusBar(opts)
        Parent   a Window's Content frame (recommended)
        Panes    array of { Text=..., Width=pixels|nil (nil=flex) }
        Height   number default 20

    Designed to sit at the bottom of a window's content area. Use
    Size = UDim2.new(1, 0, 0, 20) and Position = UDim2.new(0, 0, 1, -20).

    returns: .Instance, :SetPaneText(i, text), :Destroy()
]]
function Win95.StatusBar(opts)
    opts = opts or {}
    local height = opts.Height or 20

    local root = new("Frame", {
        Name = "StatusBar",
        Size = opts.Size or UDim2.new(1, 0, 0, height),
        Position = opts.Position or UDim2.new(0, 0, 1, -height),
        BackgroundColor3 = C.Face, BorderSizePixel = 0,
        ZIndex = (opts.ZIndex or Z_BASE) + 20,
        Visible = opts.Visible ~= false,
        Parent = opts.Parent,
    })
    local comp = component(root)

    local panes = {}
    local paneDefs = opts.Panes or { { Text = "" } }

    local function layout()
        for _, p in ipairs(panes) do p:Destroy() end
        panes = {}
        local w = root.AbsoluteSize.X
        if w <= 1 then return end

        -- measure fixed panes, flex gets the rest
        local flexCount, fixedTotal = 0, 0
        for _, def in ipairs(paneDefs) do
            if def.Width then fixedTotal = fixedTotal + def.Width
            else flexCount = flexCount + 1 end
        end
        local flexW = math.max(40, math.floor((w - fixedTotal - 4 * (#paneDefs + 1)) / math.max(1, flexCount)))

        local x = 2
        for i, def in ipairs(paneDefs) do
            local pw = def.Width or flexW
            local pane = new("TextLabel", {
                Size = UDim2.fromOffset(pw, height - 4),
                Position = UDim2.fromOffset(x, 2),
                BackgroundColor3 = C.Face, BorderSizePixel = 0,
                Text = " " .. (def.Text or ""),
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                ZIndex = root.ZIndex + 1, Parent = root,
            })
            styleText(pane)
            -- sunken pane edge
            new("UIStroke", {
                Color = C.DarkSh, Thickness = 1,
                ApplyStrokeMode = Enum.ApplyStrokeMode.Inset, Parent = pane,
            })
            pane.BackgroundTransparency = 1
            bevel(pane, "thin-sunken")
            panes[i] = pane
            x = x + pw + 4
        end
    end

    comp:_track(root:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout))
    task.defer(layout)

    function comp:SetPaneText(i, text)
        if paneDefs[i] then
            paneDefs[i].Text = tostring(text)
            layout()
        end
    end
    return comp
end

--====================================================================
-- TAB STRIP
--====================================================================
--[[
    Win95.TabStrip(opts)
        Tabs     array of { Title=string, Build=function(page) }
        Size, Position, Parent
        OnChanged function(index, title)

    Each Build(pageFrame) receives a plain frame for that tab's
    content; it's called lazily the first time a tab is opened.

    returns: .Instance, :SelectTab(i), :GetSelectedTab(),
             :AddTab(title, build), :Destroy()
]]
function Win95.TabStrip(opts)
    opts = opts or {}
    local tabs = {}       -- {title, build, page, built}
    local selected = 0

    local root = new("Frame", {
        Name = "TabStrip",
        Size = opts.Size or UDim2.fromOffset(300, 200),
        Position = opts.Position or UDim2.new(),
        BackgroundColor3 = C.Face, BorderSizePixel = 0,
        ZIndex = (opts.ZIndex or Z_BASE) + 10,
        Visible = opts.Visible ~= false,
        Parent = opts.Parent,
    })
    local comp = component(root)

    -- the big raised panel that holds pages
    local panel = new("Frame", {
        Size = UDim2.new(1, 0, 1, -22),
        Position = UDim2.new(0, 0, 0, 22),
        BackgroundColor3 = C.Face, BorderSizePixel = 0,
        ZIndex = root.ZIndex + 1, Parent = root,
    })
    bevel(panel, "raised")

    local tabHolder = new("Frame", {
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1, BorderSizePixel = 0,
        ZIndex = root.ZIndex + 2, Parent = root,
    })

    local tabButtons = {}

    local function drawTabs()
        for _, b in ipairs(tabButtons) do b:Destroy() end
        tabButtons = {}
        local x = 4
        for i, tab in ipairs(tabs) do
            local isSel = i == selected
            local w = #tab.title * 7 + 20
            local btn = new("TextButton", {
                Size = UDim2.fromOffset(w, isSel and 24 or 22),
                Position = UDim2.fromOffset(x, isSel and 0 or 2),
                BackgroundColor3 = C.Face, BorderSizePixel = 0,
                Text = tab.title,
                ZIndex = root.ZIndex + (isSel and 5 or 3), Parent = tabHolder,
            })
            styleText(btn)
            btn.TextXAlignment = Enum.TextXAlignment.Center
            bevel(btn, "thin-raised")
            if isSel then
                -- hide bottom edge so tab merges with panel
                new("Frame", {
                    Size = UDim2.new(1, -2, 0, 2),
                    Position = UDim2.new(0, 1, 1, -2),
                    BackgroundColor3 = C.Face, BorderSizePixel = 0,
                    ZIndex = btn.ZIndex + 1, Parent = btn,
                })
            end
            comp:_track(btn.Activated:Connect(function()
                comp:SelectTab(i)
            end))
            tabButtons[i] = btn
            x = x + w + (isSel and -1 or 1)
        end
    end

    local function showPage(i)
        for _, tab in ipairs(tabs) do
            if tab.page then tab.page.Visible = false end
        end
        local tab = tabs[i]
        if not tab then return end
        if not tab.built then
            tab.built = true
            tab.page = new("Frame", {
                Size = UDim2.new(1, -12, 1, -12),
                Position = UDim2.fromOffset(6, 6),
                BackgroundTransparency = 1, BorderSizePixel = 0,
                ZIndex = panel.ZIndex + 3, Parent = panel,
            })
            fire(tab.build, tab.page)
        end
        tab.page.Visible = true
    end

    function comp:AddTab(title, build)
        table.insert(tabs, { title = tostring(title), build = build })
        if selected == 0 then selected = 1 end
        drawTabs()
        if selected == #tabs then showPage(selected) end
    end

    function comp:SelectTab(i)
        if i < 1 or i > #tabs or i == selected then
            if i == selected then showPage(i) end
            return
        end
        selected = i
        drawTabs()
        showPage(i)
        fire(opts.OnChanged, i, tabs[i].title)
    end

    function comp:GetSelectedTab() return selected end

    for _, def in ipairs(opts.Tabs or {}) do
        comp:AddTab(def.Title or def[1] or "Tab", def.Build or def[2])
    end
    if #tabs > 0 then
        drawTabs()
        showPage(selected)
    end

    return comp
end

--====================================================================
-- EXPORTS
--====================================================================
Win95.StyleText = styleText
Win95.Bevel = bevel
Win95.New = new  -- advanced users can build with the same primitives

return Win95
