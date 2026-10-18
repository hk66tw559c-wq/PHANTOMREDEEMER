local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local LP = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")

local cachedBox, cachedSubmit, cachedCodesFrame
local _pendingRedeemCode = nil
local _pendingRedeemTime = 0

local LOG_LABEL = nil

local function makeLogLine(prefix, message, color)
    if not LOG_LABEL then return end
    local line = '<font color="' .. color .. '">' .. prefix .. '</font> '
        .. '<font color="rgb(140,160,150)">' .. tostring(message) .. '</font>'
    if LOG_LABEL.Text == "" then
        LOG_LABEL.Text = line
    else
        LOG_LABEL.Text = LOG_LABEL.Text .. "\n" .. line
    end
    task.defer(function()
        task.wait()
        if not LOG_LABEL then return end
        local parent = LOG_LABEL.Parent
        if parent and parent:IsA("ScrollingFrame") then
            parent.CanvasSize = UDim2.new(0, 0, 0, LOG_LABEL.AbsoluteSize.Y + 20)
            parent.CanvasPosition = Vector2.new(0, math.max(0, parent.AbsoluteCanvasSize.Y - parent.AbsoluteWindowSize.Y))
        end
    end)
end

local function logInfo(msg) makeLogLine("$", msg, "rgb(0,255,100)") end
local function logGame(msg) makeLogLine(">", msg, "rgb(120,220,255)") end
local function logSuccess(msg) makeLogLine("+", msg, "rgb(160,255,200)") end
local function logError(msg) makeLogLine("!", msg, "rgb(255,80,80)") end
local function logAuto(msg) makeLogLine("~", msg, "rgb(255,200,80)") end
local function logSpam(msg) makeLogLine("&", msg, "rgb(255,100,200)") end
local function logSetting(name, state)
    makeLogLine("#", name .. "=" .. (state and "ON" or "OFF"), "rgb(180,140,255)")
end

local function isOurGui(instance)
    local p = instance
    for _ = 1, 10 do
        if not p then break end
        if p.Name == "PhantomRedeemerGui" then return true end
        p = p.Parent
    end
    return false
end

local function findAllTextBoxes(pg)
    local boxes = {}
    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") and gui.Enabled and gui.Name ~= "PhantomRedeemerGui" then
            for _, d in ipairs(gui:GetDescendants()) do
                if d:IsA("TextBox") and not isOurGui(d) then
                    boxes[#boxes+1] = d
                end
            end
        end
    end
    return boxes
end

local function isVisibleChain(inst)
    local current = inst
    while current do
        if current:IsA("GuiObject") then
            if not current.Visible then return false end
        end
        if current:IsA("ScreenGui") then
            return current.Enabled
        end
        current = current.Parent
    end
    return true
end

local _has_firesignal = type(firesignal) == "function"
local _has_getconnections = type(getconnections) == "function"

local function blastButton(btn)
    if not btn then return end
    if _has_firesignal then
        pcall(firesignal, btn.MouseButton1Click)
        return
    end
    pcall(function() btn.MouseButton1Click:Fire() end)
end

local function blastFocusLost(box)
    if not box then return end
    if _has_firesignal then
        pcall(firesignal, box.FocusLost, true)
        return
    end
    if _has_getconnections then
        local cs = getconnections(box.FocusLost)
        if cs then
            for i = 1, #cs do
                local c = cs[i]
                if c.Enabled ~= false then
                    pcall(function() c:Fire(true) end)
                    return
                end
            end
        end
    end
end

local function locateCodesElements(pg)
    local codesGui = pg:FindFirstChild("Codes")
    if not codesGui then return nil, nil, nil end
    if codesGui:IsA("ScreenGui") and not codesGui.Enabled then codesGui.Enabled = true end
    local codesFrame = codesGui:FindFirstChild("Codes") or codesGui
    if not codesFrame then return nil, nil, nil end
    if codesFrame:IsA("GuiObject") and not codesFrame.Visible then codesFrame.Visible = true end

    local box, submitBtn
    for _, d in ipairs(codesFrame:GetDescendants()) do
        if not box and d:IsA("TextBox") and not isOurGui(d) then
            box = d
        elseif not submitBtn and (d:IsA("TextButton") or d:IsA("ImageButton")) and not isOurGui(d) then
            local n = d.Name:lower()
            local txt = ""
            pcall(function() txt = d.Text:lower() end)
            if n:find("submit") or txt:find("submit") or n:find("redeem") or txt:find("redeem")
                or n:find("claim") or txt:find("claim") or n:find("confirm") or txt:find("confirm")
                or n:find("enter") or txt:find("enter") then
                submitBtn = d
            end
        end
        if box and submitBtn then break end
    end
    return box, submitBtn, codesFrame
end

local function checkRedeemFeedback(text)
    if not _pendingRedeemCode then return end
    if os.clock() - _pendingRedeemTime > 3 then
        _pendingRedeemCode = nil
        return
    end
    local lower = tostring(text or ""):lower()
    if lower == "" then return end

    if lower:find("success", 1, true) or lower:find("valid", 1, true) or lower:find("claimed", 1, true) or lower:find("reward", 1, true) or lower:find("enjoy", 1, true) then
        logSuccess("code has been successfully redeemed: " .. _pendingRedeemCode)
        _pendingRedeemCode = nil
        return
    end
end

-- ============================================================
-- CONTROLLER METHOD — bind once, fire at raw FireServer speed
-- ============================================================
local _submitRemote = nil
local _resolveAttempted = false
local _submitFire = nil

local function findRemoteInUpvalues(fn)
    if not fn or not debug or not debug.getupvalue then return nil end
    local i = 1
    while true do
        local name, val = debug.getupvalue(fn, i)
        if not name then break end
        if typeof(val) == "Instance" and (val:IsA("RemoteEvent") or val:IsA("RemoteFunction")) then
            return val
        end
        if type(val) == "table" then
            for _, v in pairs(val) do
                if typeof(v) == "Instance" and (v:IsA("RemoteEvent") or v:IsA("RemoteFunction")) then
                    return v
                end
            end
        end
        i = i + 1
    end
    return nil
end

local function resolveSubmitRemote(btn)
    if not btn or not _has_getconnections then return nil end
    local ok, cs = pcall(getconnections, btn.MouseButton1Click)
    if not ok or not cs then return nil end
    for _, c in ipairs(cs) do
        local f, fn = pcall(function() return c.Function end)
        if f and type(fn) == "function" then
            local remote = findRemoteInUpvalues(fn)
            if remote then return remote end
        end
    end
    return nil
end

local function bindSubmitFire(remote)
    if not remote then return nil end
    if remote:IsA("RemoteEvent") then
        return function(code)
            remote:FireServer(code)
        end
    elseif remote:IsA("RemoteFunction") then
        return function(code)
            remote:InvokeServer(code)
        end
    end
    return nil
end

local function tryResolveSubmitRemote()
    if _submitFire then return true end
    if _resolveAttempted then return false end
    _resolveAttempted = true
    if not cachedSubmit then return false end
    local r = resolveSubmitRemote(cachedSubmit)
    if not r then return false end
    _submitRemote = r
    _submitFire = bindSubmitFire(r)
    if _submitFire then
        logInfo("controller: bound to remote")
        return true
    end
    return false
end

-- FAST SUBMIT: fire first, write second, skip FocusLost when remote fired.
-- No _submitting lock — back-to-back codes fire in the same frame.
local function typeAndSubmitCode(code)
    _pendingRedeemCode = code
    _pendingRedeemTime = os.clock()

    if cachedBox and cachedBox.Parent and cachedBox:IsDescendantOf(PlayerGui) then
        if _submitFire then
            _submitFire(code)
            cachedBox.Text = code
            return true
        end
        cachedBox.Text = code
        if cachedSubmit and cachedSubmit.Parent then blastButton(cachedSubmit) end
        blastFocusLost(cachedBox)
        return true
    end

    local box, submitBtn, frame = locateCodesElements(PlayerGui)
    if box then
        cachedBox, cachedSubmit, cachedCodesFrame = box, submitBtn, frame
        tryResolveSubmitRemote()
        if _submitFire then
            _submitFire(code)
            box.Text = code
            return true
        end
        box.Text = code
        if submitBtn then blastButton(submitBtn) end
        blastFocusLost(box)
        return true
    end

    local foundBox
    local deadline = tick() + 0.15
    while tick() < deadline and not foundBox do
        local allBoxes = findAllTextBoxes(PlayerGui)
        for i = 1, #allBoxes do
            local d = allBoxes[i]
            if isVisibleChain(d) then
                local n = d.Name:lower()
                if n:find("code") or n:find("redeem") or n:find("input") or n:find("enter") then
                    foundBox = d
                    break
                end
            end
        end
        if not foundBox and #allBoxes > 0 then
            for i = 1, #allBoxes do
                if isVisibleChain(allBoxes[i]) then foundBox = allBoxes[i]; break end
            end
        end
        if not foundBox then RunService.Heartbeat:Wait() end
    end

    if not foundBox then
        return false
    end
    cachedBox = foundBox
    foundBox.Text = code
    blastFocusLost(foundBox)
    return true
end

local function resolveNotifyRemote()
    local ok, Net = pcall(function()
        return ReplicatedStorage:WaitForChild("Packages", 5):WaitForChild("Net", 5)
    end)
    if not ok or not Net then return nil end
    local getinfo = debug and (debug.getinfo or debug.info)
    if getgc and getinfo and getconnections then
        for _, d in ipairs(Net:GetDescendants()) do
            if d:IsA("RemoteEvent") then
                local ok2, cs = pcall(getconnections, d.OnClientEvent)
                if ok2 then
                    for _, c in ipairs(cs) do
                        local f, fn = pcall(function() return c.Function end)
                        if f and type(fn) == "function" then
                            local i, info = pcall(getinfo, fn)
                            if i and tostring(info.short_src or info.source or ""):find("NotificationController", 1, true) then
                                return d
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

local notifyRemote = resolveNotifyRemote()

pcall(function()
    if PlayerGui:FindFirstChild("PhantomRedeemerGui") then
        PlayerGui.PhantomRedeemerGui:Destroy()
    end
end)

local THEME = {
    BG           = Color3.fromRGB(0, 0, 0),
    GREEN        = Color3.fromRGB(160, 255, 200),
    HACK_GREEN   = Color3.fromRGB(0, 255, 100),
    HACK_BRIGHT  = Color3.fromRGB(180, 255, 200),
    MAGENTA      = Color3.fromRGB(255, 100, 200),
}

local function applyHackerText(label, textSize, bright)
    if not label then return end
    label.TextColor3 = bright and THEME.HACK_BRIGHT or THEME.HACK_GREEN
    if textSize then label.TextSize = textSize end
    label.Font = Enum.Font.Code
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(0, 150, 60)
    stroke.Thickness = 1.5
    stroke.Transparency = 0.4
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
    stroke.Parent = label
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PhantomRedeemerGui"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.IgnoreGuiInset = true
screenGui.Parent = PlayerGui

local root = Instance.new("Frame")
root.Size = UDim2.fromOffset(340, 300)
root.Position = UDim2.new(0.5, -170, 0.5, -150)
root.BackgroundColor3 = THEME.BG
root.BackgroundTransparency = 1
root.BorderSizePixel = 0
root.Active = true
root.ClipsDescendants = true
root.Parent = screenGui

local rootCorner = Instance.new("UICorner")
rootCorner.CornerRadius = UDim.new(0, 8)
rootCorner.Parent = root

local logScroll = Instance.new("ScrollingFrame")
logScroll.Size = UDim2.new(1, -16, 1, -16)
logScroll.Position = UDim2.fromOffset(8, 8)
logScroll.BackgroundTransparency = 1
logScroll.BorderSizePixel = 0
logScroll.ScrollBarThickness = 2
logScroll.ScrollBarImageColor3 = THEME.HACK_GREEN
logScroll.ScrollingDirection = Enum.ScrollingDirection.Y
logScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
logScroll.ZIndex = 21
logScroll.Visible = false

local logOutput = Instance.new("TextLabel")
logOutput.Size = UDim2.new(1, -8, 0, 100)
logOutput.AutomaticSize = Enum.AutomaticSize.Y
logOutput.Position = UDim2.fromOffset(4, 4)
logOutput.BackgroundTransparency = 1
logOutput.RichText = true
logOutput.Text = ""
logOutput.TextSize = 11
logOutput.Font = Enum.Font.Code
logOutput.TextXAlignment = Enum.TextXAlignment.Left
logOutput.TextYAlignment = Enum.TextYAlignment.Top
logOutput.TextWrapped = true
logOutput.ZIndex = 22
logOutput.Parent = logScroll

LOG_LABEL = logOutput

logInfo("phantom redeemer online")
if notifyRemote then
    logInfo("link established")
else
    logError("no notify remote")
end

local bgBase = Instance.new("Frame")
bgBase.Size = UDim2.new(1, 0, 1, 0)
bgBase.BackgroundColor3 = Color3.fromRGB(0, 4, 0)
bgBase.BorderSizePixel = 0
bgBase.ZIndex = 1
bgBase.ClipsDescendants = true
bgBase.Parent = root

local bgBaseCorner = Instance.new("UICorner")
bgBaseCorner.CornerRadius = UDim.new(0, 8)
bgBaseCorner.Parent = bgBase

local bgGrad = Instance.new("UIGradient")
bgGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0.0, Color3.fromRGB(0, 30, 10)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 12, 4)),
    ColorSequenceKeypoint.new(1.0, Color3.fromRGB(0, 0, 0)),
})
bgGrad.Rotation = 90
bgGrad.Parent = bgBase

