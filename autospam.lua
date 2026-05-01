local clicking = false
local holdMode  = false
local KPS      = 80
local interval = 1 / KPS

local pi_integral     = 0
local PI_INTEGRAL_CAP = 2 * interval
local PI_DEADBAND     = interval * 0.015

local PI_KP         = 0.35
local PI_KI         = 0.012
local EMA_ALPHA     = 0.12
local EMA_ONE_MINUS = 1 - EMA_ALPHA
local PI_DECAY      = 1 - (1/512)

local drift_accum = 0
local pi_residual = 0

local tick_n_absolute  = 0
local suppressed_count = 0
local session_start    = 0
local ema_error        = 0
local phase_offset     = 0

local nano_cd  = 16
local micro_cd = 64

local NANO_CLAMP      = interval * 0.2
local MICRO_CLAMP     = interval * 0.4
local NANO_GAIN       = 0.05
local MICRO_GAIN      = 0.15
local HALF_INTERVAL   = interval * 0.5
local MAX_LAG         = interval
local YIELD_THRESHOLD = 0.002

local RING_SIZE      = 256
local ring           = table.create(RING_SIZE, 0)
local ring_head      = 0
local last_tier      = -1
local last_count_str = "0"

local TOGGLE_KEY = Enum.KeyCode.E
local SPAM_KEY   = Enum.KeyCode.F

local UIS          = game:GetService("UserInputService")
local VIM          = game:GetService("VirtualInputManager")
local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")
local Players      = game:GetService("Players")
local player       = Players.LocalPlayer
local playerGui    = player:WaitForChild("PlayerGui")

local hrt       = os.clock
local task_wait = task.wait
local m_floor   = math.floor
local m_abs     = math.abs
local m_clamp   = math.clamp
local tostr     = tostring

local TI_02  = TweenInfo.new(0.2)
local TI_03  = TweenInfo.new(0.3)
local TI_015 = TweenInfo.new(0.15)
local TI_04  = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TI_05  = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TI_06  = TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

local COL_WHITE      = Color3.fromRGB(225,  235, 255)
local COL_OFFWHITE   = Color3.fromRGB(180,  210, 255)
local COL_MID        = Color3.fromRGB(155,  170, 230)
local COL_DIM        = Color3.fromRGB(110,  95,  180)
local COL_DARK       = Color3.fromRGB(18,   12,  38)
local COL_BLACK      = Color3.fromRGB(8,    6,   18)
local COL_DIVIDER    = Color3.fromRGB(30,   20,  55)
local COL_STROKE_OFF = Color3.fromRGB(60,   40,  120)
local COL_STROKE_ON  = Color3.fromRGB(140,  200, 255)

local function applyKPS(newKPS)
    KPS             = math.clamp(newKPS, 1, 250)
    interval        = 1 / KPS
    PI_INTEGRAL_CAP = 2 * interval
    PI_DEADBAND     = interval * 0.015
    NANO_CLAMP      = interval * 0.2
    MICRO_CLAMP     = interval * 0.4
    HALF_INTERVAL   = interval * 0.5
    MAX_LAG         = interval
end

