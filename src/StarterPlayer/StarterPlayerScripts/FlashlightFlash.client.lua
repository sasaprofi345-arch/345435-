--[[
    FlashlightFlash.client.lua
    --------------------------------------------------------------------
    Клиентский скрипт «вспышка фонариком» для R6.

    Логика:
      * игрок целится камерой в нужное место;
      * нажимает ЛКМ — фонарик включается на ~2.5 секунды
        и светит туда, куда смотрит камера;
      * после окончания вспышки наступает короткий кулдаун,
        чтобы нельзя было спамить кнопкой.

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
-- Настройки
----------------------------------------------------------------------
local FLASH_DURATION = 2.5    -- сколько секунд горит вспышка
local FLASH_COOLDOWN = 0.5    -- задержка после вспышки до следующей
local FLASH_RANGE    = 120    -- дальность света в studs
local FLASH_ANGLE    = 60     -- угол конуса SpotLight (полный)
local FLASH_BRIGHT   = 8      -- яркость SpotLight (1..10)
local FADE_IN_TIME   = 0.05   -- короткое нарастание/затухание, чтобы не «щёлкало»
local FADE_OUT_TIME  = 0.25

----------------------------------------------------------------------
-- Состояние
----------------------------------------------------------------------
local attachment  -- Attachment на торсе, к которому крепим SpotLight
local spotLight   -- сам SpotLight
local activeUntil = 0
local cooldownEnd = 0
local renderConn  -- Heartbeat-коннект для постоянной ориентации света по камере

----------------------------------------------------------------------
-- Создание/уничтожение света на персонаже
----------------------------------------------------------------------
local function setupOnCharacter(character)
    -- Снимаем предыдущее, если есть
    if attachment then
        attachment:Destroy()
        attachment = nil
        spotLight = nil
    end
    if renderConn then
        renderConn:Disconnect()
        renderConn = nil
    end

    -- В R6 точка крепления — Torso (в R15 это UpperTorso, но задача про R6)
    local torso = character:WaitForChild("Torso", 10)
    if not torso then return end

    -- Attachment даёт возможность развернуть SpotLight в нужную сторону,
    -- независимо от ориентации торса
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

    -- Каждый кадр поворачиваем attachment так, чтобы он смотрел туда же,
    -- куда смотрит камера. Луч получается «из груди, но в сторону взгляда»,
    -- что для механики «посветить туда, куда смотрит игрок» работает отлично.
    renderConn = RunService.RenderStepped:Connect(function()
        if not attachment.Parent then return end
        local lookCFrame = CFrame.new(
            attachment.WorldPosition,
            attachment.WorldPosition + camera.CFrame.LookVector
        )
        attachment.WorldCFrame = lookCFrame
    end)
end

----------------------------------------------------------------------
-- Сама вспышка
----------------------------------------------------------------------
local function fadeBrightness(target, duration)
    -- Простое ручное «затухание» без TweenService — для свойства Brightness
    -- этого более чем достаточно и проще читается
    if not spotLight then return end
    local start    = spotLight.Brightness
    local elapsed  = 0
    local conn
    conn = RunService.Heartbeat:Connect(function(dt)
        if not spotLight then
            conn:Disconnect()
            return
        end
        elapsed += dt
        local t = math.clamp(elapsed / duration, 0, 1)
        spotLight.Brightness = start + (target - start) * t
        if t >= 1 then
            conn:Disconnect()
        end
    end)
end

local function doFlash()
    local now = tick()
    if now < cooldownEnd then return end          -- ещё кулдаун
    if now < activeUntil then return end          -- уже горит
    if not spotLight then return end

    activeUntil = now + FLASH_DURATION
    spotLight.Enabled    = true
    spotLight.Brightness = 0
    fadeBrightness(FLASH_BRIGHT, FADE_IN_TIME)

    task.delay(FLASH_DURATION - FADE_OUT_TIME, function()
        if not spotLight then return end
        fadeBrightness(0, FADE_OUT_TIME)
    end)

    task.delay(FLASH_DURATION, function()
        if not spotLight then return end
        spotLight.Enabled = false
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
    end
end)

local function onCharacterAdded(character)
    setupOnCharacter(character)
end

if localPlayer.Character then
    onCharacterAdded(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(onCharacterAdded)