local visualEffects = Instance.new("Folder")
visualEffects.Name = "VisualEffects"
visualEffects.Parent = bgBase

local runMatrix = true
local runSweep = true
local runAura = true

local CHAR_POOL = {"ア","イ","ウ","エ","オ","カ","キ","ク","ケ","コ","サ","シ","ス","セ","ソ","タ","チ","ツ","テ","ト","ナ","ニ","ヌ","ネ","ノ","ハ","ヒ","フ","ヘ","ホ","0","1","2","3","4","5","6","7","8","9","A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z","$","#","@","%","&","*","+","=","<",">","/","\\","|","!","?","~"}

local function randChar()
    return CHAR_POOL[math.random(1, #CHAR_POOL)]
end

local function makeColumn(xPos, speed, charCount, zIndex, opacity, fontSize)
    local col = Instance.new("Frame")
    col.Size = UDim2.new(0, 12, 1, 0)
    col.Position = UDim2.new(xPos, 0, 0, 0)
    col.BackgroundTransparency = 1
    col.ZIndex = zIndex
    col.Parent = visualEffects

    local labels = {}
    for i = 1, charCount do
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, 0, 0, fontSize + 2)
        lbl.Position = UDim2.new(0, 0, (i - 1) / charCount, 0)
        lbl.BackgroundTransparency = 1
        lbl.Text = randChar()
        lbl.TextColor3 = THEME.HACK_GREEN
        lbl.TextSize = fontSize
        lbl.Font = Enum.Font.Code
        lbl.TextTransparency = opacity
        lbl.ZIndex = zIndex
        lbl.Parent = col
        labels[i] = lbl
    end

    task.spawn(function()
        while col.Parent and runMatrix do
            col.Position = UDim2.new(xPos, 0, -1, 0)
            local dur = speed
            local tween = TweenService:Create(col, TweenInfo.new(dur, Enum.EasingStyle.Linear), {
                Position = UDim2.new(xPos, 0, 1.2, 0)
            })
            tween:Play()
            local sc = math.random(3, 8)
            for _ = 1, sc do
                task.wait(dur / sc)
                if not runMatrix then break end
                for _, lbl in ipairs(labels) do
                    if math.random() < 0.3 then lbl.Text = randChar() end
                end
            end
            tween.Completed:Wait()
            task.wait(math.random(5, 40) / 100)
        end
    end)
end

for i = 0, 24 do
    makeColumn((i / 25) + (math.random(-2, 2) / 200), math.random(30, 90) / 10, math.random(4, 9), 2, math.random(40, 85) / 100, math.random(8, 12))
end

for i = 0, 12 do
    local xPos = (i / 12) + (math.random(-3, 3) / 200)
    local col = Instance.new("Frame")
    col.Size = UDim2.new(0, 8, 1, 0)
    col.Position = UDim2.new(xPos, 0, 0, 0)
    col.BackgroundTransparency = 1
    col.ZIndex = 3
    col.Parent = visualEffects

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 200)
    lbl.BackgroundTransparency = 1
    lbl.Text = string.rep(math.random(0, 1) .. "\n", 40)
    lbl.TextColor3 = Color3.fromRGB(120, 255, 160)
    lbl.TextSize = 9
    lbl.Font = Enum.Font.Code
    lbl.TextTransparency = 0.55
    lbl.TextYAlignment = Enum.TextYAlignment.Top
    lbl.ZIndex = 3
    lbl.Parent = col

    task.spawn(function()
        while col.Parent and runMatrix do
            col.Position = UDim2.new(xPos, 0, -0.5, 0)
            local dur = math.random(25, 60) / 10
            TweenService:Create(col, TweenInfo.new(dur, Enum.EasingStyle.Linear), {
                Position = UDim2.new(xPos, 0, 1, 0)
            }):Play()
            task.wait(dur + math.random(10, 30) / 100)
        end
    end)