local function spam_loop()
    task_wait(0.05)
    if not clicking then return end

    pi_integral      = 0
    pi_residual      = 0
    ema_error        = 0
    drift_accum      = 0
    tick_n_absolute  = 0
    suppressed_count = 0
    phase_offset     = 0
    nano_cd          = 16
    micro_cd         = 64
    ring_head        = 0
    for i = 1, RING_SIZE do ring[i] = 0 end
    EMA_ONE_MINUS = 1 - EMA_ALPHA

    session_start = hrt()

    while clicking do
        local next_fire = session_start + (tick_n_absolute - suppressed_count) * interval + phase_offset

        local remaining = next_fire - hrt()
        if remaining > YIELD_THRESHOLD then
            task_wait(remaining - YIELD_THRESHOLD)
        end
        while hrt() < next_fire do end

        if not clicking then break end

        local fire_time = hrt()
        VIM:SendKeyEvent(true,  SPAM_KEY, false, game)
        VIM:SendKeyEvent(false, SPAM_KEY, false, game)

        tick_n_absolute = tick_n_absolute + 1
        ring_head = (ring_head % RING_SIZE) + 1
        ring[ring_head] = fire_time

        local abs_elapsed  = fire_time - session_start
        local abs_expected = (tick_n_absolute - suppressed_count) * interval

        nano_cd = nano_cd - 1
        if nano_cd == 0 then
            nano_cd = 16
            local err = abs_elapsed - abs_expected
            if err >  NANO_CLAMP then err =  NANO_CLAMP
            elseif err < -NANO_CLAMP then err = -NANO_CLAMP end
            phase_offset = phase_offset - err * NANO_GAIN
        end

        micro_cd = micro_cd - 1
        if micro_cd == 0 then
            micro_cd = 64
            local err = abs_elapsed - abs_expected
            if err >  MICRO_CLAMP then err =  MICRO_CLAMP
            elseif err < -MICRO_CLAMP then err = -MICRO_CLAMP end
            phase_offset = phase_offset - err * MICRO_GAIN
        end

        local raw_error = abs_elapsed - abs_expected
        ema_error = EMA_ONE_MINUS * ema_error + EMA_ALPHA * raw_error
        local error = ema_error

        if error > PI_DEADBAND or error < -PI_DEADBAND then
            pi_integral = pi_integral + error
            if pi_integral >  PI_INTEGRAL_CAP then pi_integral =  PI_INTEGRAL_CAP
            elseif pi_integral < -PI_INTEGRAL_CAP then pi_integral = -PI_INTEGRAL_CAP end
            local correction = PI_KP * error + PI_KI * pi_integral
            drift_accum = drift_accum + correction
            local carry = m_floor(drift_accum / interval + 0.5) * interval
            drift_accum = drift_accum - carry
            pi_residual = pi_residual + (correction - carry)
            local res_carry = m_floor(pi_residual / interval + 0.5) * interval
            pi_residual = pi_residual - res_carry
            phase_offset = phase_offset - correction
        else
            pi_integral = pi_integral * PI_DECAY
        end

        local now        = hrt()
        local next_ideal = session_start + (tick_n_absolute - suppressed_count) * interval + phase_offset
        local lag        = now - next_ideal

        if lag > MAX_LAG then
            session_start = now - (tick_n_absolute - suppressed_count) * interval - phase_offset
            suppressed_count = suppressed_count + 1
        elseif lag > HALF_INTERVAL then
            session_start = session_start + lag * 0.5
        end
    end
end

-- ─── GUI ──────────────────────────────────────────────────────────────────

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AutoSpamGUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = playerGui

-- ─── Title / splash box ──────────────────────────────────────────────────

local titleBox = Instance.new("Frame")
titleBox.Name = "TitleBox"
titleBox.Size = UDim2.new(0, 110, 0, 40)
titleBox.Position = UDim2.new(0.5, -55, 0.5, -20)
titleBox.BackgroundColor3 = COL_BLACK
titleBox.BorderSizePixel = 0
titleBox.BackgroundTransparency = 1   -- start invisible for fade-in
titleBox.Parent = screenGui
Instance.new("UICorner", titleBox).CornerRadius = UDim.new(0, 10)

local titleStroke = Instance.new("UIStroke")
titleStroke.Color = COL_STROKE_OFF
titleStroke.Thickness = 1.5
titleStroke.Transparency = 1          -- start invisible
titleStroke.Parent = titleBox

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, 0, 1, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "1NSTICT"
titleLabel.TextColor3 = COL_WHITE
titleLabel.TextTransparency = 1       -- start invisible
titleLabel.TextScaled = true
titleLabel.Font = Enum.Font.GothamBold
titleLabel.Parent = titleBox

local titleBtn = Instance.new("TextButton")
titleBtn.Size = UDim2.new(1, 0, 1, 0)
titleBtn.BackgroundTransparency = 1
titleBtn.Text = ""
titleBtn.Parent = titleBox

-- ─── Main frame (hidden initially) ───────────────────────────────────────

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 160, 0, 280)
frame.Position = UDim2.new(0.5, -80, 0.5, -140)
frame.BackgroundColor3 = COL_BLACK
frame.BorderSizePixel = 0
frame.BackgroundTransparency = 1   -- start invisible
frame.Visible = false
frame.Parent = screenGui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 16)

local stroke = Instance.new("UIStroke")
stroke.Color = COL_STROKE_OFF
stroke.Thickness = 1.5
stroke.Transparency = 1
stroke.Parent = frame

-- ─── Close (X) button ────────────────────────────────────────────────────

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 22, 0, 22)
closeBtn.Position = UDim2.new(1, -26, 0, 4)
closeBtn.BackgroundColor3 = COL_DARK
closeBtn.BorderSizePixel = 0
closeBtn.Text = "X"
closeBtn.TextColor3 = COL_MID
closeBtn.TextScaled = false
closeBtn.TextSize = 12
closeBtn.Font = Enum.Font.GothamBold
closeBtn.ZIndex = 10
closeBtn.Parent = frame
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 5)

