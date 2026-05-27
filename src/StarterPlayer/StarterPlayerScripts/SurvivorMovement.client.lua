--[[
    SurvivorMovement.client.lua
    --------------------------------------------------------------------
    Плавность движений выжившего в стиле Dead by Daylight (R6).
    НЕ меняет скорость персонажа и НЕ использует стамину — только
    делает поворот тела и камеру "вязкой" и кинематографичной.

      * Плавный поворот корпуса вслед за камерой (как в DBD —
        тело "догоняет" взгляд, а не клеится к курсору 1-в-1)
      * Тонкий наклон камеры (lean) при стрейфе и при повороте мышью
      * Мягкий head-bob, синхронный с шагами
      * Быстрый разворот (Q) — плавный 180° за ~0.18 с с FOV-пуш
      * "Посмотреть назад" удержанием LeftAlt — камера разворачивается
        на 180°, тело не двигается

    Размещение: StarterPlayer -> StarterPlayerScripts.
    --------------------------------------------------------------------
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local Workspace        = game:GetService("Workspace")

local localPlayer = Players.LocalPlayer
local camera      = Workspace.CurrentCamera

----------------------------------------------------------------------
-- Конфиг — крути здесь, чтобы поменять "ощущения"
----------------------------------------------------------------------
local CONFIG = {
    -- Плавность поворота тела за камерой.
    -- Чем меньше — тем "тяжелее" тело догоняет взгляд (более DBD-like).
    BodyTurnResponse  = 9.0,

    -- Наклон камеры (lean)
    LeanFromStrafe    = 3.5,   -- макс. угол от стрейфа (град.)
    LeanFromYaw       = 2.5,   -- макс. угол от вращения мыши (град.)
    LeanResponse      = 7.0,   -- скорость интерполяции lean

    -- Head-bob (мягкий, чисто косметика)
    BobAmplitude      = 0.10,
    BobFrequency      = 7.0,
    BobSideways       = 0.05,

    -- FOV
    BaseFOV           = 70,
    QuickTurnFOVDip   = 5,
    QuickTurnDuration = 0.18,

    -- Клавиши
    QuickTurnKey      = Enum.KeyCode.Q,
    LookBackKey       = Enum.KeyCode.LeftAlt,
}

----------------------------------------------------------------------
-- Состояние
----------------------------------------------------------------------
local State = {
    character  = nil,
    humanoid   = nil,
    rootPart   = nil,

    -- Текущий "сглаженный" yaw тела, к которому мы приближаемся
    bodyYaw    = 0,

    -- Для определения скорости поворота мыши (yaw delta)
    lastCamYaw = 0,
    camYawRate = 0,

    leanCurrent = 0,
    bobPhase    = 0,

    isLookBack  = false,
    isQuickTurning = false,
}

----------------------------------------------------------------------
-- Утилиты
----------------------------------------------------------------------
local function getCameraYaw()
    -- Извлекаем yaw из CFrame камеры (поворот вокруг Y)
    local lv = camera.CFrame.LookVector
    return math.atan2(-lv.X, -lv.Z)
end

local function shortestAngle(from, to)
    local d = (to - from) % (2 * math.pi)
    if d > math.pi then d = d - 2 * math.pi end
    return d
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

----------------------------------------------------------------------
-- Плавный поворот корпуса: вместо мгновенного AutoRotate тело
-- интерполирует свой yaw к yaw камеры с задержкой — это и даёт
-- "тяжёлое" DBD-ощущение при поворотах.
----------------------------------------------------------------------
local function updateBodyRotation(dt)
    if not State.rootPart or State.isQuickTurning then return end

    local camYaw = getCameraYaw()
    local moving = State.humanoid and State.humanoid.MoveDirection.Magnitude > 0.05

    -- Тело поворачивается только когда игрок ИЛИ идёт, ИЛИ удерживается
    -- большой угол — это убирает дёрганья, когда стоишь и крутишь камеру.
    local diff = shortestAngle(State.bodyYaw, camYaw)
    if not moving and math.abs(diff) < math.rad(45) then
        return
    end

    local alpha = math.clamp(dt * CONFIG.BodyTurnResponse, 0, 1)
    State.bodyYaw = State.bodyYaw + diff * alpha

    -- Применяем CFrame: сохраняем позицию, меняем только yaw
    local pos = State.rootPart.Position
    State.rootPart.CFrame = CFrame.new(pos) * CFrame.Angles(0, State.bodyYaw, 0)
end

----------------------------------------------------------------------
-- Lean камеры: от стрейфа и от вращения мыши (yaw rate)
----------------------------------------------------------------------
local function updateCameraLean(dt)
    if not State.humanoid or not State.rootPart then return end

    -- 1) lean от стрейфа
    local strafeLean = 0
    local moveDir = State.humanoid.MoveDirection
    if moveDir.Magnitude > 0.05 then
        local right = State.rootPart.CFrame.RightVector
        local strafe = right:Dot(moveDir)
        strafeLean = -strafe * CONFIG.LeanFromStrafe
    end

    -- 2) lean от вращения камеры (наклон в сторону поворота)
    local camYaw = getCameraYaw()
    local rawDelta = shortestAngle(State.lastCamYaw, camYaw)
    -- сглаживаем yaw rate, чтобы не было нервозного дёргания
    local yawRate = math.deg(rawDelta) / math.max(dt, 1/240)
    State.camYawRate = State.camYawRate + (yawRate - State.camYawRate) * math.clamp(dt * 10, 0, 1)
    State.lastCamYaw = camYaw

    local yawLean = math.clamp(State.camYawRate / 180, -1, 1) * CONFIG.LeanFromYaw

    local target = strafeLean + yawLean
    local alpha = math.clamp(dt * CONFIG.LeanResponse, 0, 1)
    State.leanCurrent = State.leanCurrent + (target - State.leanCurrent) * alpha

    -- Применяем как roll к камере мягко поверх дефолтного контроллера
    if math.abs(State.leanCurrent) > 0.01 then
        camera.CFrame = camera.CFrame * CFrame.Angles(0, 0, math.rad(State.leanCurrent))
    end
