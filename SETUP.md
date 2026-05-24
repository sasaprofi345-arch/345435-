# Настройка проекта в Roblox Studio

Этот документ описывает, какие объекты нужно создать в Roblox Studio, чтобы скрипты Фредди заработали.

## Скрипты — куда положить

| Файл | Куда в Roblox Studio | Тип Instance |
|---|---|---|
| `src/ServerScriptService/FreddyAI.server.lua` | `ServerScriptService` | **Script** |
| `src/StarterPlayer/StarterPlayerScripts/FlashlightClient.client.lua` | `StarterPlayer → StarterPlayerScripts` | **LocalScript** |
| `src/ReplicatedStorage/FreddyRemotes.lua` *(опционально)* | `ReplicatedStorage` | **Script** *(или создайте папку/события вручную)* |

> Расширения `.server.lua` и `.client.lua` — это конвенция Rojo. Если вы копируете код вручную в Studio, расширение игнорируйте — важен только **тип Instance** в правой колонке.

## Иерархия объектов в Workspace

```
Workspace
├── Freddy                       (Model)            ← враг
│   ├── HumanoidRootPart         (BasePart)         ← PrimaryPart модели
│   ├── Head                     (BasePart)
│   ├── Torso                    (BasePart)
│   └── ...                      (любые другие части модели)
│
└── FreddySpawnPoints            (Folder)           ← точки телепортации
    ├── Point1                   (Part, Anchored, Transparency = 1, CanCollide = false)
    ├── Point2                   (Part, Anchored, Transparency = 1, CanCollide = false)
    ├── Point3                   (Part, Anchored, Transparency = 1, CanCollide = false)
    └── ...                      (добавьте сколько хотите)
```

### Важные настройки

- **Freddy (Model)** — обязательно задайте `PrimaryPart` (например, `HumanoidRootPart`). Без него скрипт упадёт с assertion-ошибкой.
- **Все части Freddy** — скрипт автоматически делает их `Anchored = true` и `CanCollide = false`. Если хотите коллизию (чтобы игрок не мог пройти сквозь), уберите эту строку в `FreddyAI.server.lua` (комментарий `чтобы игрок не натыкался`).
- **Точки спавна** — расставьте по тёмной локации в местах, где Фредди должен появляться. Сделайте их прозрачными (`Transparency = 1`) и `CanCollide = false`, чтобы не мешали игроку.

## Иерархия в ReplicatedStorage

```
ReplicatedStorage
└── FreddyRemotes                (Folder)
    ├── FreddySpotted            (RemoteEvent)   ← клиент → сервер
    ├── FreddyJumpscare          (RemoteEvent)   ← сервер → конкретный клиент
    └── FreddySound              (RemoteEvent)   ← сервер → все клиенты
```

> Если вы оставите `FreddyRemotes.lua` в `ReplicatedStorage` или будете запускать `FreddyAI.server.lua` — папка и события создадутся автоматически на старте сервера. Но проще создать их в Studio один раз вручную.

## Звуки

В `FlashlightClient.client.lua` найдите блок `CONFIG.Sounds` и подставьте свои `rbxassetid://...`:

```lua
Sounds = {
    Jumpscare = "rbxassetid://0000000000",  -- скример (резкий)
    Laugh     = "rbxassetid://0000000000",  -- смех Фредди
    Drop      = "rbxassetid://0000000000",  -- падение предмета
},
```

Вы можете загрузить свои звуки через **Asset Manager → Audio → Bulk Import**, и подставить полученные ID.

## Управление

| Действие | Клавиша |
|---|---|
| Включить / выключить фонарик | `F` |

> Хотите ЛКМ-удержание (как в JoC)? Замените блок `UserInputService.InputBegan` на:
> ```lua
> UserInputService.InputBegan:Connect(function(i, gpe)
>     if not gpe and i.UserInputType == Enum.UserInputType.MouseButton1 then
>         flashlight:setOn(true)
>     end
> end)
> UserInputService.InputEnded:Connect(function(i)
>     if i.UserInputType == Enum.UserInputType.MouseButton1 then
>         flashlight:setOn(false)
>     end
> end)
> ```

## Тюнинг

Параметры поведения находятся в `CONFIG` в начале каждого скрипта:

**Сервер (`FreddyAI.server.lua`):**
- `IdleTimeMin/Max` — как долго Фредди стоит на точке.
- `SoundChancePerSec` — шанс издать звук каждую секунду.
- `JumpscareDistance` — насколько близко камера "прыгает" к лицу Фредди.
- `FleeDelay` — задержка перед побегом после скримера.

**Клиент (`FlashlightClient.client.lua`):**
- `FlashlightRange` — дальность луча.
- `FlashlightAngleDeg` — половинный угол конуса детекции (чем меньше — тем точнее нужно целиться).
- `DetectCooldown` — пауза между отправкой сигнала на сервер.

## Архитектура: почему именно так

- **Серверная проверка обнаружения.** Клиент шлёт `FreddySpotted` без аргументов — сервер сам делает Raycast от головы игрока к позиции Фредди. Это защита от чита: клиент не может "вызвать скример" по своему желанию.
- **Anchored + PivotTo.** Враг не использует Humanoid/PathfindingService — он телепортируется через `PivotTo`. Это **намного дешевле** по производительности и подходит под механику "появляется и исчезает".
- **3D-звуки через клиента.** Сервер шлёт только тип звука и позицию — клиент сам создаёт Sound в Workspace и удаляет после окончания. Звуки не реплицируются с сервера → меньше нагрузки на сеть.
- **Кулдауны.** `SpotCooldown` на сервере + `DetectCooldown` на клиенте → даже если Raycast попадает каждый кадр, скример не зациклится.