end

for i = 0, 69 do
    local line = Instance.new("Frame")
    line.Size = UDim2.new(1, 0, 0, 1)
    line.Position = UDim2.new(0, 0, i / 70, 0)
    line.BackgroundColor3 = Color3.fromRGB(0, 255, 100)
    line.BackgroundTransparency = 0.94
    line.BorderSizePixel = 0
    line.ZIndex = 4
    line.Parent = visualEffects
end

local sweep = Instance.new("Frame")
sweep.Size = UDim2.new(1, 0, 0, 2)
sweep.BackgroundColor3 = THEME.HACK_GREEN
sweep.BackgroundTransparency = 0.7
sweep.BorderSizePixel = 0
sweep.ZIndex = 5
sweep.Parent = visualEffects

task.spawn(function()
    while sweep.Parent and runSweep do
        sweep.Position = UDim2.new(0, 0, 0, 0)
        TweenService:Create(sweep, TweenInfo.new(3.5, Enum.EasingStyle.Linear), {
            Position = UDim2.new(0, 0, 1, 0)
        }):Play()
        task.wait(3.5)
    end
end)

local innerTint = Instance.new("Frame")
innerTint.Size = UDim2.new(1, 0, 1, 0)
innerTint.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
innerTint.BackgroundTransparency = 0.68
innerTint.BorderSizePixel = 0
innerTint.ZIndex = 6
innerTint.Parent = bgBase

local auraStroke = Instance.new("UIStroke")
auraStroke.Color = THEME.HACK_GREEN
auraStroke.Thickness = 1.5
auraStroke.Transparency = 0.4
auraStroke.Parent = root

task.spawn(function()
    while screenGui.Parent and runAura do
        TweenService:Create(auraStroke, TweenInfo.new(1.5, Enum.EasingStyle.Sine), {Transparency = 0.2}):Play()
        task.wait(1.5)
        TweenService:Create(auraStroke, TweenInfo.new(1.5, Enum.EasingStyle.Sine), {Transparency = 0.55}):Play()
        task.wait(1.5)
    end
end)

local title = Instance.new("TextLabel")
title.Size = UDim2.fromOffset(200, 20)
title.Position = UDim2.fromOffset(12, 6)
title.BackgroundTransparency = 1
title.Text = "PHANTOM REDEEMER"
title.TextXAlignment = Enum.TextXAlignment.Left
title.ZIndex = 10
title.Parent = root
applyHackerText(title, 12, true)

local pingText = Instance.new("TextLabel")
pingText.Size = UDim2.fromOffset(60, 12)
pingText.Position = UDim2.new(1, -140, 0, 10)
pingText.BackgroundTransparency = 1
pingText.Text = "-- ms"
pingText.TextColor3 = THEME.HACK_GREEN
pingText.TextSize = 9
pingText.Font = Enum.Font.Code
pingText.TextXAlignment = Enum.TextXAlignment.Right
pingText.ZIndex = 10
pingText.Parent = root

task.spawn(function()
    while pingText and pingText.Parent do
        local ok, ping = pcall(function()
            return math.floor(LP:GetNetworkPing() * 1000 + 0.5)
        end)
        if ok and ping then
            pingText.Text = ping .. " ms"
            if ping > 150 then
                pingText.TextColor3 = Color3.fromRGB(255, 80, 80)
            elseif ping > 80 then
                pingText.TextColor3 = Color3.fromRGB(255, 200, 80)
            else
                pingText.TextColor3 = THEME.HACK_GREEN
            end
        else
            pingText.Text = "-- ms"
        end
        task.wait(1)
    end
end)

local statusText = Instance.new("TextLabel")
statusText.Size = UDim2.fromOffset(70, 12)
statusText.Position = UDim2.new(1, -212, 0, 10)
statusText.BackgroundTransparency = 1
statusText.Text = "[ IDLE ]"
statusText.TextColor3 = THEME.HACK_GREEN
statusText.TextSize = 9
statusText.Font = Enum.Font.Code
statusText.TextXAlignment = Enum.TextXAlignment.Right
statusText.ZIndex = 10
statusText.Parent = root

local tabMain = Instance.new("TextButton")
tabMain.Size = UDim2.fromOffset(60, 20)
tabMain.Position = UDim2.fromOffset(12, 30)
tabMain.BackgroundColor3 = Color3.fromRGB(0, 30, 10)
tabMain.BorderSizePixel = 0
tabMain.Text = "Main"
tabMain.TextColor3 = THEME.HACK_BRIGHT
tabMain.Font = Enum.Font.Code
tabMain.TextSize = 11
tabMain.AutoButtonColor = false
tabMain.ZIndex = 10
tabMain.Parent = root

local tabMainCorner = Instance.new("UICorner")
tabMainCorner.CornerRadius = UDim.new(0, 4)
tabMainCorner.Parent = tabMain

local tabSettings = Instance.new("TextButton")
tabSettings.Size = UDim2.fromOffset(60, 20)
tabSettings.Position = UDim2.fromOffset(76, 30)
tabSettings.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
tabSettings.BorderSizePixel = 0
tabSettings.Text = "Settings"
tabSettings.TextColor3 = THEME.HACK_GREEN
tabSettings.Font = Enum.Font.Code
tabSettings.TextSize = 11
tabSettings.AutoButtonColor = false
tabSettings.ZIndex = 10
tabSettings.Parent = root

local tabSettingsCorner = Instance.new("UICorner")
tabSettingsCorner.CornerRadius = UDim.new(0, 4)
tabSettingsCorner.Parent = tabSettings

local tabLogs = Instance.new("TextButton")
tabLogs.Size = UDim2.fromOffset(60, 20)
tabLogs.Position = UDim2.fromOffset(140, 30)
tabLogs.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
tabLogs.BorderSizePixel = 0
tabLogs.Text = "Logs"
tabLogs.TextColor3 = THEME.HACK_GREEN
tabLogs.Font = Enum.Font.Code
tabLogs.TextSize = 11
tabLogs.AutoButtonColor = false
tabLogs.ZIndex = 10
tabLogs.Parent = root

local tabLogsCorner = Instance.new("UICorner")
tabLogsCorner.CornerRadius = UDim.new(0, 4)
tabLogsCorner.Parent = tabLogs

local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, -24, 0, 1)
divider.Position = UDim2.fromOffset(12, 54)
divider.BackgroundColor3 = THEME.HACK_GREEN
divider.BackgroundTransparency = 0.5
divider.BorderSizePixel = 0
divider.ZIndex = 10
divider.Parent = root

local mainPage = Instance.new("Frame")
mainPage.Size = UDim2.new(1, 0, 1, -54)
mainPage.Position = UDim2.fromOffset(0, 54)
mainPage.BackgroundTransparency = 1
mainPage.ZIndex = 9
mainPage.Parent = root

local scanButton = Instance.new("TextButton")
scanButton.Size = UDim2.fromOffset(120, 30)
scanButton.Position = UDim2.fromOffset(12, 8)
scanButton.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
scanButton.BackgroundTransparency = 0.3
scanButton.BorderSizePixel = 0
scanButton.Text = "START SCAN"
scanButton.AutoButtonColor = false
scanButton.ZIndex = 10
scanButton.Parent = mainPage

local scanCorner = Instance.new("UICorner")
scanCorner.CornerRadius = UDim.new(0, 5)
scanCorner.Parent = scanButton

local scanStroke = Instance.new("UIStroke")
scanStroke.Color = THEME.HACK_GREEN
scanStroke.Thickness = 1
scanStroke.Transparency = 0.55
scanStroke.Parent = scanButton

applyHackerText(scanButton, 10)