closeBtn.MouseEnter:Connect(function()
    TweenService:Create(closeBtn, TI_02, {TextColor3 = COL_WHITE}):Play()
end)
closeBtn.MouseLeave:Connect(function()
    TweenService:Create(closeBtn, TI_02, {TextColor3 = COL_MID}):Play()
end)

local dot = Instance.new("Frame")
dot.Size = UDim2.new(0, 10, 0, 10)
dot.Position = UDim2.new(0.5, -5, 0, 10)
dot.BackgroundColor3 = COL_DIM
dot.BorderSizePixel = 0
dot.Parent = frame
Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

local kpsNumber = Instance.new("TextLabel")
kpsNumber.Size = UDim2.new(1, 0, 0, 70)
kpsNumber.Position = UDim2.new(0, 0, 0, 18)
kpsNumber.BackgroundTransparency = 1
kpsNumber.Text = "0"
kpsNumber.TextColor3 = COL_WHITE
kpsNumber.TextScaled = true
kpsNumber.Font = Enum.Font.GothamBold
kpsNumber.Parent = frame

local kpsSub = Instance.new("TextLabel")
kpsSub.Size = UDim2.new(1, 0, 0, 16)
kpsSub.Position = UDim2.new(0, 0, 0, 88)
kpsSub.BackgroundTransparency = 1
kpsSub.Text = "KPS"
kpsSub.TextColor3 = COL_DIM
kpsSub.TextScaled = true
kpsSub.Font = Enum.Font.Gotham
kpsSub.Parent = frame

local function makeDivider(y)
    local d = Instance.new("Frame")
    d.Size = UDim2.new(1, -20, 0, 1)
    d.Position = UDim2.new(0, 10, 0, y)
    d.BackgroundColor3 = COL_DIVIDER
    d.BorderSizePixel = 0
    d.Parent = frame
end

local function makeRowLabel(text, y)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, -12, 0, 14)
    l.Position = UDim2.new(0, 10, 0, y)
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextColor3 = COL_DIM
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextScaled = true
    l.Font = Enum.Font.Gotham
    l.Parent = frame
    return l
end

local function makeKeyBtn(defaultText, y)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 52, 0, 22)
    btn.Position = UDim2.new(1, -60, 0, y)
    btn.BackgroundColor3 = COL_DARK
    btn.BorderSizePixel = 0
    btn.Text = defaultText
    btn.TextColor3 = COL_OFFWHITE
    btn.TextScaled = true
    btn.Font = Enum.Font.GothamBold
    btn.Parent = frame
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
    local s = Instance.new("UIStroke")
    s.Color = COL_STROKE_OFF
    s.Thickness = 1
    s.Parent = btn
    return btn, s
end

-- ── KPS row ───────────────────────────────────────────────────────────────
makeDivider(112)
makeRowLabel("KPS:", 120)

local btnMinus = Instance.new("TextButton")
btnMinus.Size = UDim2.new(0, 40, 0, 30)
btnMinus.Position = UDim2.new(0, 8, 0, 138)
btnMinus.BackgroundColor3 = COL_DARK
btnMinus.BorderSizePixel = 0
btnMinus.Text = "–"
btnMinus.TextColor3 = COL_OFFWHITE
btnMinus.TextScaled = true
btnMinus.Font = Enum.Font.GothamBold
btnMinus.Parent = frame
Instance.new("UICorner", btnMinus).CornerRadius = UDim.new(0, 8)

local targetNum = Instance.new("TextLabel")
targetNum.Size = UDim2.new(0, 56, 0, 30)
targetNum.Position = UDim2.new(0.5, -28, 0, 138)
targetNum.BackgroundTransparency = 1
targetNum.Text = "80"
targetNum.TextColor3 = COL_WHITE
targetNum.TextScaled = true
targetNum.Font = Enum.Font.GothamBold
targetNum.Parent = frame

local btnPlus = Instance.new("TextButton")
btnPlus.Size = UDim2.new(0, 40, 0, 30)
btnPlus.Position = UDim2.new(1, -48, 0, 138)
btnPlus.BackgroundColor3 = COL_DARK
btnPlus.BorderSizePixel = 0
btnPlus.Text = "+"
btnPlus.TextColor3 = COL_OFFWHITE
btnPlus.TextScaled = true
btnPlus.Font = Enum.Font.GothamBold
btnPlus.Parent = frame
Instance.new("UICorner", btnPlus).CornerRadius = UDim.new(0, 8)

