--[[
    FlashlightFlash.client.lua
    --------------------------------------------------------------------
    Клиентский скрипт «вспышка фонариком» для R6.

    Логика:
      * пока игрок зажимает ПКМ — проигрываются анимации:
          1) DRAW_ANIM_ID  — «доставание» фонарика (1 раз);
          2) HOLD_ANIM_ID  — «держание» фонарика (зацикленная);
        отпускание ПКМ — анимации останавливаются.
      * нажатие ЛКМ — фонарик включается на FLASH_DURATION секунд
        и светит туда, куда смотрит камера;
      * есть настраиваемое затухание в начале (FADE_IN_TIME)
        и в конце (FADE_OUT_TIME) — поставьте 0, чтобы было резко;
      * после короткого кулдауна можно делать новую вспышку.

    Размещение: StarterPlayer -> StarterPlayerScripts (LocalScript).
    Работает на R6-персонаже (использует Torso как точку крепления).
--------------------------------------------------------------------]]

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")
local Workspace        = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local camera      = Workspace.CurrentCamera

----------------------------------------------------------------------
-- Настройки света
----------------------------------------------------------------------
local FLASH_DURATION = 1.5    -- сколько секунд горит вспышка (включая fade-in/out)
local FLASH_COOLDOWN = 0.5    -- задержка после вспышки до следующей
local FLASH_RANGE    = 120    -- дальность света в studs
local FLASH_ANGLE    = 60     -- угол конуса SpotLight (полный)
local FLASH_BRIGHT   = 8      -- максимальная яркость SpotLight (1..10)

-- Затухание. Поставьте 0, чтобы вспышка включалась/выключалась мгновенно.
local FADE_IN_TIME   = 0      -- секунд на разгорание в начале
local FADE_OUT_TIME  = 0      -- секунд на затухание в конце

----------------------------------------------------------------------
-- Настройки анимаций
----------------------------------------------------------------------
local DRAW_ANIM_ID = "rbxassetid://82265148061463"  -- «доставание» (играется 1 раз)
local HOLD_ANIM_ID = "rbxassetid://0"               -- «держание» (зацикленная)
                                                    -- ВПИШИ СВОЙ ID СЮДА

local DRAW_ANIM_SPEED = 1   -- скорость воспроизведения «доставания»
local HOLD_ANIM_SPEED = 1   -- скорость воспроизведения «держания»

----------------------------------------------------------------------
-- Состояние
----------------------------------------------------------------------
local attachment
local spotLight
local activeUntil = 0
local cooldownEnd = 0
local renderConn
local fadeToken = 0

local drawTrack
local holdTrack
local drawStoppedConn
local rmbHeld = false

----------------------------------------------------------------------
-- Создание света и загрузка анимаций на персонаже
----------------------------------------------------------------------
local function loadAnimations(character)
    local humanoid = character:WaitForChild("Humanoid", 10)
    if not humanoid then return end
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end

    local drawAnim = Instance.new("Animation")
    drawAnim.AnimationId = DRAW_ANIM_ID
    drawTrack = animator:LoadAnimation(drawAnim)
    drawTrack.Looped   = false
    drawTrack.Priority = Enum.AnimationPriority.Action

    -- HOLD грузим только если задан валидный id
    if HOLD_ANIM_ID and HOLD_ANIM_ID ~= "" and HOLD_ANIM_ID ~= "rbxassetid://0" then
        local holdAnim = Instance.new("Animation")
        holdAnim.AnimationId = HOLD_ANIM_ID
        holdTrack = animator:LoadAnimation(holdAnim)
        holdTrack.Looped   = true
        holdTrack.Priority = Enum.AnimationPriority.Action
    end
end

