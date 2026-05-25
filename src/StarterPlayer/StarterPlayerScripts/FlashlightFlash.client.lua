--[[
    FlashlightFlash.client.lua
    --------------------------------------------------------------------
    Клиентский скрипт «вспышка фонариком» для R6.

    Логика:
      * игрок целится камерой в нужное место;
      * нажимает ЛКМ — фонарик включается на FLASH_DURATION секунд
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
-- Настройки
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
-- Состояние
----------------------------------------------------------------------
local attachment
local spotLight
local activeUntil = 0
local cooldownEnd = 0
local renderConn
local fadeToken = 0           -- инкрементируется при каждой вспышке, чтобы
                              -- старый fade-цикл не перезаписал новый

----------------------------------------------------------------------
-- Создание света на персонаже
----------------------------------------------------------------------
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

    -- В R6 точка крепления — Torso
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

    -- Каждый кадр поворачиваем attachment туда же, куда смотрит камера —
    -- получается «свет туда, куда направлен взгляд игрока».
    renderConn = RunService.RenderStepped:Connect(function()
        if not attachment.Parent then return end
        attachment.WorldCFrame = CFrame.new(
            attachment.WorldPosition,
            attachment.WorldPosition + camera.CFrame.LookVector
        )
    end)
end

----------------------------------------------------------------------
-- Линейное изменение Brightness от текущего значения к target за duration.
-- При duration <= 0 ставит target мгновенно.
-- token — снимок fadeToken на момент запуска; если он успел измениться,
-- значит запустилась новая вспышка и старый fade нужно прервать.
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

----------------------------------------------------------------------
-- Сама вспышка
----------------------------------------------------------------------
local function doFlash()
    local now = tick()
    if now < cooldownEnd then return end
    if now < activeUntil then return end
    if not spotLight then return end

    fadeToken += 1
    local myToken = fadeToken

    activeUntil = now + FLASH_DURATION
    spotLight.Enabled = true

    -- Fade-in (или мгновенно, если FADE_IN_TIME == 0)
    fadeBrightness(FLASH_BRIGHT, FADE_IN_TIME, myToken)

    -- Fade-out стартует так, чтобы закончиться ровно в конце FLASH_DURATION
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
    end
end)

local function onCharacterAdded(character)
    setupOnCharacter(character)
end

if localPlayer.Character then
    onCharacterAdded(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(onCharacterAdded)