-- ── Mode row ──────────────────────────────────────────────────────────────
makeDivider(176)
makeRowLabel("MODE:", 184)

local modeBtn = Instance.new("TextButton")
modeBtn.Size = UDim2.new(0, 72, 0, 22)
modeBtn.Position = UDim2.new(1, -80, 0, 181)
modeBtn.BackgroundColor3 = COL_DARK
modeBtn.BorderSizePixel = 0
modeBtn.Text = "TOGGLE"
modeBtn.TextColor3 = COL_OFFWHITE
modeBtn.TextScaled = true
modeBtn.Font = Enum.Font.GothamBold
modeBtn.Parent = frame
Instance.new("UICorner", modeBtn).CornerRadius = UDim.new(0, 6)
local modeStroke = Instance.new("UIStroke")
modeStroke.Color = COL_STROKE_OFF
modeStroke.Thickness = 1
modeStroke.Parent = modeBtn

-- ── ACTIVATE row ──────────────────────────────────────────────────────────
makeDivider(212)
makeRowLabel("ACTIVATE:", 220)
local activateBtn, activateStroke = makeKeyBtn("E", 217)

-- ── KEY2SPAM row ──────────────────────────────────────────────────────────
makeDivider(248)
makeRowLabel("KEY2SPAM:", 256)
local spamBtn, spamStroke = makeKeyBtn("F", 253)

-- ─── Open / Close animation helpers ──────────────────────────────────────

local mainOpen = false

local function openMainGui()
    if mainOpen then return end
    mainOpen = true

    -- Snapshot title box screen position before hiding it
    local tbPos = titleBox.AbsolutePosition

    -- Collapse the title box
    TweenService:Create(titleBox,   TI_04, {BackgroundTransparency = 1}):Play()
    TweenService:Create(titleStroke,TI_04, {Transparency = 1}):Play()
    TweenService:Create(titleLabel, TI_04, {TextTransparency = 1}):Play()

    task.delay(0.25, function()
        titleBox.Visible = false

        -- Place main frame at same screen position as where the title box was
        frame.Position = UDim2.new(0, tbPos.X, 0, tbPos.Y)
        frame.Size = UDim2.new(0, 160, 0, 40)
        frame.BackgroundTransparency = 0
        frame.Visible = true

        TweenService:Create(frame,  TI_06, {Size = UDim2.new(0, 160, 0, 280)}):Play()
        TweenService:Create(stroke, TI_05, {Transparency = 0}):Play()
    end)
end

local function closeMainGui()
    if not mainOpen then return end
    mainOpen = false

    -- Snapshot main frame position before animating
    local fPos = frame.AbsolutePosition

    TweenService:Create(frame,  TI_04, {Size = UDim2.new(0, 160, 0, 40), BackgroundTransparency = 1}):Play()
    TweenService:Create(stroke, TI_04, {Transparency = 1}):Play()

    task.delay(0.35, function()
        frame.Visible = false
        frame.Size = UDim2.new(0, 160, 0, 280)

        -- Restore title box at the spot where the main frame was
        titleBox.Position = UDim2.new(0, fPos.X, 0, fPos.Y)
        titleBox.Visible = true
        TweenService:Create(titleBox,    TI_05, {BackgroundTransparency = 0}):Play()
        TweenService:Create(titleStroke, TI_05, {Transparency = 0}):Play()
        TweenService:Create(titleLabel,  TI_05, {TextTransparency = 0}):Play()
    end)
end

-- declared here so the click handler below can read it (drag section sets it)
local tbDidDrag = false

-- ─── Title box hover glow ────────────────────────────────────────────────

titleBtn.MouseEnter:Connect(function()
    TweenService:Create(titleStroke, TI_02, {Color = COL_STROKE_ON}):Play()
    TweenService:Create(titleLabel,  TI_02, {TextColor3 = COL_WHITE}):Play()
end)
titleBtn.MouseLeave:Connect(function()
    TweenService:Create(titleStroke, TI_02, {Color = COL_STROKE_OFF}):Play()
    TweenService:Create(titleLabel,  TI_02, {TextColor3 = COL_OFFWHITE}):Play()
end)
titleBtn.MouseButton1Click:Connect(function()
    if not tbDidDrag then openMainGui() end
end)

