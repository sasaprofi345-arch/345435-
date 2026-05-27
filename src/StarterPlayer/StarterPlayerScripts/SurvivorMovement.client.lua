--[[
    SurvivorMovement.client.lua
    --------------------------------------------------------------------
    DBD-подобный мувмент для выжившего (R6).
    Делает игру за выжившего ОТЗЫВЧИВОЙ и КИНЕМАТОГРАФИЧНОЙ:

      * Спринт на Shift со стаминой и состоянием "exhausted"
      * Присед на C (тише, медленнее)
      * Плавное FOV "punch" во время бега
      * Тонкий наклон камеры (lean) при стрейфе на бегу
      * Камера-бобминг (head-bob) синхронно с шагами
      * Контекстное запрыгивание/перепрыгивание (Vault) на Space
        у низких препятствий — быстрый vault, если стамина есть,
        медленный vault, если exhausted
      * Быстрый разворот (Q) — 180° за один кадр с микро-зумом
      * "Посмотреть назад" удержанием LeftAlt (не разворачивает героя,
        только камеру)
      * Плавное ускорение / торможение через WalkSpeed-tween

    Размещение: StarterPlayer -> StarterPlayerScripts.
    --------------------------------------------------------------------
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local Workspace         = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local camera      = Workspace.CurrentCamera

----------------------------------------------------------------------
-- Конфиг — крути здесь, чтобы поменять "ощущения"
----------------------------------------------------------------------
local CONFIG = {
    -- Скорости (studs/sec)
    WalkSpeed     = 14,
    SprintSpeed   = 24,
    CrouchSpeed   = 7,
    ExhaustedCap  = 12,    -- максимум, пока стамина не восстановится

    -- Плавность перехода скоростей (сек до целевой)
    SpeedTweenIn  = 0.18,
    SpeedTweenOut = 0.35,

    -- Стамина
    MaxStamina        = 5.0,    -- секунд непрерывного спринта
    StaminaRegen      = 1.0,    -- единиц/сек
    ExhaustRegenDelay = 0.6,    -- задержка перед началом регена

    -- FOV
    BaseFOV       = 70,
    SprintFOV     = 82,
    CrouchFOV     = 65,
    FOVTweenIn    = 0.28,
    FOVTweenOut   = 0.45,

    -- Наклон камеры (lean) на спринте при стрейфе
    LeanMaxDegrees = 4.0,
    LeanResponse   = 8.0,    -- скорость реакции

    -- Head-bob
    BobAmplitude   = 0.12,   -- studs, вертикальное смещение
    BobFrequency   = 7.5,    -- 1.0 при walk = 14 studs/sec, scale-ится со скоростью
    BobSideways    = 0.06,

    -- Vault
    VaultCheckRange   = 3.0,     -- как далеко вперед ищем препятствие
    VaultMaxHeight    = 4.5,     -- максимальная высота препятствия
    VaultMinClearance = 3.0,     -- сколько свободного места должно быть за препятствием
    VaultFastTime     = 0.45,
    VaultSlowTime     = 0.85,

    -- Быстрый разворот
    QuickTurnDuration = 0.18,

    -- Клавиши
    SprintKey     = Enum.KeyCode.LeftShift,
    CrouchKey     = Enum.KeyCode.C,
    QuickTurnKey  = Enum.KeyCode.Q,
    LookBackKey   = Enum.KeyCode.LeftAlt,
    VaultKey      = Enum.KeyCode.Space,
}

----------------------------------------------------------------------
-- Состояние
----------------------------------------------------------------------
local State = {
    character    = nil,
    humanoid     = nil,
    rootPart     = nil,

    isSprinting  = false,
    isCrouching  = false,
    isExhausted  = false,
    isVaulting   = false,
    isLookBack   = false,

    stamina      = CONFIG.MaxStamina,
    lastSprintEnded = 0,

    currentLean  = 0,   -- текущий применённый угол (для интерполяции)
    bobPhase     = 0,
    bobOffset    = Vector3.zero,
}

----------------------------------------------------------------------
-- Утилиты
----------------------------------------------------------------------
local activeSpeedTween
local function tweenWalkSpeed(target, time)
    if not State.humanoid then return end
    if activeSpeedTween then
        activeSpeedTween:Cancel()
    end
    activeSpeedTween = TweenService:Create(
        State.humanoid,
        TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { WalkSpeed = target }
    )
    activeSpeedTween:Play()
end

local activeFovTween
local function tweenFOV(target, time)
    if activeFovTween then activeFovTween:Cancel() end
    activeFovTween = TweenService:Create(
        camera,
        TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { FieldOfView = target }
    )
    activeFovTween:Play()
end

local function getDesiredSpeed()
    if State.isCrouching then
        return CONFIG.CrouchSpeed
    end
    if State.isSprinting and not State.isExhausted then
        return CONFIG.SprintSpeed
    end
    if State.isExhausted then
        return math.min(CONFIG.ExhaustedCap, CONFIG.WalkSpeed)
    end
    return CONFIG.WalkSpeed
end

local function applyMovementMode(quick)
    local speed = getDesiredSpeed()
    local time  = quick and CONFIG.SpeedTweenIn or CONFIG.SpeedTweenOut
    tweenWalkSpeed(speed, time)

    local fov
    if State.isCrouching then
        fov = CONFIG.CrouchFOV
    elseif State.isSprinting and not State.isExhausted then
        fov = CONFIG.SprintFOV
    else
        fov = CONFIG.BaseFOV
    end
    tweenFOV(fov, quick and CONFIG.FOVTweenIn or CONFIG.FOVTweenOut)
end

----------------------------------------------------------------------
-- Стамина: считаем каждый кадр
----------------------------------------------------------------------
local function updateStamina(dt)
    if State.isSprinting and not State.isExhausted then
        State.stamina = State.stamina - dt
        if State.stamina <= 0 then
            State.stamina      = 0
            State.isExhausted  = true
            State.isSprinting  = false
            State.lastSprintEnded = tick()
            applyMovementMode(false)
        end
    else
        local sinceStop = tick() - State.lastSprintEnded
        if sinceStop >= CONFIG.ExhaustRegenDelay then
            State.stamina = math.min(CONFIG.MaxStamina, State.stamina + dt * CONFIG.StaminaRegen)
            if State.isExhausted and State.stamina >= CONFIG.MaxStamina * 0.5 then
                -- Восстанавливаемся, когда заполнили хотя бы половину
                State.isExhausted = false
                applyMovementMode(false)
            end
        end
    end
end

----------------------------------------------------------------------
-- Камера: lean + head-bob + look-back
-- Используем CameraOffset на Humanoid: оно безопасно стэкается с
-- дефолтным контроллером камеры Roblox и работает на R6.
----------------------------------------------------------------------
local baseCameraType
local lookBackBaseCFrame -- камера-якорь при удержании Alt (не используем — крутим через humanoid)

local function updateCameraEffects(dt)
    if not State.humanoid or not State.rootPart then return end

    ---------------- Lean при беге со стрейфом ----------------
    local targetLean = 0
    if State.isSprinting and not State.isExhausted then
        local moveDir = State.humanoid.MoveDirection
        if moveDir.Magnitude > 0.1 then
            local right = State.rootPart.CFrame.RightVector
            -- проекция направления движения на правый вектор => знак стрейфа
            local strafe = right:Dot(moveDir)
            targetLean = -strafe * CONFIG.LeanMaxDegrees
        end
    end
    -- Плавная интерполяция текущего угла к целевому
    local alpha = math.clamp(dt * CONFIG.LeanResponse, 0, 1)
    State.currentLean = State.currentLean + (targetLean - State.currentLean) * alpha

    ---------------- Head-bob: синусоида по скорости движения ----------------
    local speedMag = State.humanoid.MoveDirection.Magnitude * State.humanoid.WalkSpeed
    if State.humanoid.FloorMaterial == Enum.Material.Air then
        speedMag = 0   -- в воздухе bob не считаем
    end
    local bobScale = speedMag / CONFIG.WalkSpeed
    State.bobPhase = State.bobPhase + dt * CONFIG.BobFrequency * bobScale
    local vertical = math.abs(math.sin(State.bobPhase)) * CONFIG.BobAmplitude * bobScale
    local sideways = math.sin(State.bobPhase * 0.5) * CONFIG.BobSideways * bobScale

    State.humanoid.CameraOffset = Vector3.new(sideways, -vertical, 0)

    ---------------- Lean применяем как roll к CurrentCamera ----------------
    if math.abs(State.currentLean) > 0.05 then
        local rad = math.rad(State.currentLean)
        camera.CFrame = camera.CFrame * CFrame.Angles(0, 0, rad * dt * 60 / 60)
        -- ВНИМАНИЕ: применяем lean мягко поверх CFrame — это устойчиво
        -- работает с дефолтным CameraType=Custom и не "крадёт" управление
        -- мышью. По сути мы добавляем roll, который сбрасывается каждым
        -- кадром стандартным контроллером, и нам нужно лишь "подкручивать".
    end
end

----------------------------------------------------------------------
-- Look-back: на удержание Alt поворачиваем камеру на 180° относительно
-- персонажа, не меняя направление взгляда хитбокса.
----------------------------------------------------------------------
local lookBackConn
local function startLookBack()
    if State.isLookBack or not State.rootPart then return end
    State.isLookBack = true
    camera.CameraType = Enum.CameraType.Scriptable

    lookBackConn = RunService.RenderStepped:Connect(function()
        if not State.rootPart then return end
        local root = State.rootPart.CFrame
        local back = root.Position + root.LookVector * -1
        local eye  = root.Position + Vector3.new(0, 1.5, 0) + root.LookVector * -6
        camera.CFrame = CFrame.lookAt(eye, back + Vector3.new(0, 1.5, 0))
    end)
end

local function stopLookBack()
    if not State.isLookBack then return end
    State.isLookBack = false
    if lookBackConn then
        lookBackConn:Disconnect()
        lookBackConn = nil
    end
    camera.CameraType = Enum.CameraType.Custom
end

----------------------------------------------------------------------
-- Быстрый разворот (Q): мгновенно поворачиваем персонажа на 180°
-- с микро-зумом FOV для "вес-кадра".
----------------------------------------------------------------------
local function quickTurn()
    if not State.rootPart or State.isVaulting then return end

    local current = State.rootPart.CFrame
    local target  = current * CFrame.Angles(0, math.pi, 0)
    -- Сохраняем позицию, чтобы не телепортировать на пару студов вверх
    target = CFrame.new(current.Position) * (target - target.Position)

    -- Маленький FOV-pop для подчёркивания манёвра
    tweenFOV(CONFIG.BaseFOV - 5, 0.08)
    task.delay(0.1, function()
        tweenFOV((State.isSprinting and not State.isExhausted) and CONFIG.SprintFOV or CONFIG.BaseFOV, 0.18)
    end)

    -- Плавный поворот за CONFIG.QuickTurnDuration
    local startTime = tick()
    local startCFrame = current
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not State.rootPart then conn:Disconnect() return end
        local t = (tick() - startTime) / CONFIG.QuickTurnDuration
        if t >= 1 then
            State.rootPart.CFrame = target
            conn:Disconnect()
            return
        end
        -- ease-out
        local k = 1 - (1 - t) ^ 3
        State.rootPart.CFrame = startCFrame:Lerp(target, k)
    end)
end

----------------------------------------------------------------------
-- Vault: ищем низкое препятствие перед игроком и плавно его
-- перепрыгиваем. Скорость зависит от стамины.
----------------------------------------------------------------------
local function tryVault()
    if State.isVaulting or not State.rootPart then return end

    local root = State.rootPart.CFrame
    local origin = root.Position + Vector3.new(0, -1, 0)
    local forward = root.LookVector

    -- 1) проверка: есть ли стена прямо перед нами на уровне пояса?
    local raycastParams = RaycastParams.new()
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    raycastParams.FilterDescendantsInstances = { State.character }

    local hit = Workspace:Raycast(origin, forward * CONFIG.VaultCheckRange, raycastParams)
    if not hit then return end

    -- 2) проверка: сверху препятствия — пусто? (его можно перелезть)
    local topOrigin   = hit.Position + forward * 0.3 + Vector3.new(0, CONFIG.VaultMaxHeight, 0)
    local topDownHit  = Workspace:Raycast(topOrigin, Vector3.new(0, -CONFIG.VaultMaxHeight - 0.5, 0), raycastParams)
    if not topDownHit then return end  -- слишком высокое, не перелезть

    local obstacleTop = topDownHit.Position
    local obstacleHeight = obstacleTop.Y - origin.Y
    if obstacleHeight > CONFIG.VaultMaxHeight or obstacleHeight < 0.6 then
        return
    end

    -- 3) точка приземления = на другой стороне препятствия
    local landPos = hit.Position + forward * CONFIG.VaultMinClearance
    landPos = Vector3.new(landPos.X, obstacleTop.Y + 0.2, landPos.Z)

    State.isVaulting = true
    local duration = State.isExhausted and CONFIG.VaultSlowTime or CONFIG.VaultFastTime

    -- Поднимем за арку: контрольная точка над препятствием
    local startPos = root.Position
    local peakPos  = Vector3.new(
        (startPos.X + landPos.X) * 0.5,
        obstacleTop.Y + 0.8,
        (startPos.Z + landPos.Z) * 0.5
    )
    local startCFrame = root
    local lookYaw = math.atan2(-forward.X, -forward.Z)
    local endCFrame = CFrame.new(landPos) * CFrame.Angles(0, lookYaw, 0)

    -- Запрещаем дефолтную физику на время прыжка
    local prevAutoRotate = State.humanoid.AutoRotate
    State.humanoid.AutoRotate = false
    State.humanoid.WalkSpeed  = 0

    -- небольшой FOV punch на быстрый vault
    if not State.isExhausted then
        tweenFOV(CONFIG.SprintFOV + 4, 0.12)
    end

    local startTime = tick()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not State.rootPart then conn:Disconnect() return end
        local t = math.clamp((tick() - startTime) / duration, 0, 1)
        -- Bezier (квадратичная) траектория: start -> peak -> end
        local a = startPos:Lerp(peakPos, t)
        local b = peakPos:Lerp(landPos, t)
        local pos = a:Lerp(b, t)
        State.rootPart.CFrame = CFrame.new(pos) * (endCFrame - endCFrame.Position)

        if t >= 1 then
            conn:Disconnect()
            State.isVaulting = false
            State.humanoid.AutoRotate = prevAutoRotate
            applyMovementMode(true)
        end
    end)