local modeLabel = Instance.new("TextLabel")
modeLabel.Size = UDim2.fromOffset(120, 9)
modeLabel.Position = UDim2.fromOffset(142, 4)
modeLabel.BackgroundTransparency = 1
modeLabel.Text = "> chain"
modeLabel.TextColor3 = THEME.HACK_GREEN
modeLabel.TextSize = 8
modeLabel.Font = Enum.Font.Code
modeLabel.TextTransparency = 0.3
modeLabel.TextXAlignment = Enum.TextXAlignment.Left
modeLabel.ZIndex = 11
modeLabel.Parent = mainPage

local modeSeg = Instance.new("Frame")
modeSeg.Size = UDim2.fromOffset(186, 26)
modeSeg.Position = UDim2.fromOffset(142, 14)
modeSeg.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
modeSeg.BackgroundTransparency = 0.5
modeSeg.BorderSizePixel = 0
modeSeg.ZIndex = 10
modeSeg.Parent = mainPage

local modeSegCorner = Instance.new("UICorner")
modeSegCorner.CornerRadius = UDim.new(0, 5)
modeSegCorner.Parent = modeSeg

local modeSegStroke = Instance.new("UIStroke")
modeSegStroke.Color = THEME.HACK_GREEN
modeSegStroke.Thickness = 1
modeSegStroke.Transparency = 0.7
modeSegStroke.Parent = modeSeg

local segments = {}
local currentMode = 3

local function refreshSegments()
    for i, seg in ipairs(segments) do
        if i == currentMode then
            seg.BackgroundColor3 = THEME.HACK_GREEN
            seg.BackgroundTransparency = 0
            seg.TextColor3 = Color3.fromRGB(0, 0, 0)
            local st = seg:FindFirstChildOfClass("UIStroke")
            if st then st.Transparency = 0 end
        else
            seg.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
            seg.BackgroundTransparency = 0.4
            seg.TextColor3 = THEME.HACK_GREEN
            local st = seg:FindFirstChildOfClass("UIStroke")
            if st then st.Transparency = 0.75 end
        end
    end
end

for i = 1, 4 do
    local seg = Instance.new("TextButton")
    seg.Size = UDim2.fromOffset(42, 22)
    seg.Position = UDim2.fromOffset(2 + (i - 1) * 45, 2)
    seg.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
    seg.BackgroundTransparency = 0.4
    seg.BorderSizePixel = 0
    seg.Text = tostring(i)
    seg.TextColor3 = THEME.HACK_GREEN
    seg.TextSize = 10
    seg.Font = Enum.Font.Code
    seg.AutoButtonColor = false
    seg.ZIndex = 11
    seg.Parent = modeSeg

    local segCorner = Instance.new("UICorner")
    segCorner.CornerRadius = UDim.new(0, 3)
    segCorner.Parent = seg

    local segStroke = Instance.new("UIStroke")
    segStroke.Color = THEME.HACK_GREEN
    segStroke.Thickness = 1
    segStroke.Transparency = 0.75
    segStroke.Parent = seg

    segments[i] = seg
end

refreshSegments()

local autoButton = Instance.new("TextButton")
autoButton.Size = UDim2.fromOffset(120, 24)
autoButton.Position = UDim2.fromOffset(12, 44)
autoButton.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
autoButton.BackgroundTransparency = 0.4
autoButton.BorderSizePixel = 0
autoButton.Text = "AUTO: OFF"
autoButton.TextColor3 = THEME.HACK_GREEN
autoButton.TextSize = 9
autoButton.Font = Enum.Font.Code
autoButton.AutoButtonColor = false
autoButton.ZIndex = 11
autoButton.Parent = mainPage

local autoCorner = Instance.new("UICorner")
autoCorner.CornerRadius = UDim.new(0, 5)
autoCorner.Parent = autoButton

local autoStroke = Instance.new("UIStroke")
autoStroke.Color = THEME.HACK_GREEN
autoStroke.Thickness = 1
autoStroke.Transparency = 0.6
autoStroke.Parent = autoButton

local autoStartEnabled = false

local function refreshAutoButton()
    if autoStartEnabled then
        autoButton.Text = "AUTO: ON"
        autoButton.BackgroundColor3 = THEME.HACK_GREEN
        autoButton.TextColor3 = Color3.fromRGB(0, 0, 0)
        autoStroke.Transparency = 0.15
    else
        autoButton.Text = "AUTO: OFF"
        autoButton.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
        autoButton.TextColor3 = THEME.HACK_GREEN
        autoStroke.Transparency = 0.6
    end
end

refreshAutoButton()

local spamButton = Instance.new("TextButton")
spamButton.Size = UDim2.fromOffset(186, 24)
spamButton.Position = UDim2.fromOffset(142, 44)
spamButton.BackgroundColor3 = Color3.fromRGB(25, 0, 15)
spamButton.BackgroundTransparency = 0.4
spamButton.BorderSizePixel = 0
spamButton.Text = "SPAM: OFF"
spamButton.TextColor3 = THEME.MAGENTA
spamButton.TextSize = 9
spamButton.Font = Enum.Font.Code
spamButton.AutoButtonColor = false
spamButton.ZIndex = 11
spamButton.Parent = mainPage

local spamCorner = Instance.new("UICorner")
spamCorner.CornerRadius = UDim.new(0, 5)
spamCorner.Parent = spamButton

local spamStroke = Instance.new("UIStroke")
spamStroke.Color = THEME.MAGENTA
spamStroke.Thickness = 1
spamStroke.Transparency = 0.6
spamStroke.Parent = spamButton

local spamRedeemEnabled = false

local function refreshSpamButton()
    if spamRedeemEnabled then
        spamButton.Text = "SPAM: ON"
        spamButton.BackgroundColor3 = THEME.MAGENTA
        spamButton.TextColor3 = Color3.fromRGB(0, 0, 0)
        spamStroke.Transparency = 0.15
    else
        spamButton.Text = "SPAM: OFF"
        spamButton.BackgroundColor3 = Color3.fromRGB(25, 0, 15)
        spamButton.TextColor3 = THEME.MAGENTA
        spamStroke.Transparency = 0.6
    end
end

refreshSpamButton()

local settingsPage = Instance.new("Frame")
settingsPage.Size = UDim2.new(1, 0, 1, -54)
settingsPage.Position = UDim2.fromOffset(0, 54)
settingsPage.BackgroundTransparency = 1
settingsPage.Visible = false
settingsPage.ZIndex = 9
settingsPage.Parent = root

-- ============================================================
-- ANTI-LAG
-- ============================================================
local antiLagBtn = Instance.new("TextButton")
antiLagBtn.Size = UDim2.fromOffset(316, 26)
antiLagBtn.Position = UDim2.fromOffset(12, 10)
antiLagBtn.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
antiLagBtn.BackgroundTransparency = 0.4
antiLagBtn.BorderSizePixel = 0
antiLagBtn.Text = "ANTI-LAG: OFF"
antiLagBtn.TextColor3 = THEME.HACK_GREEN
antiLagBtn.TextSize = 10
antiLagBtn.Font = Enum.Font.Code
antiLagBtn.AutoButtonColor = false
antiLagBtn.ZIndex = 11
antiLagBtn.Parent = settingsPage

local antiLagCorner = Instance.new("UICorner")
antiLagCorner.CornerRadius = UDim.new(0, 5)
antiLagCorner.Parent = antiLagBtn

local antiLagStroke = Instance.new("UIStroke")
antiLagStroke.Color = THEME.HACK_GREEN
antiLagStroke.Thickness = 1
antiLagStroke.Transparency = 0.6
antiLagStroke.Parent = antiLagBtn

local antiLagEnabled = false
local antiLagDescConn = nil

local _antiLagCache = {}
local _antiLagSeen = {}

local function applyAntiLagDerender(obj)
    if not obj or _antiLagSeen[obj] then return end

    local ok, entry = pcall(function()
        local cache = {}
        if obj:IsA("BasePart") then
            cache.Material = obj.Material
            cache.Reflectance = obj.Reflectance
            cache.CastShadow = obj.CastShadow
            obj.Material = Enum.Material.Plastic
            obj.Reflectance = 0
            obj.CastShadow = false
        elseif obj:IsA("Decal") or obj:IsA("Texture") then
            cache.Transparency = obj.Transparency
            obj.Transparency = 1
        elseif obj:IsA("ParticleEmitter") or obj:IsA("Trail")
            or obj:IsA("Beam") or obj:IsA("Fire")
            or obj:IsA("Smoke") or obj:IsA("Sparkles") then
            cache.Enabled = obj.Enabled
            obj.Enabled = false
        elseif obj:IsA("AnimationController") or obj:IsA("Animator") then
            local tracks = obj:GetPlayingAnimationTracks()
            if #tracks > 0 then
                for _, t in ipairs(tracks) do pcall(function() t:Stop(0) end) end
                cache.StoppedTracks = true
            end
        end
        return cache
    end)

    if ok and entry then
        _antiLagCache[obj] = entry
        _antiLagSeen[obj] = true
    end
