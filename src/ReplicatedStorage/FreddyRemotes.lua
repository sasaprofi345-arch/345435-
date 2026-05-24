-- FreddyRemotes.lua
-- Тип: Script (или просто Folder в Roblox Studio с RemoteEvent внутри).
-- Этот файл служит "документацией" того, какие RemoteEvent нужны.
--
-- В Roblox Studio создайте в ReplicatedStorage:
--   Folder "FreddyRemotes"
--      RemoteEvent "FreddySpotted"   -- клиент -> сервер: игрок посветил фонариком на Фредди
--      RemoteEvent "FreddyJumpscare" -- сервер -> клиент: показать скример конкретному игроку
--      RemoteEvent "FreddySound"     -- сервер -> клиент(все): проиграть звук в точке мира
--
-- Этот Lua-файл можно не использовать в Roblox — он только описывает структуру.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local folder = ReplicatedStorage:FindFirstChild("FreddyRemotes")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "FreddyRemotes"
	folder.Parent = ReplicatedStorage
end

local function ensureRemote(name)
	local r = folder:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = folder
	end
	return r
end

ensureRemote("FreddySpotted")
ensureRemote("FreddyJumpscare")
ensureRemote("FreddySound")

return folder
