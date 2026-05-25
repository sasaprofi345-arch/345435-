--[[
    FlashlightFlash.client.lua
    --------------------------------------------------------------------
    Клиентский скрипт «вспышка фонариком» для R6.

    Логика:
      * игрок целится камерой в нужное место;
      * нажимает ЛКМ — фонарик мгновенно включается на 1.5 секунды
        и светит туда, куда смотрит камера;
      * по истечении времени так же мгновенно выключается;
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
local FLASH_DURATION = 1.5    -- сколько секунд горит вспышка
local FLASH_COOLDOWN = 0.5    -- задержка после вспышки до следующей
local FLASH_RANGE    = 120    -- дальность света в studs
local FLASH_ANGLE    = 60     -- угол конуса SpotLight (полный)
local FLASH_BRIGHT   = 8      -- яркость SpotLight (1..10)

----------------------------------------------------------------------
-- Состояние
----------------------------------------------------------------------
local attachment
local spotLight
local activeUntil = 0
local cooldownEnd = 0
local renderConn

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
    spotLight.Brightness = FLASH_BRIGHT
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
-- Сама вспышка — резкое включение и резкое выключение
----------------------------------------------------------------------
local function doFlash()
    local now = tick()
    if now < cooldownEnd then return end
    if now < activeUntil then return end
    if not spotLight then return end

    activeUntil = now + FLASH_DURATION
    spotLight.Brightness = FLASH_BRIGHT
    spotLight.Enabled    = true

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
