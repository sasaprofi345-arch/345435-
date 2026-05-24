--!strict
-- FreddyAI.server.lua
-- Положить в: ServerScriptService
-- Тип: Script (server-side)
--
-- Управляет поведением Фредди: телепортация между точками, случайные звуки,
-- и реакция на обнаружение лучом фонарика (скример + побег).

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local Workspace           = game:GetService("Workspace")
local Players             = game:GetService("Players")

-- Инициализация RemoteEvent'ов (на случай если их еще нет в проекте).
-- См. ReplicatedStorage/FreddyRemotes.lua для подробностей.
do
	local existing = ReplicatedStorage:FindFirstChild("FreddyRemotes")
	if not existing then
		local folder = Instance.new("Folder")
		folder.Name = "FreddyRemotes"
		folder.Parent = ReplicatedStorage
		for _, n in ipairs({ "FreddySpotted", "FreddyJumpscare", "FreddySound" }) do
			local ev = Instance.new("RemoteEvent")
			ev.Name = n
			ev.Parent = folder
		end
	end
end

local Remotes        = ReplicatedStorage:WaitForChild("FreddyRemotes")
local FreddySpotted  = Remotes:WaitForChild("FreddySpotted")  :: RemoteEvent
local FreddyJumpscare= Remotes:WaitForChild("FreddyJumpscare"):: RemoteEvent
local FreddySoundEv  = Remotes:WaitForChild("FreddySound")    :: RemoteEvent

-- Конфигурация поведения. Все значения "тюнить" здесь.
local CONFIG = {
	-- Имя модели Фредди в Workspace. Модель должна иметь PrimaryPart.
	FreddyName          = "Freddy",
	-- Имя Folder с Part'ами-точками телепортации.
	SpawnPointsFolder   = "FreddySpawnPoints",
	-- Сколько секунд Фредди стоит на точке, минимум/максимум.
	IdleTimeMin         = 8,
	IdleTimeMax         = 18,
	-- Шанс издать звук в течение одного "тика" (раз в 1с).
	SoundChancePerSec   = 0.10,
	-- Минимальная пауза между звуками одной "сессии" точки.
	SoundCooldown       = 4,
	-- На какое расстояние от камеры враг "прыгает" во время скримера.
	JumpscareDistance   = 4,
	-- Кулдаун между обнаружениями (чтобы клиент не спамил).
	SpotCooldown        = 1.5,
	-- Через сколько секунд после скримера Фредди уходит на новую точку.
	FleeDelay           = 0.6,
}

-- Класс Freddy ----------------------------------------------------------------
local Freddy = {}
Freddy.__index = Freddy