local function setupOnCharacter(character)
    if attachment then
        attachment:Destroy()
        attachment = nil
        spotLight = nil
    end
    if renderConn then
        renderConn:Disconnect()
        renderConn = nil
    end
    if drawStoppedConn then
        drawStoppedConn:Disconnect()
        drawStoppedConn = nil
    end
    drawTrack = nil
    holdTrack = nil
    rmbHeld   = false

    local torso = character:WaitForChild("Torso", 10)
    if not torso then return end

    attachment = Instance.new("Attachment")
    attachment.Name   = "FlashFlashlightAttach"
    attachment.Parent = torso

    spotLight = Instance.new("SpotLight")
    spotLight.Name       = "FlashFlashlight"
    spotLight.Range      = FLASH_RANGE
    spotLight.Angle      = FLASH_ANGLE
    spotLight.Brightness = 0
    spotLight.Shadows    = true
    spotLight.Enabled    = false
    spotLight.Face       = Enum.NormalId.Front
    spotLight.Color      = Color3.fromRGB(255, 245, 210)
    spotLight.Parent     = attachment

    renderConn = RunService.RenderStepped:Connect(function()
        if not attachment.Parent then return end
        attachment.WorldCFrame = CFrame.new(
            attachment.WorldPosition,
            attachment.WorldPosition + camera.CFrame.LookVector
        )
    end)

    loadAnimations(character)
end

----------------------------------------------------------------------
-- Анимации: запуск/остановка по ПКМ
----------------------------------------------------------------------
local function startHold()
    if rmbHeld then return end
    if not drawTrack then return end
    rmbHeld = true

    if holdTrack then holdTrack:Stop(0.1) end

    if drawStoppedConn then
        drawStoppedConn:Disconnect()
        drawStoppedConn = nil
    end

    drawTrack:Stop(0)
    drawTrack:Play(0.1, 1, DRAW_ANIM_SPEED)

    drawStoppedConn = drawTrack.Stopped:Connect(function()
        if drawStoppedConn then
            drawStoppedConn:Disconnect()
            drawStoppedConn = nil
        end
        if rmbHeld and holdTrack then
            holdTrack:Play(0.1, 1, HOLD_ANIM_SPEED)
        end
    end)
end

local function stopHold()
    if not rmbHeld then return end
    rmbHeld = false
    if drawStoppedConn then
        drawStoppedConn:Disconnect()
        drawStoppedConn = nil
    end
    if drawTrack then drawTrack:Stop(0.15) end
    if holdTrack then holdTrack:Stop(0.15) end
end

----------------------------------------------------------------------
-- Сама вспышка (ЛКМ)
----------------------------------------------------------------------
local function fadeBrightness(target, duration, token)
    if not spotLight then return end
    if duration <= 0 then
        spotLight.Brightness = target
        return
    end
    local startValue = spotLight.Brightness
    local elapsed    = 0
    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not spotLight or token ~= fadeToken then
            conn:Disconnect()
            return
        end
        elapsed += dt
        local t = math.clamp(elapsed / duration, 0, 1)
        spotLight.Brightness = startValue + (target - startValue) * t
        if t >= 1 then
            conn:Disconnect()
        end
    end)
end

local function doFlash()
    local now = tick()
    if now < cooldownEnd then return end
    if now < activeUntil then return end
    if not spotLight then return end

    fadeToken += 1
    local myToken = fadeToken

    activeUntil = now + FLASH_DURATION
    spotLight.Enabled = true

    fadeBrightness(FLASH_BRIGHT, FADE_IN_TIME, myToken)

    local fadeOutStart = math.max(0, FLASH_DURATION - FADE_OUT_TIME)
    task.delay(fadeOutStart, function()
        if myToken ~= fadeToken then return end
        fadeBrightness(0, FADE_OUT_TIME, myToken)
    end)

    task.delay(FLASH_DURATION, function()
        if myToken ~= fadeToken then return end
        if not spotLight then return end
        spotLight.Enabled    = false
        spotLight.Brightness = 0
        cooldownEnd = tick() + FLASH_COOLDOWN
    end)
end

----------------------------------------------------------------------
-- Входы
----------------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        doFlash()
    elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
        startHold()
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton2 then
        stopHold()
    end
end)

local function onCharacterAdded(character)
    setupOnCharacter(character)
end

if localPlayer.Character then
    onCharacterAdded(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(onCharacterAdded)