end

----------------------------------------------------------------------
-- Head-bob через CameraOffset (R6-совместимо, не ломает контроллер)
----------------------------------------------------------------------
local function updateHeadBob(dt)
    if not State.humanoid then return end
    local moveMag = State.humanoid.MoveDirection.Magnitude * State.humanoid.WalkSpeed
    if State.humanoid.FloorMaterial == Enum.Material.Air then
        moveMag = 0
    end
    local scale = math.clamp(moveMag / 16, 0, 1.2)
    State.bobPhase = State.bobPhase + dt * CONFIG.BobFrequency * scale

    local vertical = math.abs(math.sin(State.bobPhase)) * CONFIG.BobAmplitude * scale
    local sideways = math.sin(State.bobPhase * 0.5) * CONFIG.BobSideways * scale

    -- Плавно подмешиваем к текущему offset, чтобы не "клацало"
    local current = State.humanoid.CameraOffset
    local target  = Vector3.new(sideways, -vertical, 0)
    State.humanoid.CameraOffset = current:Lerp(target, math.clamp(dt * 12, 0, 1))
end

----------------------------------------------------------------------
-- Look-back: удержать LeftAlt — камера смотрит назад
----------------------------------------------------------------------
local lookBackConn
local function startLookBack()
    if State.isLookBack or not State.rootPart then return end
    State.isLookBack = true
    camera.CameraType = Enum.CameraType.Scriptable

    lookBackConn = RunService.RenderStepped:Connect(function()
        if not State.rootPart then return end
        local root = State.rootPart.CFrame
        local eye  = root.Position + Vector3.new(0, 1.5, 0) + root.LookVector * -6
        local lookAt = root.Position + Vector3.new(0, 1.5, 0) - root.LookVector
        camera.CFrame = CFrame.lookAt(eye, lookAt)
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
-- Быстрый разворот (Q): плавно крутим тело на 180° + микро-FOV-dip
----------------------------------------------------------------------
local function quickTurn()
    if not State.rootPart or State.isQuickTurning then return end
    State.isQuickTurning = true

    local startYaw  = State.bodyYaw
    local targetYaw = startYaw + math.pi

    tweenFOV(CONFIG.BaseFOV - CONFIG.QuickTurnFOVDip, 0.08)
    task.delay(0.12, function() tweenFOV(CONFIG.BaseFOV, 0.2) end)

    local startTime = tick()
    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not State.rootPart then conn:Disconnect() return end
        local t = (tick() - startTime) / CONFIG.QuickTurnDuration
        if t >= 1 then
            State.bodyYaw = targetYaw
            local pos = State.rootPart.Position
            State.rootPart.CFrame = CFrame.new(pos) * CFrame.Angles(0, targetYaw, 0)
            State.isQuickTurning = false
            conn:Disconnect()
            return
        end
        local k = 1 - (1 - t) ^ 3   -- ease-out
        State.bodyYaw = startYaw + (targetYaw - startYaw) * k
        local pos = State.rootPart.Position
        State.rootPart.CFrame = CFrame.new(pos) * CFrame.Angles(0, State.bodyYaw, 0)
    end)
end

----------------------------------------------------------------------
-- Ввод
----------------------------------------------------------------------
local function bindInput()
    UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == CONFIG.QuickTurnKey then
            quickTurn()
        elseif input.KeyCode == CONFIG.LookBackKey then
            startLookBack()
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.KeyCode == CONFIG.LookBackKey then
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

    -- Сброс
    State.bodyYaw    = getCameraYaw()
    State.lastCamYaw = State.bodyYaw
    State.camYawRate = 0
    State.leanCurrent = 0
    State.bobPhase   = 0
    State.isQuickTurning = false

    camera.FieldOfView = CONFIG.BaseFOV

    -- Главное: отключаем встроенный AutoRotate, чтобы вручную
    -- интерполировать поворот тела за камерой (это и даёт DBD-ощущение).
    State.humanoid.AutoRotate = false

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
    updateBodyRotation(dt)
    updateCameraLean(dt)
    updateHeadBob(dt)
end)