-- ─── Close button ────────────────────────────────────────────────────────

closeBtn.MouseButton1Click:Connect(function()
    if clicking then
        clicking = false
        TweenService:Create(dot,       TI_02, {BackgroundColor3 = COL_DIM}):Play()
        TweenService:Create(stroke,    TI_02, {Color = COL_STROKE_OFF}):Play()
        TweenService:Create(kpsNumber, TI_03, {TextColor3 = COL_WHITE}):Play()
        kpsNumber.Text = "0"
        last_tier = -1
    end
    closeMainGui()
end)

-- ─── Startup fade-in of title box ────────────────────────────────────────

task.spawn(function()
    task_wait(0.3)
    titleBox.Visible = true
    TweenService:Create(titleBox, TI_05, {BackgroundTransparency = 0}):Play()
    TweenService:Create(titleStroke, TI_05, {Transparency = 0}):Play()
    task_wait(0.1)
    TweenService:Create(titleLabel, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {TextTransparency = 0}):Play()
    -- Subtle pulse on the stroke to draw attention
    task_wait(0.7)
    TweenService:Create(titleStroke, TI_03, {Color = COL_STROKE_ON}):Play()
    task_wait(0.4)
    TweenService:Create(titleStroke, TI_03, {Color = COL_STROKE_OFF}):Play()
end)

-- ─── Key-bind helper ──────────────────────────────────────────────────────

local waitingForKey = false

local function bindKey(btn, btnStroke, blockedKeys, onSuccess)
    if waitingForKey then return end
    waitingForKey = true
    local prev = btn.Text
    btn.Text = "..."
    btn.TextColor3 = COL_MID
    TweenService:Create(btnStroke, TI_02, {Color = COL_MID}):Play()

    local conn
    conn = UIS.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

        for _, blocked in ipairs(blockedKeys) do
            if input.KeyCode == blocked then
                btn.Text = "!"
                task.delay(0.8, function()
                    btn.Text = prev
                    btn.TextColor3 = COL_OFFWHITE
                    TweenService:Create(btnStroke, TI_02, {Color = COL_STROKE_OFF}):Play()
                    waitingForKey = false
                end)
                conn:Disconnect()
                return
            end
        end

        local name = tostr(input.KeyCode.Name)
        if #name > 4 then name = string.sub(name, 1, 4) end
        btn.Text = name
        btn.TextColor3 = COL_OFFWHITE
        TweenService:Create(btnStroke, TI_02, {Color = COL_STROKE_OFF}):Play()
        waitingForKey = false
        onSuccess(input.KeyCode)
        conn:Disconnect()
    end)
end

activateBtn.MouseButton1Click:Connect(function()
    bindKey(activateBtn, activateStroke, {SPAM_KEY}, function(key)
        TOGGLE_KEY = key
    end)
end)

spamBtn.MouseButton1Click:Connect(function()
    bindKey(spamBtn, spamStroke, {TOGGLE_KEY}, function(key)
        SPAM_KEY = key
        if clicking then
            clicking = false
            task_wait(0.02)
            clicking = true
            task.spawn(spam_loop)
        end
    end)
end)

-- ─── Mode toggle ──────────────────────────────────────────────────────────

modeBtn.MouseButton1Click:Connect(function()
    holdMode = not holdMode
    if holdMode then
        modeBtn.Text = "HOLD"
        if clicking then
            clicking = false
            TweenService:Create(dot,       TI_02, {BackgroundColor3 = COL_DIM}):Play()
            TweenService:Create(stroke,    TI_02, {Color = COL_STROKE_OFF}):Play()
            TweenService:Create(kpsNumber, TI_03, {TextColor3 = COL_WHITE}):Play()
            kpsNumber.Text = "0"
            last_tier = -1
        end
    else
        modeBtn.Text = "TOGGLE"
    end
end)

-- ─── KPS buttons ──────────────────────────────────────────────────────────

local targetKPS = 80

local function updateTarget(newVal)
    targetKPS = math.clamp(newVal, 1, 250)
    targetNum.Text = tostr(targetKPS)
    applyKPS(targetKPS)
    if clicking then
        clicking = false
        task_wait(0.02)
        clicking = true
        task.spawn(spam_loop)
    end
end