end

----------------------------------------------------------------------
-- Ввод
----------------------------------------------------------------------
local function bindInput()
    UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == CONFIG.SprintKey then
            if State.isExhausted or State.isCrouching or State.isVaulting then return end
            State.isSprinting = true
            applyMovementMode(true)
        elseif input.KeyCode == CONFIG.CrouchKey then
            State.isCrouching = not State.isCrouching
            if State.isCrouching then
                State.isSprinting = false
            end
            applyMovementMode(true)
        elseif input.KeyCode == CONFIG.QuickTurnKey then
            quickTurn()
        elseif input.KeyCode == CONFIG.LookBackKey then
            startLookBack()
        elseif input.KeyCode == CONFIG.VaultKey then
            tryVault()
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.KeyCode == CONFIG.SprintKey then
            if State.isSprinting then
                State.isSprinting = false
                State.lastSprintEnded = tick()
                applyMovementMode(false)
            end
        elseif input.KeyCode == CONFIG.LookBackKey then
            stopLookBack()
        end
    end)
end

----------------------------------------------------------------------
-- Привязка к персонажу
----------------------------------------------------------------------
local function onCharacter(character)
    State.character = character
    State.humanoid  = character:WaitForChild("Humanoid")
    State.rootPart  = character:WaitForChild("HumanoidRootPart")

    -- Сброс состояний на новый респаун
    State.isSprinting = false
    State.isCrouching = false
    State.isExhausted = false
    State.isVaulting  = false
    State.stamina     = CONFIG.MaxStamina
    State.currentLean = 0
    State.bobPhase    = 0

    State.humanoid.WalkSpeed = CONFIG.WalkSpeed
    camera.FieldOfView       = CONFIG.BaseFOV

    -- При смерти отрубаем look-back, чтобы камера не залипла
    State.humanoid.Died:Connect(stopLookBack)
end

if localPlayer.Character then
    onCharacter(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(onCharacter)

bindInput()

----------------------------------------------------------------------
-- Главный цикл
----------------------------------------------------------------------
RunService.RenderStepped:Connect(function(dt)
    if not State.humanoid then return end
    updateStamina(dt)
    updateCameraEffects(dt)
end)
