--[[
    FreddyAI.server.lua
    --------------------------------------------------------------------
    Серверный скрипт, управляющий поведением врага "Фредди" в стиле
    The Joy of Creation: Story Mode.

    Логика:
      * Фредди стоит на одной из заранее заданных точек (TeleportPoints).
      * Через случайные интервалы он телепортируется в новую точку.
      * Иногда играет случайный звук (смех / падение), чтобы игрок мог
        определить его местоположение по слуху.
      * Если клиент сообщил через RemoteEvent "FlashlightHit", что
        фонарик попал по Фредди, тот воспроизводит "глюк"-скример
        (рывок к камере игрока) и сбегает в другую точку.

    Размещение: ServerScriptService.
    --------------------------------------------------------------------
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace          = game:GetService("Workspace")
local RunService         = game:GetService("RunService")
local TweenService       = game:GetService("TweenService")
local Debris             = game:GetService("Debris")

-- RemoteEvent, по которому клиент сообщает о попадании луча фонарика
local flashlightHit = ReplicatedStorage:WaitForChild("FlashlightHit")
-- RemoteEvent для запуска "глюк-скримера" на стороне клиента
-- (тряска камеры / эффект помех — это уже визуальная часть клиента)
local jumpscareEvent = ReplicatedStorage:WaitForChild("JumpscareEvent")

-- Ссылки на модель Фредди и контейнер с точками появления
local freddy        = Workspace:WaitForChild("Freddy")          -- Model
local rootPart      = freddy:WaitForChild("HumanoidRootPart")   -- Part (PrimaryPart)
local teleportPoints = Workspace:WaitForChild("FreddyTeleportPoints"):GetChildren()

-- Звуки лежат прямо внутри HumanoidRootPart Фредди:
-- LaughSound (Sound) и DropSound (Sound)
local laughSound = rootPart:WaitForChild("LaughSound")
local dropSound  = rootPart:WaitForChild("DropSound")

----------------------------------------------------------------------
-- ОО-стиль: создаём "класс" Freddy через метатаблицу.
----------------------------------------------------------------------
local Freddy = {}
Freddy.__index = Freddy

-- Конструктор
function Freddy.new(model, points)
    local self = setmetatable({}, Freddy)
    self.Model      = model
    self.Root       = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")
    self.Points     = points
    self.CurrentPoint = nil
    self.IsScared   = false        -- блокирует обычное поведение, пока бежит после испуга
    self.LastTeleport = 0
    self.LastSound  = 0
    return self
end

-- Возвращает случайную точку, отличную от текущей
function Freddy:_pickRandomPoint()
    if #self.Points <= 1 then
        return self.Points[1]
    end
    local pt
    repeat
        pt = self.Points[math.random(1, #self.Points)]
    until pt ~= self.CurrentPoint
    return pt
end

-- Телепортация к указанной точке. Использует PivotTo, чтобы переместить
-- всю модель целиком, а не только PrimaryPart.
function Freddy:TeleportTo(point)
    self.CurrentPoint = point
    -- Поднимаем модель на половину высоты HumanoidRootPart, чтобы ноги
    -- встали на поверхность Part'а, а не утопились в нём.
    local offset = Vector3.new(0, self.Root.Size.Y / 2, 0)
    self.Model:PivotTo(CFrame.new(point.Position + offset))
    self.LastTeleport = tick()
end

-- Телепорт в случайную точку
function Freddy:TeleportRandom()
    self:TeleportTo(self:_pickRandomPoint())
end

-- Случайный окружающий звук в текущей точке
function Freddy:PlayAmbientSound()
    -- 50/50: смех или падающий предмет
    local sound = (math.random() < 0.5) and laughSound or dropSound
    sound:Play()
    self.LastSound = tick()
end

-- Реакция на попадание луча фонарика
function Freddy:OnFlashlightHit(player)
    -- Отбиваем повторные срабатывания за короткий промежуток
    if self.IsScared then return end
    self.IsScared = true

    -- 1. Сообщаем клиенту: запустить скример (тряска, помехи, sting-sound)
    jumpscareEvent:FireClient(player)

    -- 2. "Глитч-прыжок" к камере: на сервере имитируем резкое
    --    приближение модели к игроку, после чего убегаем в новую точку.
    local character = player.Character
    local head      = character and character:FindFirstChild("Head")
    if head then
        -- Позиция вплотную к лицу игрока, лицом к нему
        local jumpCFrame = CFrame.new(head.Position - head.CFrame.LookVector * 2,
                                       head.Position)
        self.Model:PivotTo(jumpCFrame)
    end

    -- 3. Короткая пауза, чтобы скример успел проиграться, и убегаем.
    task.delay(0.25, function()
        self:TeleportRandom()
        -- После побега небольшой кулдаун, чтобы избежать спама
        task.wait(2)
        self.IsScared = false
    end)
end

-- Основной цикл поведения. Запускается один раз в конструкторе игры.
function Freddy:StartBehaviour()
    -- Изначально ставим в случайную точку
    self:TeleportRandom()

    task.spawn(function()
        while self.Model.Parent do
            -- Интервал между перемещениями: 6–12 секунд
            local teleportDelay = math.random(6, 12)
            task.wait(teleportDelay)

            if self.IsScared then
                -- Пока в "испуганном" состоянии, обычный цикл паузим
                continue
            end

            -- Иногда (40 % шанс) перед телепортом издаём звук
            if math.random() < 0.4 then
                self:PlayAmbientSound()
                task.wait(math.random(1, 3))  -- даём игроку время засечь
            end

            self:TeleportRandom()
        end
    end)
end

----------------------------------------------------------------------
-- Точка входа
----------------------------------------------------------------------
local freddyAI = Freddy.new(freddy, teleportPoints)
freddyAI:StartBehaviour()

-- Подписка на событие от клиента
flashlightHit.OnServerEvent:Connect(function(player, hitInstance)
    -- Защита: проверяем, что клиент действительно попал по Фредди,
    -- а не подсунул нам произвольный объект.
    if not hitInstance or not hitInstance:IsDescendantOf(freddy) then
        return
    end

    -- Дополнительная серверная валидация дистанции, чтобы исключить
    -- читы с "телепорт-фонариком" через всю карту.
    local character = player.Character
    local root      = character and character:FindFirstChild("HumanoidRootPart")
    if not root then return end

    local distance = (root.Position - freddyAI.Root.Position).Magnitude
    if distance > 80 then return end  -- 80 studs — макс. дальность фонарика

    freddyAI:OnFlashlightHit(player)
end)