local function holdButton(btn, delta)
    local held = false
    btn.MouseButton1Down:Connect(function()
        held = true
        updateTarget(targetKPS + delta)
        task.spawn(function()
            task_wait(0.4)
            while held do
                updateTarget(targetKPS + delta)
                task_wait(0.08)
            end
        end)
    end)
    btn.MouseButton1Up:Connect(function() held = false end)
    btn.MouseLeave:Connect(function() held = false end)
end

holdButton(btnMinus, -1)
holdButton(btnPlus,  1)

-- ─── Activation helpers ───────────────────────────────────────────────────

local function startClicking()
    if clicking then return end
    clicking = true
    last_tier = -1
    TweenService:Create(dot,    TI_02, {BackgroundColor3 = COL_WHITE}):Play()
    TweenService:Create(stroke, TI_02, {Color = COL_STROKE_ON}):Play()
    task.spawn(spam_loop)
end

local function stopClicking()
    if not clicking then return end
    clicking = false
    TweenService:Create(dot,       TI_02, {BackgroundColor3 = COL_DIM}):Play()
    TweenService:Create(stroke,    TI_02, {Color = COL_STROKE_OFF}):Play()
    TweenService:Create(kpsNumber, TI_03, {TextColor3 = COL_WHITE}):Play()
    kpsNumber.Text = "0"
    last_tier = -1
end

-- ─── Input handling ───────────────────────────────────────────────────────

UIS.InputBegan:Connect(function(input, _)
    if waitingForKey then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    if input.KeyCode ~= TOGGLE_KEY then return end
    if holdMode then startClicking()
    else if clicking then stopClicking() else startClicking() end
    end
end)

UIS.InputEnded:Connect(function(input)
    if waitingForKey then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    if input.KeyCode ~= TOGGLE_KEY then return end
    if holdMode then stopClicking() end
end)

-- ─── Drag ─────────────────────────────────────────────────────────────────

local dragActive  = false
local dragTarget  = nil
local dragOffsetX = 0
local dragOffsetY = 0

-- title box pending state (before threshold)
local tbPending   = false   -- mouse is held, not yet confirmed as drag
local tbPendDownX = 0
local tbPendDownY = 0

local THRESH = 8            -- pixels before drag activates

frame.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    dragActive  = true
    dragTarget  = frame
    dragOffsetX = input.Position.X - frame.AbsolutePosition.X
    dragOffsetY = input.Position.Y - frame.AbsolutePosition.Y
end)

titleBtn.MouseButton1Down:Connect(function(input)
    tbPending   = true
    tbDidDrag   = false
    tbPendDownX = input.Position.X
    tbPendDownY = input.Position.Y
    dragOffsetX = input.Position.X - titleBox.AbsolutePosition.X
    dragOffsetY = input.Position.Y - titleBox.AbsolutePosition.Y
end)

UIS.InputChanged:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end

    -- promote pending title box press into a real drag after threshold
    if tbPending and not tbDidDrag then
        local dx = input.Position.X - tbPendDownX
        local dy = input.Position.Y - tbPendDownY
        if dx*dx + dy*dy >= THRESH*THRESH then
            tbDidDrag  = true
            dragActive = true
            dragTarget = titleBox
        end
    end

    if not dragActive or not dragTarget then return end
    local ss = screenGui.AbsoluteSize
    local fs = dragTarget.AbsoluteSize
    dragTarget.Position = UDim2.new(0,
        m_clamp(input.Position.X - dragOffsetX, 0, ss.X - fs.X),
        0,
        m_clamp(input.Position.Y - dragOffsetY, 0, ss.Y - fs.Y)
    )
end)

UIS.InputEnded:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    dragActive = false
    dragTarget = nil
    tbPending  = false
end)

-- ─── KPS counter ──────────────────────────────────────────────────────────

task.spawn(function()
    while true do
        task_wait(0.1)
        if clicking then
            local now    = hrt()
            local cutoff = now - 1
            local count  = 0
            for i = 1, RING_SIZE do
                if ring[i] > cutoff then count = count + 1 end
            end

            local str = tostr(count)
            if str ~= last_count_str then
                last_count_str = str
                kpsNumber.Text = str
            end

            local tier
            if count >= 130 then tier = 2
            elseif count >= 90 then tier = 1
            else tier = 0 end

            if tier ~= last_tier then
                last_tier = tier
                local col = tier == 2 and COL_WHITE or tier == 1 and COL_OFFWHITE or COL_MID
                TweenService:Create(kpsNumber, TI_015, {TextColor3 = col}):Play()
            end
        end
    end
end)