function Freddy.new(model: Model, spawnPoints: { BasePart })
	assert(model.PrimaryPart, "Модель Freddy должна иметь PrimaryPart")
	assert(#spawnPoints > 0, "Нужна хотя бы одна точка спавна")

	local self = setmetatable({}, Freddy)
	self.model           = model
	self.spawnPoints     = spawnPoints
	self.currentPoint    = nil :: BasePart?
	self.lastSoundAt     = 0
	self.lastSpotAt      = {} :: { [Player]: number } -- кулдаун обнаружения на игрока
	self.isScared        = false
	-- Кэш HumanoidRootPart-подобного якоря для перемещения.
	self.root            = model.PrimaryPart :: BasePart
	-- Снижаем сетевую нагрузку: модель должна быть Anchored, чтоб двигать через CFrame.
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false -- чтобы игрок не натыкался на телепортирующегося врага
		end
	end
	return self
end

-- Телепорт в указанную точку (или в случайную, отличную от текущей).
function Freddy:teleportTo(point: BasePart?)
	if not point then
		-- Выбираем случайную точку, желательно НЕ ту же самую.
		local candidates = {}
		for _, p in ipairs(self.spawnPoints) do
			if p ~= self.currentPoint then
				table.insert(candidates, p)
			end
		end
		if #candidates == 0 then
			candidates = self.spawnPoints
		end
		point = candidates[math.random(1, #candidates)]
	end
	self.currentPoint = point
	-- Смещаем так, чтобы низ модели стоял на точке (а не пересекал её).
	local offset = Vector3.new(0, self.root.Size.Y / 2 + point.Size.Y / 2, 0)
	self.model:PivotTo(CFrame.new(point.Position + offset) * CFrame.Angles(0, math.rad(point.Orientation.Y), 0))
end

-- Возвращает текущую мировую позицию Фредди (для рейкаста с клиента).
function Freddy:getPosition(): Vector3
	return self.root.Position
end

-- Проиграть пугающий звук в текущей точке (рассылаем всем клиентам — звук 3D).
function Freddy:playAmbientSound()
	local now = os.clock()
	if now - self.lastSoundAt < CONFIG.SoundCooldown then return end
	self.lastSoundAt = now
	-- Клиенты сами решат, какой звук взять (смех/падение) — мы шлём только позицию и тип.
	local soundType = (math.random() < 0.5) and "Laugh" or "Drop"
	FreddySoundEv:FireAllClients(soundType, self.root.Position)
end

-- Реакция на обнаружение фонариком.
-- spotter — игрок, посветивший на Фредди.
function Freddy:onSpotted(spotter: Player)
	if self.isScared then return end
	local now = os.clock()
	if (self.lastSpotAt[spotter] or 0) + CONFIG.SpotCooldown > now then return end
	self.lastSpotAt[spotter] = now
	self.isScared = true

	-- Локальный скример: прыжок к камере + звук — обрабатывается у того игрока.
	FreddyJumpscare:FireClient(spotter, self.root.Position, CONFIG.JumpscareDistance)

	-- Через FleeDelay Фредди уходит на другую точку и снимается флаг.
	task.delay(CONFIG.FleeDelay, function()
		self:teleportTo(nil)
		self.isScared = false
	end)
end

-- Главный цикл поведения. Запускается один раз, работает всё время существования игры.
function Freddy:start()
	self:teleportTo(nil)

	-- Цикл "случайных звуков" — тикает каждую секунду.
	task.spawn(function()
		while self.model.Parent do
			task.wait(1)
			if not self.isScared and math.random() < CONFIG.SoundChancePerSec then
				self:playAmbientSound()
			end
		end
	end)

	-- Цикл "смены точки" — стоит на месте от IdleTimeMin до IdleTimeMax, затем телепорт.
	task.spawn(function()
		while self.model.Parent do
			local wait = math.random() * (CONFIG.IdleTimeMax - CONFIG.IdleTimeMin) + CONFIG.IdleTimeMin
			task.wait(wait)
			if not self.isScared then
				self:teleportTo(nil)
			end
		end
	end)
end

-- Сборка зависимостей --------------------------------------------------------

-- Ждём появления модели Фредди и папки точек.
local function collectSpawnPoints(folder: Instance): { BasePart }
	local points = {}
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("BasePart") then
			table.insert(points, child)
		end
	end
	return points
end

local freddyModel = Workspace:WaitForChild(CONFIG.FreddyName) :: Model
local pointsFolder = Workspace:WaitForChild(CONFIG.SpawnPointsFolder)
local spawnPoints  = collectSpawnPoints(pointsFolder)

local freddy = Freddy.new(freddyModel, spawnPoints)
freddy:start()

-- Обработка сообщений от клиента: игрок посветил на Фредди.
-- Клиент шлёт ничего (или nil) — серверная проверка валидности ниже.
FreddySpotted.OnServerEvent:Connect(function(player: Player)
	-- Валидация: серверно перепроверяем, что игрок РЕАЛЬНО смотрит на Фредди.
	-- Без этой проверки клиент мог бы вызвать "скример" по своему желанию.
	local character = player.Character
	local head = character and character:FindFirstChild("Head") :: BasePart?
	if not head then return end

	local toFreddy = freddy:getPosition() - head.Position
	local distance = toFreddy.Magnitude
	if distance > 200 then return end -- слишком далеко — точно не видно

	-- Рейкаст от головы игрока в сторону Фредди — должен попасть в модель Фредди.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local hit = Workspace:Raycast(head.Position, toFreddy.Unit * (distance + 2), params)
	if hit and hit.Instance:IsDescendantOf(freddyModel) then
		freddy:onSpotted(player)
	end
end)

-- Очищаем кэш кулдауна при выходе игрока.
Players.PlayerRemoving:Connect(function(p)
	freddy.lastSpotAt[p] = nil
end)
