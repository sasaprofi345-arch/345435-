--[[
    Flashlight.client.lua
    --------------------------------------------------------------------
    Клиентский скрипт, отвечающий за фонарик игрока:
      * включение/выключение по клавише F;
      * собственно "луч" — SpotLight в руке + лучевой Raycast от камеры;
      * детекция Фредди в конусе фонарика и отправка события на сервер;
      * визуальные эффекты "глюк-скримера", когда сервер их инициирует.

    Размещение: StarterPlayer -> StarterPlayerScripts.
    --------------------------------------------------------------------
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local Workspace         = game:GetService("Workspace")
local Lighting          = game:GetService("Lighting")
local TweenService      = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local camera      = Workspace.CurrentCamera

-- Remote-события, согласованные с серверным скриптом
local flashlightHit  = ReplicatedStorage:WaitForChild("FlashlightHit")
local jumpscareEvent = ReplicatedStorage:WaitForChild("JumpscareEvent")

----------------------------------------------------------------------
-- Параметры фонарика
----------------------------------------------------------------------
local FLASHLIGHT_RANGE   = 80    -- макс. длина луча в studs (синхронно с сервером)
local FLASHLIGHT_ANGLE   = 25    -- половинный угол конуса, в градусах
local DETECTION_INTERVAL = 0.1   -- как часто опрашиваем raycast (сек)
local FREDDY_NAME        = "Freddy"  -- имя модели врага в Workspace

----------------------------------------------------------------------
-- ОО-стиль: класс Flashlight
----------------------------------------------------------------------
local Flashlight = {}
Flashlight.__index = Flashlight

function Flashlight.new()
    local self = setmetatable({}, Flashlight)
    self.IsOn         = false
    self.LastHitSent  = 0
    self.SpotLight    = nil    -- SpotLight, заспавненный на персонаже
    self.RaycastParams = RaycastParams.new()
    self.RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
    return self
end

-- Привязка фонаря к персонажу: ждём появления RightHand и вешаем туда SpotLight
function Flashlight:Attach(character)
    self.Character = character
    local hand = character:WaitForChild("RightHand", 5) or character:WaitForChild("Head")

    -- SpotLight для визуализации луча
    local light = Instance.new("SpotLight")
    light.Name        = "FlashlightLight"
    light.Range       = FLASHLIGHT_RANGE
    light.Angle       = FLASHLIGHT_ANGLE * 2  -- SpotLight.Angle — полный конус
    light.Brightness  = 2
    light.Shadows     = true
    light.Enabled     = false
    light.Parent      = hand
    self.SpotLight    = light

    -- Игрок не должен сам себя "осветить" и попасть в raycast
    self.RaycastParams.FilterDescendantsInstances = {character}
end

function Flashlight:Toggle()
    self.IsOn = not self.IsOn
    if self.SpotLight then
        self.SpotLight.Enabled = self.IsOn
    end
end

-- Главная проверка: смотрит ли игрок на Фредди в данный момент.
-- Алгоритм: пускаем raycast из камеры по направлению её взгляда.
-- Если луч уперся в часть, принадлежащую модели Freddy, считаем попадание.
function Flashlight:CheckHit()
    if not self.IsOn then return end

    local origin    = camera.CFrame.Position
    local direction = camera.CFrame.LookVector * FLASHLIGHT_RANGE
    local result    = Workspace:Raycast(origin, direction, self.RaycastParams)

    if not result then return end
    local hitInstance = result.Instance
    if not hitInstance then return end

    -- Поднимаемся по иерархии и проверяем, не Фредди ли это
    local model = hitInstance:FindFirstAncestorOfClass("Model")
    if not model or model.Name ~= FREDDY_NAME then return end

    -- Дополнительная проверка угла: луч из центра камеры — это, по сути,
    -- центр конуса. SpotLight в Roblox светит конусом, поэтому здесь
    -- "попадание" = курсор/камера направлены прямо на Фредди. Это даёт
    -- честную, читаемую механику без false-positive по краям конуса.

    -- Анти-спам: не чаще одного срабатывания в 0.5 секунды
    if tick() - self.LastHitSent < 0.5 then return end
    self.LastHitSent = tick()

    flashlightHit:FireServer(hitInstance)
end

function Flashlight:StartLoop()
    -- RunService.Heartbeat с собственным аккумулятором — экономичнее,
    -- чем дёргать raycast каждый кадр.
    local acc = 0
    RunService.Heartbeat:Connect(function(dt)
        acc += dt
        if acc < DETECTION_INTERVAL then return end
        acc = 0
        self:CheckHit()
    end)
end

----------------------------------------------------------------------
-- Эффекты скримера на стороне клиента
----------------------------------------------------------------------
local function playJumpscareEffects()
    -- 1. Цветовой "глюк": быстро гасим экран красным через ColorCorrection
    local cc = Instance.new("ColorCorrectionEffect")
    cc.Name       = "JumpscareCC"
    cc.TintColor  = Color3.fromRGB(255, 60, 60)
    cc.Brightness = 0.4
    cc.Saturation = -0.5
    cc.Parent     = Lighting

    -- 2. Тряска камеры: дёргаем CFrame несколько кадров подряд
    local shakeStart = tick()
    local shakeConn
    shakeConn = RunService.RenderStepped:Connect(function()
        local elapsed = tick() - shakeStart
        if elapsed > 0.5 then
            shakeConn:Disconnect()
            return
        end
        local intensity = (1 - elapsed / 0.5) * 0.8
        camera.CFrame = camera.CFrame * CFrame.new(
            (math.random() - 0.5) * intensity,
            (math.random() - 0.5) * intensity,
            0
        )
    end)

    -- 3. Через 0.5 с убираем цветовой фильтр через tween
    local tween = TweenService:Create(cc,
        TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {Brightness = 0, TintColor = Color3.new(1, 1, 1)})
    task.delay(0.5, function()
        tween:Play()
        tween.Completed:Wait()
        cc:Destroy()
    end)
end

----------------------------------------------------------------------
-- Точка входа
----------------------------------------------------------------------
local flashlight = Flashlight.new()

local function onCharacterAdded(character)
    flashlight:Attach(character)
end

if localPlayer.Character then
    onCharacterAdded(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(onCharacterAdded)

flashlight:StartLoop()

-- Toggle по клавише F (можно поменять на любую другую)
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F then
        flashlight:Toggle()
    end
end)

-- Сервер сказал "пугаем" — крутим эффекты
jumpscareEvent.OnClientEvent:Connect(playJumpscareEffects)