end

local function restoreAntiLagOriginal(obj)
    local cache = _antiLagCache[obj]
    if not cache then return end
    pcall(function()
        if cache.Material ~= nil and obj:IsA("BasePart") then
            obj.Material = cache.Material
        end
        if cache.Reflectance ~= nil and obj:IsA("BasePart") then
            obj.Reflectance = cache.Reflectance
        end
        if cache.CastShadow ~= nil and obj:IsA("BasePart") then
            obj.CastShadow = cache.CastShadow
        end
        if cache.Transparency ~= nil then
            obj.Transparency = cache.Transparency
        end
        if cache.Enabled ~= nil then
            obj.Enabled = cache.Enabled
        end
    end)
    _antiLagCache[obj] = nil
    _antiLagSeen[obj] = nil
end

local function enableAntiLag()
    antiLagEnabled = true

    runMatrix = false
    runSweep = false
    runAura = false
    pcall(function() visualEffects:Destroy() end)
    auraStroke.Transparency = 1
    bgBase.BackgroundTransparency = 1
    root.BackgroundTransparency = 0.5

    task.spawn(function()
        local descs = Workspace:GetDescendants()
        local i = 0
        local total = #descs
        while i < total and antiLagEnabled do
            for _ = 1, 200 do
                i = i + 1
                if i > total then break end
                applyAntiLagDerender(descs[i])
            end
            task.wait()
        end
    end)

    if antiLagDescConn then antiLagDescConn:Disconnect() end
    antiLagDescConn = Workspace.DescendantAdded:Connect(function(obj)
        if antiLagEnabled then applyAntiLagDerender(obj) end
    end)
end

local function disableAntiLag()
    antiLagEnabled = false
    if antiLagDescConn then
        antiLagDescConn:Disconnect()
        antiLagDescConn = nil
    end

    task.spawn(function()
        local list = {}
        for inst in pairs(_antiLagCache) do list[#list+1] = inst end
        local i = 0
        while i < #list do
            for _ = 1, 200 do
                i = i + 1
                if i > #list then break end
                restoreAntiLagOriginal(list[i])
            end
            task.wait()
        end
    end)

    auraStroke.Transparency = 0.4
    bgBase.BackgroundTransparency = 0
    root.BackgroundTransparency = 1
end

local function refreshAntiLag()
    if antiLagEnabled then
        antiLagBtn.Text = "ANTI-LAG: ON"
        antiLagBtn.BackgroundColor3 = THEME.HACK_GREEN
        antiLagBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
        antiLagStroke.Transparency = 0.15
    else
        antiLagBtn.Text = "ANTI-LAG: OFF"
        antiLagBtn.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
        antiLagBtn.TextColor3 = THEME.HACK_GREEN
        antiLagStroke.Transparency = 0.6
    end
end

antiLagBtn.MouseButton1Click:Connect(function()
    if antiLagEnabled then
        disableAntiLag()
    else
        enableAntiLag()
    end
    refreshAntiLag()
    logSetting("anti-lag", antiLagEnabled)
end)

LP.CharacterAdded:Connect(function(char)
    if not antiLagEnabled then return end
    local ok, hrp = pcall(function()
        return char:WaitForChild("HumanoidRootPart", 10)
    end)
    if ok and hrp and antiLagEnabled then
        for _, d in ipairs(char:GetDescendants()) do
            if antiLagEnabled then applyAntiLagDerender(d) end
        end
        char.DescendantAdded:Connect(function(d)
            if antiLagEnabled then applyAntiLagDerender(d) end
        end)
    end
end)

-- Camera Settings (FOV only)
local camLabel = Instance.new("TextLabel")
camLabel.Size = UDim2.fromOffset(100, 10)
camLabel.Position = UDim2.fromOffset(12, 44)
camLabel.BackgroundTransparency = 1
camLabel.Text = "> CAMERA"
camLabel.TextColor3 = THEME.HACK_GREEN
camLabel.TextSize = 9
camLabel.Font = Enum.Font.Code
camLabel.ZIndex = 11
camLabel.Parent = settingsPage

local fovBtn = Instance.new("TextButton")
fovBtn.Size = UDim2.fromOffset(316, 28)
fovBtn.Position = UDim2.fromOffset(12, 56)
fovBtn.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
fovBtn.BackgroundTransparency = 0.4
fovBtn.BorderSizePixel = 0
fovBtn.Text = "FOV: OFF"
fovBtn.TextColor3 = THEME.HACK_GREEN
fovBtn.Font = Enum.Font.Code
fovBtn.TextSize = 10
fovBtn.AutoButtonColor = false
fovBtn.ZIndex = 11
fovBtn.Parent = settingsPage

local fovCorner = Instance.new("UICorner")
fovCorner.CornerRadius = UDim.new(0, 5)
fovCorner.Parent = fovBtn

local fovStroke = Instance.new("UIStroke")
fovStroke.Color = THEME.HACK_GREEN
fovStroke.Thickness = 1
fovStroke.Transparency = 0.6
fovStroke.Parent = fovBtn

local fovEnabled = false
local fovValue = 120

fovBtn.MouseButton1Click:Connect(function()
    fovEnabled = not fovEnabled
    fovBtn.Text = fovEnabled and "FOV: ON" or "FOV: OFF"
    fovBtn.BackgroundColor3 = fovEnabled and THEME.HACK_GREEN or Color3.fromRGB(0, 15, 5)
    fovBtn.TextColor3 = fovEnabled and Color3.fromRGB(0,0,0) or THEME.HACK_GREEN

    if fovEnabled then
        Workspace.CurrentCamera.FieldOfView = fovValue
    else
        Workspace.CurrentCamera.FieldOfView = 70
    end
end)

-- Outfits
local outfitLabel = Instance.new("TextLabel")
outfitLabel.Size = UDim2.fromOffset(100, 10)
outfitLabel.Position = UDim2.fromOffset(12, 90)
outfitLabel.BackgroundTransparency = 1
outfitLabel.Text = "> OUTFITS"
outfitLabel.TextColor3 = THEME.HACK_GREEN
outfitLabel.TextSize = 9
outfitLabel.Font = Enum.Font.Code
outfitLabel.ZIndex = 11
outfitLabel.Parent = settingsPage

local outfitBtn = Instance.new("TextButton")
outfitBtn.Size = UDim2.fromOffset(150, 28)
outfitBtn.Position = UDim2.fromOffset(12, 102)
outfitBtn.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
outfitBtn.BackgroundTransparency = 0.4
outfitBtn.BorderSizePixel = 0
outfitBtn.Text = "CHANGE OUTFIT"
outfitBtn.TextColor3 = THEME.HACK_GREEN
outfitBtn.Font = Enum.Font.Code
outfitBtn.TextSize = 10
outfitBtn.AutoButtonColor = false
outfitBtn.ZIndex = 11
outfitBtn.Parent = settingsPage

local outfitCorner = Instance.new("UICorner")
outfitCorner.CornerRadius = UDim.new(0, 5)
outfitCorner.Parent = outfitBtn

local outfitStroke = Instance.new("UIStroke")
outfitStroke.Color = THEME.HACK_GREEN
outfitStroke.Thickness = 1
outfitStroke.Transparency = 0.6
outfitStroke.Parent = outfitBtn

local resetOutfitBtn = Instance.new("TextButton")
resetOutfitBtn.Size = UDim2.fromOffset(150, 28)
resetOutfitBtn.Position = UDim2.fromOffset(178, 102)
resetOutfitBtn.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
resetOutfitBtn.BackgroundTransparency = 0.4
resetOutfitBtn.BorderSizePixel = 0
resetOutfitBtn.Text = "RESET AVATAR"
resetOutfitBtn.TextColor3 = THEME.HACK_GREEN
resetOutfitBtn.Font = Enum.Font.Code
resetOutfitBtn.TextSize = 10
resetOutfitBtn.AutoButtonColor = false
resetOutfitBtn.ZIndex = 11
resetOutfitBtn.Parent = settingsPage

local resetOutfitCorner = Instance.new("UICorner")
resetOutfitCorner.CornerRadius = UDim.new(0, 5)
resetOutfitCorner.Parent = resetOutfitBtn

local resetOutfitStroke = Instance.new("UIStroke")
resetOutfitStroke.Color = THEME.HACK_GREEN
resetOutfitStroke.Thickness = 1
resetOutfitStroke.Transparency = 0.6
resetOutfitStroke.Parent = resetOutfitBtn

local currentOutfit = 1
local OUTFITS = {
    { shirt = 9683332638, pants = 93182020184041, head = 134079402 },
    { shirt = 11926549070, pants = 13189494471, head = 16673245747 },
    { shirt = 123181702116947, pants = 93330291631062, head = 134079402 }
}

outfitBtn.MouseButton1Click:Connect(function()
    local c = LP.Character
    if not c then return end
    local outfit = OUTFITS[currentOutfit]

    local shirt = c:FindFirstChildOfClass("Shirt") or Instance.new("Shirt", c)
    shirt.ShirtTemplate = "rbxassetid://" .. outfit.shirt

    local pants = c:FindFirstChildOfClass("Pants") or Instance.new("Pants", c)
    pants.PantsTemplate = "rbxassetid://" .. outfit.pants

    local head = c:FindFirstChild("Head")
    if head and head:IsA("MeshPart") then
        head.MeshId = "rbxassetid://" .. outfit.head
    end

    logInfo("Applied outfit " .. currentOutfit)
    currentOutfit = (currentOutfit % #OUTFITS) + 1
end)

resetOutfitBtn.MouseButton1Click:Connect(function()
    local c = LP.Character
    if not c then return end
    local desc = c:GetDescendants()
    for _, v in ipairs(desc) do
        if v:IsA("Shirt") or v:IsA("Pants") then
            v:Destroy()
        elseif v:IsA("Accessory") then
            v:Destroy()
        elseif v.Name == "Head" and v:IsA("MeshPart") then
            v.MeshId = "rbxasset://fonts/head.mesh"
        end
    end
    logInfo("Avatar reset")
end)

-- Animation Pack Changer
local animLabel = Instance.new("TextLabel")
animLabel.Size = UDim2.fromOffset(100, 10)
animLabel.Position = UDim2.fromOffset(12, 138)
animLabel.BackgroundTransparency = 1
animLabel.Text = "> ANIMATIONS"
animLabel.TextColor3 = THEME.HACK_GREEN
animLabel.TextSize = 9
animLabel.Font = Enum.Font.Code
animLabel.ZIndex = 11
animLabel.Parent = settingsPage

local ANIM_PACKS = {
    ["Off"] = nil,
    ["Zombie"] = { idle1="rbxassetid://616158929", idle2="rbxassetid://616160636", walk="rbxassetid://616168032", run="rbxassetid://616163682", jump="rbxassetid://616161997", fall="rbxassetid://616157476", climb="rbxassetid://616156119", swim="rbxassetid://616165109", swimidle="rbxassetid://616166655" },
    ["Ninja"] = { idle1="rbxassetid://656117400", idle2="rbxassetid://656117400", walk="rbxassetid://656121766", run="rbxassetid://656118852", jump="rbxassetid://656117878", fall="rbxassetid://656115606", climb="rbxassetid://656114359", swim="rbxassetid://656117400", swimidle="rbxassetid://656117400" },
    ["Knight"] = { idle1="rbxassetid://657595757", idle2="rbxassetid://657595757", walk="rbxassetid://657552124", run="rbxassetid://657564596", jump="rbxassetid://658409194", fall="rbxassetid://657600338", climb="rbxassetid://658360781", swim="rbxassetid://657595757", swimidle="rbxassetid://657595757" },
    ["Elder"] = { idle1="rbxassetid://845397899", idle2="rbxassetid://845397899", walk="rbxassetid://845403856", run="rbxassetid://845386501", jump="rbxassetid://845398858", fall="rbxassetid://845397673", climb="rbxassetid://845392038", swim="rbxassetid://845397899", swimidle="rbxassetid://845397899" },
    ["Levitate"] = { idle1="rbxassetid://616006778", idle2="rbxassetid://616006778", walk="rbxassetid://616013216", run="rbxassetid://616013216", jump="rbxassetid://616008936", fall="rbxassetid://616005863", climb="rbxassetid://616003713", swim="rbxassetid://616006778", swimidle="rbxassetid://616006778" },
    ["Astronaut"] = { idle1="rbxassetid://891621366", idle2="rbxassetid://891621366", walk="rbxassetid://891636393", run="rbxassetid://891636393", jump="rbxassetid://891627522", fall="rbxassetid://891617961", climb="rbxassetid://891609353", swim="rbxassetid://891621366", swimidle="rbxassetid://891621366" },
    ["Pirate"] = { idle1="rbxassetid://750781874", idle2="rbxassetid://750781874", walk="rbxassetid://750785693", run="rbxassetid://750783738", jump="rbxassetid://750782230", fall="rbxassetid://750780242", climb="rbxassetid://750779899", swim="rbxassetid://750781874", swimidle="rbxassetid://750781874" },
    ["Toy"] = { idle1="rbxassetid://782841498", idle2="rbxassetid://782841498", walk="rbxassetid://782843345", run="rbxassetid://782842708", jump="rbxassetid://782847020", fall="rbxassetid://782846423", climb="rbxassetid://782843869", swim="rbxassetid://782841498", swimidle="rbxassetid://782841498" },
    ["Vampire"] = { idle1="rbxassetid://1083445855", idle2="rbxassetid://1083445855", walk="rbxassetid://1083473930", run="rbxassetid://1083462077", jump="rbxassetid://1083455352", fall="rbxassetid://1083443587", climb="rbxassetid://1083439238", swim="rbxassetid://1083445855", swimidle="rbxassetid://1083445855" },
    ["Werewolf"] = { idle1="rbxassetid://1083195517", idle2="rbxassetid://1083195517", walk="rbxassetid://1083178339", run="rbxassetid://1083216690", jump="rbxassetid://1083218792", fall="rbxassetid://1083189019", climb="rbxassetid://1083182000", swim="rbxassetid://1083195517", swimidle="rbxassetid://1083195517" },
    ["Rthro"] = { idle1="rbxassetid://2510196951", idle2="rbxassetid://2510196951", walk="rbxassetid://2510202577", run="rbxassetid://2510198475", jump="rbxassetid://2510197830", fall="rbxassetid://2510195892", climb="rbxassetid://2510192778", swim="rbxassetid://2510196951", swimidle="rbxassetid://2510196951" },
    ["Stylish"] = { idle1="rbxassetid://616136790", idle2="rbxassetid://616136790", walk="rbxassetid://616146177", run="rbxassetid://616140816", jump="rbxassetid://616139451", fall="rbxassetid://616134815", climb="rbxassetid://616133594", swim="rbxassetid://616136790", swimidle="rbxassetid://616136790" }
}

local ANIM_ORDER = {"Off", "Zombie", "Ninja", "Knight", "Elder", "Levitate", "Astronaut", "Pirate", "Toy", "Vampire", "Werewolf", "Rthro", "Stylish"}
local currentAnimIndex = 1
local origAnims = nil
local animLoopConn = nil

local function saveOrigAnims()
    local char = LP.Character
    if not char then return end
    local animate = char:FindFirstChild("Animate")
    if not animate then return end

    local function g(obj) return obj and obj.AnimationId or nil end
    origAnims = {
        idle1 = g(animate.idle and animate.idle.Animation1),
        idle2 = g(animate.idle and animate.idle.Animation2),
        walk  = g(animate.walk and animate.walk.WalkAnim),
        run   = g(animate.run and animate.run.RunAnim),
        jump  = g(animate.jump and animate.jump.JumpAnim),
        fall  = g(animate.fall and animate.fall.FallAnim),
        climb = g(animate.climb and animate.climb.ClimbAnim),
        swim  = g(animate.swim and animate.swim.Swim),
        swimidle = g(animate.swimidle and animate.swimidle.SwimIdle),
    }
end

local function applyAnimPack(packName)
    local char = LP.Character
    if not char then return end
    local animate = char:FindFirstChild("Animate")
    if not animate then return end

    if animLoopConn then animLoopConn:Disconnect(); animLoopConn = nil end

    if packName == "Off" then
        if origAnims then
            local function s(obj, id) if obj then obj.AnimationId = id end end
            s(animate.idle and animate.idle.Animation1, origAnims.idle1)
            s(animate.idle and animate.idle.Animation2, origAnims.idle2)
            s(animate.walk and animate.walk.WalkAnim, origAnims.walk)
            s(animate.run and animate.run.RunAnim, origAnims.run)
            s(animate.jump and animate.jump.JumpAnim, origAnims.jump)
            s(animate.fall and animate.fall.FallAnim, origAnims.fall)
            s(animate.climb and animate.climb.ClimbAnim, origAnims.climb)
            s(animate.swim and animate.swim.Swim, origAnims.swim)
            s(animate.swimidle and animate.swimidle.SwimIdle, origAnims.swimidle)
        end
        return
    end

    local pack = ANIM_PACKS[packName]
    if not pack then return end

    animLoopConn = RunService.Heartbeat:Connect(function()
        local c = LP.Character
        if not c then return end
        local anim = c:FindFirstChild("Animate")
        if not anim then return end

        local function s(obj, id) if obj then obj.AnimationId = id end end
        s(anim.idle and anim.idle.Animation1, pack.idle1)
        s(anim.idle and anim.idle.Animation2, pack.idle2)
        s(anim.walk and anim.walk.WalkAnim, pack.walk)
        s(anim.run and anim.run.RunAnim, pack.run)
        s(anim.jump and anim.jump.JumpAnim, pack.jump)
        s(anim.fall and anim.fall.FallAnim, pack.fall)
        s(anim.climb and anim.climb.ClimbAnim, pack.climb)
        s(anim.swim and anim.swim.Swim, pack.swim)
        s(anim.swimidle and anim.swimidle.SwimIdle, pack.swimidle)
    end)
end

local animLeftBtn = Instance.new("TextButton")
animLeftBtn.Size = UDim2.fromOffset(28, 28)
animLeftBtn.Position = UDim2.fromOffset(12, 150)
animLeftBtn.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
animLeftBtn.BorderSizePixel = 0
animLeftBtn.Text = "<"
animLeftBtn.TextColor3 = THEME.HACK_GREEN
animLeftBtn.Font = Enum.Font.Code
animLeftBtn.TextSize = 14
animLeftBtn.AutoButtonColor = false
animLeftBtn.ZIndex = 11
animLeftBtn.Parent = settingsPage

local animLeftCorner = Instance.new("UICorner")
animLeftCorner.CornerRadius = UDim.new(0, 5)
animLeftCorner.Parent = animLeftBtn

local animLeftStroke = Instance.new("UIStroke")
animLeftStroke.Color = THEME.HACK_GREEN
animLeftStroke.Thickness = 1
animLeftStroke.Transparency = 0.6
animLeftStroke.Parent = animLeftBtn

local animDisplay = Instance.new("TextLabel")
animDisplay.Size = UDim2.fromOffset(256, 28)
animDisplay.Position = UDim2.fromOffset(42, 150)
animDisplay.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
animDisplay.BackgroundTransparency = 0.5
animDisplay.BorderSizePixel = 0
animDisplay.Text = "Off"
animDisplay.TextColor3 = THEME.HACK_GREEN
animDisplay.Font = Enum.Font.Code
animDisplay.TextSize = 12
animDisplay.ZIndex = 11
animDisplay.Parent = settingsPage

local animDisplayCorner = Instance.new("UICorner")
animDisplayCorner.CornerRadius = UDim.new(0, 5)
animDisplayCorner.Parent = animDisplay

local animDisplayStroke = Instance.new("UIStroke")
animDisplayStroke.Color = THEME.HACK_GREEN
animDisplayStroke.Thickness = 1
animDisplayStroke.Transparency = 0.6
animDisplayStroke.Parent = animDisplay

local animRightBtn = Instance.new("TextButton")
animRightBtn.Size = UDim2.fromOffset(28, 28)
animRightBtn.Position = UDim2.fromOffset(300, 150)
animRightBtn.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
animRightBtn.BorderSizePixel = 0
animRightBtn.Text = ">"
animRightBtn.TextColor3 = THEME.HACK_GREEN
animRightBtn.Font = Enum.Font.Code
animRightBtn.TextSize = 14
animRightBtn.AutoButtonColor = false
animRightBtn.ZIndex = 11
animRightBtn.Parent = settingsPage

local animRightCorner = Instance.new("UICorner")
animRightCorner.CornerRadius = UDim.new(0, 5)
animRightCorner.Parent = animRightBtn

local animRightStroke = Instance.new("UIStroke")
animRightStroke.Color = THEME.HACK_GREEN
animRightStroke.Thickness = 1
animRightStroke.Transparency = 0.6
animRightStroke.Parent = animRightBtn

animLeftBtn.MouseButton1Click:Connect(function()
    currentAnimIndex = currentAnimIndex - 1
    if currentAnimIndex < 1 then currentAnimIndex = #ANIM_ORDER end
    local pack = ANIM_ORDER[currentAnimIndex]
    animDisplay.Text = pack
    applyAnimPack(pack)
end)

animRightBtn.MouseButton1Click:Connect(function()
    currentAnimIndex = currentAnimIndex + 1
    if currentAnimIndex > #ANIM_ORDER then currentAnimIndex = 1 end
    local pack = ANIM_ORDER[currentAnimIndex]
    animDisplay.Text = pack
    applyAnimPack(pack)
end)

-- ============================================================
-- LOGS PAGE
-- ============================================================
local logPage = Instance.new("Frame")
logPage.Size = UDim2.new(1, 0, 1, -54)
logPage.Position = UDim2.fromOffset(0, 54)
logPage.BackgroundTransparency = 1
logPage.Visible = false
logPage.ZIndex = 9
logPage.Parent = root

logScroll.Parent = logPage

local function switchTab(tab)
    if tab == "main" then
        mainPage.Visible = true
        settingsPage.Visible = false
        logPage.Visible = false
        logScroll.Visible = false
        tabMain.BackgroundColor3 = Color3.fromRGB(0, 30, 10)
        tabMain.TextColor3 = THEME.HACK_BRIGHT
        tabSettings.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
        tabSettings.TextColor3 = THEME.HACK_GREEN
        tabLogs.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
        tabLogs.TextColor3 = THEME.HACK_GREEN
    elseif tab == "settings" then
        mainPage.Visible = false
        settingsPage.Visible = true
        logPage.Visible = false
        logScroll.Visible = false
        tabSettings.BackgroundColor3 = Color3.fromRGB(0, 30, 10)
        tabSettings.TextColor3 = THEME.HACK_BRIGHT
        tabMain.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
        tabMain.TextColor3 = THEME.HACK_GREEN
        tabLogs.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
        tabLogs.TextColor3 = THEME.HACK_GREEN
    else
        mainPage.Visible = false
        settingsPage.Visible = false
        logPage.Visible = true
        logScroll.Visible = true
        tabLogs.BackgroundColor3 = Color3.fromRGB(0, 30, 10)
        tabLogs.TextColor3 = THEME.HACK_BRIGHT
        tabMain.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
        tabMain.TextColor3 = THEME.HACK_GREEN
        tabSettings.BackgroundColor3 = Color3.fromRGB(0, 15, 5)
        tabSettings.TextColor3 = THEME.HACK_GREEN
    end
end

tabMain.MouseButton1Click:Connect(function() switchTab("main") end)
tabSettings.MouseButton1Click:Connect(function() switchTab("settings") end)
tabLogs.MouseButton1Click:Connect(function() switchTab("logs") end)

local dragging, dragInput, dragStart, startPosRoot

local function updateDrag(input)
    local delta = input.Position - dragStart
    root.Position = UDim2.new(startPosRoot.X.Scale, startPosRoot.X.Offset + delta.X, startPosRoot.Y.Scale, startPosRoot.Y.Offset + delta.Y)
end

local function isOverInteractive(pos)
    local blocked = false
    pcall(function()
        local objs = PlayerGui:GetGuiObjectsAtPosition(pos.X, pos.Y)
        if objs then
            for _, obj in ipairs(objs) do
                if obj:IsA("TextBox") or obj:IsA("TextButton") then
                    blocked = true
                    break
                end
            end
        end
    end)
    return blocked
end

local function beginDrag(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
    if isOverInteractive(input.Position) then return end
    dragging = true
    dragStart = input.Position
    startPosRoot = root.Position
    input.Changed:Connect(function()
        if input.UserInputState == Enum.UserInputState.End or input.UserInputState == Enum.UserInputState.Cancel then
            dragging = false
            dragInput = nil
        end
    end)
end

root.InputBegan:Connect(beginDrag)

root.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then updateDrag(input) end
end)

-- ============================================================
-- MINIMIZE / RESTORE
-- ============================================================
local isMinimized = false

local miniTab = Instance.new("TextButton")
miniTab.Size = UDim2.fromOffset(120, 26)
miniTab.Position = UDim2.new(0, 20, 0, 60)
miniTab.BackgroundColor3 = Color3.fromRGB(0, 20, 8)
miniTab.BackgroundTransparency = 0.1
miniTab.BorderSizePixel = 0
miniTab.Text = "▲ PHANTOM"
miniTab.TextColor3 = THEME.HACK_BRIGHT
miniTab.Font = Enum.Font.Code
miniTab.TextSize = 11
miniTab.AutoButtonColor = false
miniTab.Visible = false
miniTab.ZIndex = 30
miniTab.Parent = screenGui

local miniCorner = Instance.new("UICorner")
miniCorner.CornerRadius = UDim.new(0, 6)
miniCorner.Parent = miniTab

local miniStroke = Instance.new("UIStroke")
miniStroke.Color = THEME.HACK_GREEN
miniStroke.Thickness = 1
miniStroke.Transparency = 0.35
miniStroke.Parent = miniTab

local miniGrad = Instance.new("UIGradient")
miniGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 30, 10)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 8, 3)),
})
miniGrad.Rotation = 90
miniGrad.Parent = miniTab

local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.fromOffset(20, 20)
minBtn.Position = UDim2.new(1, -26, 0, 6)
minBtn.BackgroundColor3 = Color3.fromRGB(0, 20, 8)
minBtn.BackgroundTransparency = 0.3
minBtn.BorderSizePixel = 0
minBtn.Text = "–"
minBtn.TextColor3 = THEME.HACK_GREEN
minBtn.Font = Enum.Font.Code
minBtn.TextSize = 16
minBtn.AutoButtonColor = false
minBtn.ZIndex = 25
minBtn.Parent = root

local minBtnCorner = Instance.new("UICorner")
minBtnCorner.CornerRadius = UDim.new(0, 4)
minBtnCorner.Parent = minBtn

local minBtnStroke = Instance.new("UIStroke")
minBtnStroke.Color = THEME.HACK_GREEN
minBtnStroke.Thickness = 1
minBtnStroke.Transparency = 0.55
minBtnStroke.Parent = minBtn

local function minimizeGui()
    if isMinimized then return end
    isMinimized = true
    root.Visible = false
    miniTab.Visible = true
end

local function restoreGui()
    if not isMinimized then return end
    isMinimized = false
    root.Visible = true
    miniTab.Visible = false
end

minBtn.MouseButton1Click:Connect(minimizeGui)
miniTab.MouseButton1Click:Connect(restoreGui)

do
    local mDragging, mDragStart, mStartPos = false, nil, nil
    miniTab.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            mDragging = true
            mDragStart = input.Position
            mStartPos = miniTab.Position
            local conn
            conn = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    mDragging = false
                    if conn then conn:Disconnect(); conn = nil end
                end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if not mDragging or not mDragStart or not mStartPos then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - mDragStart
            miniTab.Position = UDim2.new(
                mStartPos.X.Scale, mStartPos.X.Offset + delta.X,
                mStartPos.Y.Scale, mStartPos.Y.Offset + delta.Y
            )
        end
    end)
end

local TRIGGER_PHRASES = {
    "usecode", "usethecode", "usethiscode", "thecodeis", "codeis", "codewas",
    "typecode", "typethecode", "entercode", "enterthecode", "redeemcode",
    "redeemthecode", "inputcode", "inputthecode", "newcode", "freecode",
    "dropcode", "getcode", "grabcode", "claimcode", "codesare", "codesin",
    "codeshere", "pastecode", "codes",
}

local LEET_MAP = {["0"]="o",["1"]="i",["3"]="e",["4"]="a",["5"]="s",["7"]="t",["8"]="b"}

local function normalizeForTrigger(s)
    s = tostring(s or ""):lower()
    s = s:gsub(".", function(c) return LEET_MAP[c] or c end)
    s = s:gsub("[^%a]", "")
    return s
end

local function matchesTrigger(text)
    local s = normalizeForTrigger(text)
    if s == "" then return false end
    for _, phrase in ipairs(TRIGGER_PHRASES) do
        if s:find(phrase, 1, true) then return true end
    end
    return false
end

local scanning = false
local buffer = {}

local function isValidCode(msg)
    return msg:match("^[A-Za-z0-9]+$") ~= nil
end

local function processBufferNormal()
    if not scanning then return end
    while #buffer >= currentMode do
        local combined = table.concat(buffer, "", 1, currentMode)
        buffer = {}
        logInfo("sending " .. combined)
        typeAndSubmitCode(combined)
    end
end

local function processBufferSpam()
    if not scanning then return end
    local combined = table.concat(buffer, "", 1, #buffer)
    if combined == "" then return end
    logSpam("flush " .. #buffer .. "/" .. currentMode .. " -> " .. combined)
    typeAndSubmitCode(combined)
    if #buffer >= currentMode then
        buffer = {}
        logSpam("cycle reset")
    end
end

local function startScan(silent)
    if scanning then return end
    scanning = true
    scanButton.Text = "SCANNING..."
    scanButton.TextColor3 = THEME.GREEN
    statusText.Text = "[ ACTIVE ]"
    statusText.TextColor3 = THEME.GREEN
    buffer = {}
    if not silent then logInfo("scan started") end
end

local function stopScan()
    if not scanning then return end
    scanning = false
    scanButton.Text = "START SCAN"
    scanButton.TextColor3 = THEME.HACK_BRIGHT
    statusText.Text = "[ IDLE ]"
    statusText.TextColor3 = THEME.HACK_GREEN
    buffer = {}
    logInfo("scan stopped")
end

local function onAnnouncement(txt)
    if not txt or txt == "" then return end
    local first = string.byte(txt, 1)
    local last = string.byte(txt, -1)
    local msg = txt
    if first == 32 or first == 9 or first == 10 or first == 13
        or last == 32 or last == 9 or last == 10 or last == 13 then
        msg = txt:match("^%s*(.-)%s*$")
    end

    if scanning and msg and #msg > 0 and isValidCode(msg) then
        if spamRedeemEnabled then
            table.insert(buffer, msg)
            processBufferSpam()
        else
            typeAndSubmitCode(msg)
            buffer = {}
        end
    end

    logGame(txt)
    if autoStartEnabled and not scanning and matchesTrigger(txt) then
        logAuto("trigger " .. txt)
        startScan(true)
    end
    if scanning and msg and #msg > 0 and isValidCode(msg) then
        logInfo("caught " .. msg)
    end
end

scanButton.MouseButton1Click:Connect(function()
    if scanning then stopScan() else startScan() end
end)

for i, seg in ipairs(segments) do
    seg.MouseButton1Click:Connect(function()
        currentMode = i
        refreshSegments()
        logSetting("chain", i)
    end)
end

autoButton.MouseButton1Click:Connect(function()
    autoStartEnabled = not autoStartEnabled
    refreshAutoButton()
    logSetting("auto", autoStartEnabled)
end)

spamButton.MouseButton1Click:Connect(function()
    spamRedeemEnabled = not spamRedeemEnabled
    refreshSpamButton()
    logSetting("spam", spamRedeemEnabled)
end)

if notifyRemote then
    notifyRemote.OnClientEvent:Connect(function(txt, ...)
        onAnnouncement(txt)
    end)
else
    warn("[Phantom Redeemer] No notify remote - announcements not captured.")
end

task.spawn(function()
    local pg = PlayerGui
    for _, obj in ipairs(pg:GetDescendants()) do
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            obj:GetPropertyChangedSignal("Text"):Connect(function()
                checkRedeemFeedback(obj.Text)
            end)
        end
    end
    pg.DescendantAdded:Connect(function(obj)
        if obj:IsA("TextLabel") or obj:IsA("TextButton") then
            obj:GetPropertyChangedSignal("Text"):Connect(function()
                checkRedeemFeedback(obj.Text)
            end)
        end
    end)
end)

task.spawn(function()
    local char = LP.Character or LP.CharacterAdded:Wait()
    char:WaitForChild("Humanoid", 5)
    task.wait(1)
    saveOrigAnims()
end)

print("[Phantom Redeemer] Ready. Click 'START SCAN' to begin.")
