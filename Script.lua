-- ================================================================
-- 🧠 GARDEN TD AI  v9.7   —  переписано ПО РЕАЛЬНОМУ ДАМПУ ИГРЫ
-- v9.7: ИЗУЧЕНИЕ КАРТЫ (choke-точки: пересечения/центры петель) + ходьба к ним,
--       предсказание слива → КОПИТЬ на косилку вместо апгрейдов, когда она спасёт.
-- карты: map_farm, map_island (остальные — волны тянутся из модуля карты)
--
-- v9.6: РОТАЦИЯ ДОРОЖЕК как на сервере (AllowedPaths, дамп 173822): покрытие
--       считается раздельно по линиям, ценятся точки, бьющие по обеим сразу
--       (пересечения / общая зона), DPS доски считается под текущую волну.
-- v9.5: Terrain-точки (центр петель и пересечения дорожек), бонус за
--       несколько линий в радиусе, косилки ТОЛЬКО экстренно, раффлезии не у базы,
--       резервный слот под косилку, режим "босс близко".
-- v9.4: косилка ставится В КОНЕЦ дорожки (она едет назад к спавну!),
--       раффлезия разносится по пути и не стоит у базы,
--       места выбираются по НОВОМУ покрытию пути (пересечения дорожек),
--       единая метрика "урон за кэш" → апгрейды вместо спама косилок,
--       сложность фиксированная в CFG + клавиши 1..5, поддержка 1..4 дорожек,
--       GUI-записи под pcall (экзекутор: lacking capability Plugin).
--
-- Что исправлено относительно v8 (причины "ставит только одного"):
--  1) СТАРТОВЫЙ КЭШ = 250 (dif_normal) → хватало ровно на один Bonsai (250).
--     v8 после этого выходил из цикла и больше ничего не делал.
--     Теперь: постоянный эконом-цикл, докупает по мере дохода.
--  2) Сервер валидирует место через SharedModelPlacement.IsPlacementValid:
--       • точка ОБЯЗАНА лежать на частях из workspace.Map.Placeable
--         (или на голом Terrain) — иначе "collision" → "You can't place there!"
--       • не ближе 100 студов к HumanoidRootPart персонажа → "distance"
--       • не пересекаться с другими юнитами (FlatDistance < 1)
--     v8 рейкастил "куда угодно" → почти все попытки отбивались сервером.
--  3) v8 после 3 неудач ВЫКИДЫВАЛ юнит из списка owned навсегда
--     (table.remove) → список пустел → "больше некого ставить".
--  4) ЛОВУШКИ (unit_trap) ставятся ДРУГИМ способом: сервер ждёт
--     {Position = <точка у пути>, PathIndex = <индекс пути>} и сам
--     snapping'ит юнит на путь (ветка PlaceUnit без IsPlacementValid).
--     v8 слал только CF → ловушки не работали.
--  5) unit_bronze_lawnmower не имеет своего UnitConfig — это скин
--     BaseUnit = "unit_lawnmower" (а это unit_trap = СТАВИТСЯ НА ПУТЬ).
--     v8 считал его обычным ranged и пытался поставить вне пути → отказ.
--  6) Сервер возвращает (true, entityId) / (false, reason) / nil.
--     v8 считал nil успехом и потом 3 раза "не видел модель" → сливал кэш.
--  7) PlacementCooldown (rafflesia 15с, lawnmower 3с) и Resell-кулдаун
--     теперь читаются из player.PlacementCooldowns.
--  8) Волна берётся из workspace:GetAttribute("Round"), а не из текста GUI.
--  9) PlaceDifficultyVote ждёт СТРОКУ ("dif_normal"), а не 1.
--
-- Добавлено по запросу:
--  • БАЗА: workspace.Map.BaseHP (Part) + workspace.BaseHP / MaxBaseHP
--    (+ BaseHP_1 / BaseHP_2 для команд). Урон базе = ТЕКУЩЕЕ HP врага,
--    а босс (enemy_snail_king) наносит 999999999 → мгновенный проигрыш.
--  • ВРАГИ: живой реестр сущностей (Data.Health/MaxHealth/Position/
--    DistanceTravelled/Speed) + фолбэк по HPDisplay-бару над врагом.
--  • ВОЛНЫ: полная таблица волн map_farm из дампа (HP/скорость каждого
--    врага на каждой сложности) → AI знает, что придёт дальше.
--  • ЮНИТЫ НА ПУТИ: все unit_trap + PlaceOnPath ставятся на путь.
--
-- M — полное уничтожение скрипта
-- ================================================================

math.randomseed(os.clock() * 1e6 + math.random(1, 99999))

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local CS          = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local UIS         = game:GetService("UserInputService")
local RunService  = game:GetService("RunService")

local LP = Players.LocalPlayer
local RF = RS:WaitForChild("RemoteFunctions", 10)

local Remotes = {}
for _, name in ipairs({
	"PlaceUnit", "UpgradeUnit", "SellUnit", "UpgradeAll", "SellAll",
	"ToggleAutoUpgrade", "ToggleAutoUpgradePriority", "LockUnit",
	"PlaceDifficultyVote", "RestartGame", "SkipWave", "ChangeTickSpeed",
}) do
	Remotes[name] = RF and RF:FindFirstChild(name)
end

-- ================================================================
-- ⚙️ НАСТРОЙКИ
-- ================================================================
local DIFFICULTIES = {"dif_easy", "dif_normal", "dif_hard", "dif_insane", "dif_impossible"}

-- ════════════════════════════════════════════════════════════════
--  СЛОЖНОСТЬ: выбери ОДИН РАЗ — дальше она подставляется автоматически
--    ""              = авто: последняя выбранная (клавишей 1-5), хранится в brain.json
--    "dif_insane"    = всегда голосовать за insane и т.д.
--  Значения: dif_easy | dif_normal | dif_hard | dif_insane | dif_impossible
-- ════════════════════════════════════════════════════════════════
local MY_DIFFICULTY = ""

local CFG = {
	folder = "AI_GardenTD_v9",
	brain  = "AI_GardenTD_v9/brain.json",

	-- ══════════════════════════════════════════════════════════════
	-- СЛОЖНОСТЬ: ставь свою, она выбирается ВСЕГДА (не случайно)
	--   dif_easy | dif_normal | dif_hard | dif_insane | dif_impossible
	-- Горячие клавиши в игре: 1=easy 2=normal 3=hard 4=insane 5=impossible
	-- Выбор запоминается в brain.json и подставляется при следующем запуске.
	-- ══════════════════════════════════════════════════════════════
	difficulty     = "dif_hard",   -- значение по умолчанию, перекрывается MY_DIFFICULTY / brain.json
	voteDifficulty = true,         -- голосовать за свою сложность в начале каждой игры
	rememberDifficulty = true,     -- запоминать выбор в brain.json и применять в следующих играх

	maxPerGame     = 20,   -- серверный лимит обычно 20 (PropertyTotalValue_MaxUnitsPlaced)
	minGap         = 2.4,  -- сервер требует >= 1 студ, берём с запасом
	charRangeLimit = 96,   -- сервер: 100 студов от HumanoidRootPart
	walkToSpots    = true, -- дойти персонажем, если все места далеко

	farmsEarly     = 3,    -- сколько ферм (Income) поставить в начале
	farmUntilWave  = 10,   -- до этой волны ставим фермы
	maxRepeaters   = 3,    -- ПОВТОРЯЮЩИХСЯ ловушек на путь (rafflesia) — они постоянные
	maxChargers    = 2,    -- ОДНОРАЗОВЫХ (lawnmower) держать про запас, не больше
	chargerHits    = 2,    -- сколько врагов в среднем сбивает одна косилка за заезд
	chargerCashMult= 3,    -- покупать расходник, только если кэша в N раз больше его цены
	cashToDps      = 0.02, -- во сколько урона конвертируется 1 кэш дохода (калибровка игры)
	upgradeBias    = 1.25, -- >1 = предпочитаем апгрейд новой постановке при равной выгоде
	trapsNearBase  = 3,    -- для экстренной реакции у базы
	equipOnFail    = true, -- если сервер молча отказал (nil) — экипировать тул и повторить

	reserveCash    = 0,    -- неснижаемый остаток
	keepOneSlot    = false,-- держать 1 слот под ловушку

	sampleStep     = 4,    -- шаг сетки по Placeable-частям (студы)
	pathSampleStep = 2,    -- шаг семплирования пути для расчёта покрытия
	maxCandidates  = 900,
	shortlistSize  = 45,   -- сколько лучших точек пересчитывать по "новому покрытию"
	maxSpotPathDist = 55,  -- дальше скольких студов от дорожки точки не рассматриваем
	terrainStep    = 7,    -- шаг рейкаста по Terrain (пляж, центр петель)
	maxTerrainSpots= 1600, -- максимум точек с Terrain (шаг адаптируется под лимит)
	maxGroundSpots = 700,  -- итоговый лимит наземных точек (берём ближайшие к пути)

	-- ЛОВУШКИ
	chargerTriggerStuds = 12,  -- враг в N студах от базы → срочно кидаем косилку.
	                           -- Ты просил 5, но решение принимается раз в ~1.5 с:
	                           -- на 5 студах враг со скоростью 6 уже успеет долить базу.
	                           -- Хочешь совсем впритык — верни 5.
	chargerHpMargin     = 20,  -- косилку имеет смысл кидать, если HP врага <= урона + margin
	trapIdealRel        = 0.40,-- где вдоль дорожки лучше держать повторяющуюся ловушку
	                           -- (0 = спавн, 1 = база). У базы — только косилки.
	chargersProactive   = false, -- покупать косилку "просто потому что враги на пути"?
	                             -- false = ТОЛЬКО экстренно (враг у базы с HP <= урона)
	keepEmergencySlot   = true,  -- держать 1 свободный слот под экстренную косилку
	planRangeMult       = 1.45,  -- при выборе места чуть учитывать радиус ПОСЛЕ апгрейдов
	walkScoreMargin     = 0.8,   -- насколько choke-точка должна быть лучше ближайших,
	                             -- чтобы AI пошёл к ней пешком (лимит сервера 100 студов)
	crossingBonus       = 0.9,   -- бонус месту, которое накрывает >=2 отдельных участков пути
	                             -- (пересечения дорожек, центр квадратной петли)

	learnRate      = 0.25,
	exploration    = 0.10,

	breakEveryMin  = 2,
	breakEveryMax  = 4,
	breakTimeMin   = 20,
	breakTimeMax   = 50,
	sessionCap     = 14,

	placeDelay     = {0.5, 1.1},
	actionDelay    = {0.8, 1.6},
}

if MY_DIFFICULTY ~= "" then
	CFG.difficulty = MY_DIFFICULTY
end

-- ================================================================
-- 🗑️ CLEAN DESTROY (M)
-- ================================================================
local destroyed = false
local stopAI    = false
local running   = false
local conns     = {}

local function connect(sig, fn)
	local c = sig:Connect(fn)
	table.insert(conns, c)
	return c
end

local guiRef
local function destroyAll()
	if destroyed then return end
	destroyed = true
	stopAI = true
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	table.clear(conns)
	task.defer(function()
		task.wait(0.05)
		if guiRef then pcall(function() guiRef:Destroy() end) end
		print("[AI] ✅ Всё уничтожено.")
	end)
end

-- ================================================================
-- 🛠 УТИЛИТЫ
-- ================================================================
local function log(...) print("[AI]", ...) end
local function rnd(a, b) return a + math.random() * (b - a) end
local function waitHuman(a, b) task.wait(rnd(a or 0.3, b or 0.9)) end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function flat(a, b) local dx, dz = a.X - b.X, a.Z - b.Z return math.sqrt(dx * dx + dz * dz) end

-- "1.2K" / "3.5M" → число
local MULT = {K = 1e3, M = 1e6, B = 1e9, T = 1e12, k = 1e3, m = 1e6, b = 1e9, t = 1e12}
local function parseAbbrev(s)
	if type(s) ~= "string" then return nil end
	local num, suf = s:match("^%s*([%d%.]+)%s*([KM BTkm bt]?)")
	if not num then return nil end
	local v = tonumber(num)
	if not v then return nil end
	if suf and MULT[suf] then v = v * MULT[suf] end
	return v
end

-- ================================================================
-- 📚 СТАТИЧЕСКАЯ БАЗА ИЗ ДАМПА
-- ================================================================
-- Полные волны map_farm и map_island: {enemyId, count, health, speed}
-- (для остальных карт волны подтягиваются живьём из модуля карты)
local WAVE_DB = {
    map_farm = {
        dif_easy = {
            {{"enemy_aphid",2,8,0}},
            {{"enemy_aphid",3,8,0}},
            {{"enemy_aphid",2,5,0}},
            {{"enemy_ant",1,30,2}},
            {{"enemy_ant",1,30,2},{"enemy_aphid",5,5,3}},
            {{"enemy_ant",3,30,3}},
            {{"enemy_aphid",10,7,5}},
            {{"enemy_roach",1,60,6}},
            {{"enemy_ant",5,30,4},{"enemy_roach",2,50,6}},
            {{"enemy_worm",1,500,2}},
            {{"enemy_roach",5,100,5}},
            {{"enemy_worm",5,300,3}},
            {{"enemy_snail",2,2000,1}},
            {{"enemy_snail",1,2000,1},{"enemy_worm",3,500,2}},
            {{"enemy_snail_king",1,3500,2}},
        },
        dif_normal = {
            {{"enemy_aphid",5,7,3}},
            {{"enemy_aphid",7,7,3}},
            {{"enemy_ant",1,50,2}},
            {{"enemy_ant",1,50,2},{"enemy_aphid",6,7,4}},
            {{"enemy_aphid",10,10,5}},
            {{"enemy_ant",2,50,2},{"enemy_aphid",5,7,2}},
            {{"enemy_roach",1,100,7}},
            {{"enemy_ant",1,50,2},{"enemy_roach",1,100,7}},
            {{"enemy_aphid",20,20,4}},
            {{"enemy_worm",1,1000,2}},
            {{"enemy_roach",4,100,6}},
            {{"enemy_worm",1,1000,2},{"enemy_roach",3,100,7}},
            {{"enemy_worm",2,1000,3}},
            {{"enemy_ladybug",20,200,5}},
            {{"enemy_snail",1,3000,3},{"enemy_ladybug",5,200,5}},
            {{"enemy_worm",5,1000,3}},
            {{"enemy_snail",2,3000,3}},
            {{"enemy_ladybug",15,200,5},{"enemy_worm",5,1000,3}},
            {{"enemy_snail",3,5000,2}},
            {{"enemy_snail_king",1,30000,1}},
        },
        dif_hard = {
            {{"enemy_aphid",5,12,0}},
            {{"enemy_aphid",8,12,0}},
            {{"enemy_aphid",3,12,0},{"enemy_ant",1,75,2}},
            {{"enemy_aphid",5,12,0},{"enemy_ant",2,75,2}},
            {{"enemy_roach",1,75,6},{"enemy_ant",1,75,2}},
            {{"enemy_aphid",20,12,0}},
            {{"enemy_aphid",4,12,0},{"enemy_ant",2,75,2},{"enemy_roach",1,100,6}},
            {{"enemy_roach",1,800,1}},
            {{"enemy_ant",1,650,2},{"enemy_roach",2,100,6}},
            {{"enemy_roach",7,100,6}},
            {{"enemy_roach",2,800,1}},
            {{"enemy_ladybug",4,300,5}},
            {{"enemy_ladybug",2,300,5},{"enemy_roach",3,650,2}},
            {{"enemy_ladybug",7,300,5}},
            {{"enemy_mole",1,9000,2}},
            {{"enemy_worm",5,1200,4}},
            {{"enemy_worm",2,1200,4},{"enemy_mole",1,6000,2}},
            {{"enemy_mole",2,6000,2}},
            {{"enemy_mole",1,12000,2}},
            {{"enemy_snail",1,40000,1}},
            {{"enemy_mole",4,6000,2}},
            {{"enemy_jockey",7,1200,7},{"enemy_snail",1,20000,2}},
            {{"enemy_snail",4,20000,2}},
            {{"enemy_jockey",12,1200,7}},
            {{"enemy_snail_king",1,100000,2}},
        },
        dif_insane = {
            {{"enemy_aphid",8,20,3}},
            {{"enemy_aphid",12,20,3}},
            {{"enemy_ant",2,100,4}},
            {{"enemy_ant",1,100,4},{"enemy_aphid",8,20,3}},
            {{"enemy_ant",2,100,5}},
            {{"enemy_ant",1,100,5},{"enemy_roach",1,400,2}},
            {{"enemy_roach",3,400,2}},
            {{"enemy_ant",7,100,5}},
            {{"enemy_roach",3,400,3}},
            {{"enemy_worm",2,1500,2}},
            {{"enemy_roach",3,500,3},{"enemy_ant",5,100,5}},
            {{"enemy_roach",2,700,6}},
            {{"enemy_worm",4,1500,2}},
            {{"enemy_roach",2,700,6},{"enemy_worm",2,1500,2}},
            {{"enemy_mole",1,7000,3}},
            {{"enemy_roach",5,700,6}},
            {{"enemy_mole",1,5000,3},{"enemy_worm",4,1500,2}},
            {{"enemy_ladybug",8,1000,4}},
            {{"enemy_mole",2,5000,3},{"enemy_ladybug",7,1000,4}},
            {{"enemy_snail",1,50000,2}},
            {{"enemy_ladybug",25,1000,4}},
            {{"enemy_mole",3,10000,3},{"enemy_jockey",1,7500,6}},
            {{"enemy_snail",1,50000,2},{"enemy_jockey",3,7500,6}},
            {{"enemy_snail",3,50000,2}},
            {{"enemy_snail_king",1,150000,2},{"enemy_jockey",4,7500,6}},
            {{"enemy_snail",3,25000,3},{"enemy_jockey",5,7500,6}},
            {{"enemy_snail",5,50000,2}},
            {{"enemy_snail",2,25000,3},{"enemy_jockey",8,7500,6},{"enemy_snail",1,50000,2}},
            {{"enemy_snail_king",2,100000,3}},
            {{"enemy_snail_king",1,400000,2}},
        },
        dif_impossible = {
            {{"enemy_aphid",10,30,3}},
            {{"enemy_aphid",12,30,3},{"enemy_ant",1,50,2}},
            {{"enemy_aphid",15,30,3},{"enemy_ant",1,50,2}},
            {{"enemy_aphid",18,30,3},{"enemy_ant",1,75,2}},
            {{"enemy_ant",1,100,5}},
            {{"enemy_ant",2,100,5},{"enemy_roach",1,100,2}},
            {{"enemy_roach",2,100,2},{"enemy_ant",1,150,5}},
            {{"enemy_ant",3,100,5},{"enemy_roach",1,100,2}},
            {{"enemy_roach",3,150,3},{"enemy_ant",2,100,5}},
            {{"enemy_worm",1,1500,2}},
            {{"enemy_roach",3,150,3},{"enemy_ant",5,60,5}},
            {{"enemy_roach",2,700,6}},
            {{"enemy_worm",2,1500,2},{"enemy_roach",1,700,6}},
            {{"enemy_roach",2,700,6},{"enemy_worm",2,1500,2}},
            {{"enemy_mole",1,5000,3},{"enemy_ladybug",1,750,4}},
            {{"enemy_roach",4,700,6},{"enemy_mole",1,2000,3}},
            {{"enemy_mole",1,5000,3},{"enemy_worm",3,1500,2},{"enemy_ladybug",2,500,4}},
            {{"enemy_ladybug",8,800,4},{"enemy_mole",1,5000,3}},
            {{"enemy_mole",2,5000,3},{"enemy_ladybug",5,800,4}},
            {{"enemy_snail",1,50000,2}},
            {{"enemy_ladybug",10,800,4},{"enemy_mole",2,5000,3}},
            {{"enemy_mole",3,5000,3},{"enemy_jockey",4,7500,5}},
            {{"enemy_snail",1,50000,2},{"enemy_jockey",4,7500,5},{"enemy_mole",2,5000,3}},
            {{"enemy_snail",2,50000,2},{"enemy_jockey",5,7500,5}},
            {{"enemy_snail_king",1,125000,2}},
            {{"enemy_snail",3,25000,3},{"enemy_jockey",6,7500,5},{"enemy_snail_king",1,50000,2}},
            {{"enemy_snail",4,50000,2},{"enemy_jockey",4,7500,5},{"enemy_snail_king",1,50000,2}},
            {{"enemy_snail",4,50000,2},{"enemy_jockey",8,7500,6}},
            {{"enemy_snail_king",2,125000,2},{"enemy_jockey",4,7500,6}},
            {{"enemy_snail_king",1,300000,2},{"enemy_jockey",4,25000,5}},
            {{"enemy_mole",2,200000,3},{"enemy_jockey",6,20000,6}},
            {{"enemy_snail",2,350000,2},{"enemy_jockey",8,20000,6}},
            {{"enemy_ladybug",2,265000,4},{"enemy_jockey",8,25000,6}},
            {{"enemy_worm",2,450000,2},{"enemy_jockey",10,25000,6}},
            {{"enemy_snail_king",2,1e+06,2}},
        },
    },
    map_island = {
        dif_easy = {
            {{"enemy_sand_beetle",3,10,5}},
            {{"enemy_sand_beetle",5,10,5}},
            {{"enemy_shell_crab",3,30,4}},
            {{"enemy_sand_beetle",4,10,5},{"enemy_shell_crab",2,30,4}},
            {{"enemy_sand_spider",3,50,4}},
            {{"enemy_sand_beetle",15,10,5}},
            {{"enemy_sand_spider",3,50,4},{"enemy_shell_crab",5,30,4}},
            {{"enemy_shell_crab",10,30,4},{"enemy_sand_spider",1,50,4}},
            {{"enemy_sand_spider",8,50,4},{"enemy_shell_crab",2,30,4}},
            {{"enemy_sand_worm",1,400,5}},
            {{"enemy_sand_worm",1,400,5},{"enemy_sand_spider",8,50,4}},
            {{"enemy_crab",7,150,6}},
            {{"enemy_sand_worm",2,500,5},{"enemy_crab",6,150,6}},
            {{"enemy_cobra",8,500,4}},
            {{"enemy_king_octopus",1,5000,4}},
        },
        dif_normal = {
            {{"enemy_sand_beetle",4,15,5}},
            {{"enemy_shell_crab",3,30,4}},
            {{"enemy_sand_spider",3,50,4}},
            {{"enemy_sand_beetle",4,15,5},{"enemy_shell_crab",3,30,4}},
            {{"enemy_sand_spider",5,50,4}},
            {{"enemy_sand_beetle",8,15,5},{"enemy_shell_crab",4,30,4}},
            {{"enemy_sand_spider",6,50,4},{"enemy_shell_crab",5,30,4}},
            {{"enemy_shell_crab",15,30,4},{"enemy_sand_spider",3,50,4}},
            {{"enemy_sand_spider",15,50,4},{"enemy_shell_crab",5,30,4}},
            {{"enemy_sand_worm",2,400,5},{"enemy_shell_crab",4,30,4}},
            {{"enemy_sand_worm",3,400,5},{"enemy_sand_spider",5,50,4}},
            {{"enemy_sand_worm",2,400,5},{"enemy_crab",8,150,6}},
            {{"enemy_sand_worm",3,400,5},{"enemy_crab",8,150,6}},
            {{"enemy_cobra",2,3500,4}},
            {{"enemy_king_octopus",1,8000,4}},
            {{"enemy_cobra",4,3500,4}},
            {{"enemy_crab",20,150,6},{"enemy_cobra",4,3500,4}},
            {{"enemy_sand_scorpion",2,9000,3},{"enemy_cobra",2,3500,4}},
            {{"enemy_cobra",4,4000,4},{"enemy_sand_scorpion",2,8000,3}},
            {{"enemy_king_octopus",1,40000,3}},
        },
        dif_hard = {
            {{"enemy_sand_beetle",5,25,5}},
            {{"enemy_sand_beetle",8,25,5}},
            {{"enemy_shell_crab",6,50,4}},
            {{"enemy_sand_beetle",8,25,5},{"enemy_shell_crab",5,50,4}},
            {{"enemy_sand_spider",9,75,4}},
            {{"enemy_sand_beetle",15,25,5}},
            {{"enemy_sand_spider",7,75,4},{"enemy_shell_crab",10,50,4}},
            {{"enemy_shell_crab",25,50,4}},
            {{"enemy_sand_spider",17,75,4}},
            {{"enemy_sand_worm",3,500,5}},
            {{"enemy_sand_worm",4,500,5},{"enemy_sand_spider",10,75,4}},
            {{"enemy_crab",20,150,6}},
            {{"enemy_sand_worm",6,500,5},{"enemy_crab",6,150,6}},
            {{"enemy_cobra",2,5000,4}},
            {{"enemy_king_octopus",1,15000,4}},
            {{"enemy_cobra",4,5000,4}},
            {{"enemy_crab",20,150,6},{"enemy_cobra",4,5000,4}},
            {{"enemy_sand_scorpion",3,12000,3}},
            {{"enemy_cobra",2,5000,4},{"enemy_sand_scorpion",2,12000,3}},
            {{"enemy_king_octopus",2,30000,3}},
            {{"enemy_sand_scorpion",6,12000,3}},
            {{"enemy_cobra",11,5000,4}},
            {{"enemy_cobra",5,5000,4},{"enemy_sand_scorpion",4,12000,3}},
            {{"enemy_sand_scorpion",5,12000,3},{"enemy_cobra",7,5000,4},{"enemy_sand_worm",15,500,5}},
            {{"enemy_king_octopus",1,180000,3}},
        },
        dif_insane = {
            {{"enemy_sand_beetle",5,40,5}},
            {{"enemy_sand_beetle",8,40,5}},
            {{"enemy_shell_crab",6,80,4}},
            {{"enemy_sand_beetle",8,40,5},{"enemy_shell_crab",6,80,4}},
            {{"enemy_sand_spider",10,75,5}},
            {{"enemy_sand_beetle",15,40,5},{"enemy_shell_crab",10,80,4}},
            {{"enemy_sand_spider",12,75,5},{"enemy_shell_crab",10,80,4}},
            {{"enemy_shell_crab",15,80,4},{"enemy_sand_spider",12,75,5}},
            {{"enemy_sand_spider",20,75,5},{"enemy_shell_crab",10,80,4},{"enemy_sand_beetle",5,40,5}},
            {{"enemy_sand_worm",4,700,5}},
            {{"enemy_sand_worm",5,700,5},{"enemy_sand_spider",10,75,5}},
            {{"enemy_crab",25,150,6},{"enemy_sand_spider",10,75,5}},
            {{"enemy_sand_worm",6,700,5},{"enemy_crab",25,150,6},{"enemy_shell_crab",15,80,4}},
            {{"enemy_cobra",2,6000,6}},
            {{"enemy_king_octopus",1,25000,4}},
            {{"enemy_cobra",3,6000,6},{"enemy_sand_worm",10,700,5}},
            {{"enemy_crab",20,150,6},{"enemy_cobra",3,6000,6},{"enemy_sand_worm",7,700,5}},
            {{"enemy_sand_scorpion",2,20000,5}},
            {{"enemy_cobra",3,6000,6},{"enemy_sand_scorpion",2,20000,5},{"enemy_crab",25,150,6}},
            {{"enemy_king_octopus",2,50000,4}},
            {{"enemy_sand_scorpion",4,20000,5},{"enemy_cobra",5,6000,6},{"enemy_sand_worm",20,700,5}},
            {{"enemy_cobra",5,6000,6},{"enemy_crab",15,150,6},{"enemy_sand_scorpion",5,20000,5}},
            {{"enemy_cobra",5,6000,6},{"enemy_sand_scorpion",6,20000,5},{"enemy_crab",25,150,6},{"enemy_sand_worm",10,700,5}},
            {{"enemy_sand_scorpion",6,20000,5},{"enemy_cobra",8,6000,6},{"enemy_sand_worm",15,700,5},{"enemy_crab",20,150,6}},
            {{"enemy_king_octopus",1,250000,4}},
            {{"enemy_lobster",8,50000,3},{"enemy_sand_scorpion",5,20000,5}},
            {{"enemy_cobra",10,6000,6},{"enemy_lobster",3,70000,3},{"enemy_sand_scorpion",5,20000,5}},
            {{"enemy_lobster",4,80000,3},{"enemy_cobra",15,6000,6}},
            {{"enemy_lobster",2,100000,3},{"enemy_sand_scorpion",10,20000,5}},
            {{"enemy_king_cobra",1,450000,4}},
        },
        dif_impossible = {
            {{"enemy_sand_beetle",6,60,5}},
            {{"enemy_sand_beetle",8,60,5}},
            {{"enemy_shell_crab",6,120,4}},
            {{"enemy_sand_beetle",8,60,5},{"enemy_shell_crab",6,120,4}},
            {{"enemy_sand_spider",11,105,5}},
            {{"enemy_sand_beetle",10,60,5},{"enemy_shell_crab",10,120,4}},
            {{"enemy_sand_spider",12,105,5},{"enemy_shell_crab",10,120,4}},
            {{"enemy_shell_crab",15,120,4},{"enemy_sand_spider",10,105,5}},
            {{"enemy_sand_spider",12,105,5},{"enemy_shell_crab",12,120,4},{"enemy_sand_beetle",8,60,5}},
            {{"enemy_sand_worm",3,1000,5}},
            {{"enemy_sand_worm",3,1000,5},{"enemy_sand_spider",12,105,5},{"enemy_shell_crab",10,120,4}},
            {{"enemy_crab",13,500,7},{"enemy_sand_spider",5,105,5}},
            {{"enemy_sand_worm",5,1000,5},{"enemy_crab",10,500,7},{"enemy_shell_crab",15,120,4}},
            {{"enemy_cobra",2,8000,6}},
            {{"enemy_king_octopus",1,25000,5}},
            {{"enemy_cobra",5,8000,6},{"enemy_sand_worm",10,1000,5}},
            {{"enemy_crab",20,500,7},{"enemy_cobra",4,8000,6},{"enemy_sand_worm",10,1000,5}},
            {{"enemy_sand_scorpion",3,25000,5}},
            {{"enemy_cobra",5,8000,6},{"enemy_sand_scorpion",2,25000,5},{"enemy_crab",25,500,7}},
            {{"enemy_king_octopus",2,100000,5}},
            {{"enemy_sand_scorpion",5,40000,5},{"enemy_cobra",10,8000,6},{"enemy_sand_worm",25,1000,5}},
            {{"enemy_cobra",10,8000,6},{"enemy_crab",15,500,7},{"enemy_sand_scorpion",6,40000,5}},
            {{"enemy_cobra",10,8000,6},{"enemy_sand_scorpion",7,40000,5},{"enemy_crab",25,500,7},{"enemy_sand_worm",25,1000,5}},
            {{"enemy_sand_scorpion",10,40000,5},{"enemy_cobra",10,8000,6},{"enemy_sand_worm",15,1000,5},{"enemy_crab",25,500,7}},
            {{"enemy_king_octopus",1,700000,4}},
            {{"enemy_lobster",5,150000,3},{"enemy_sand_scorpion",5,40000,5}},
            {{"enemy_cobra",10,8000,6},{"enemy_lobster",4,150000,3},{"enemy_sand_scorpion",5,40000,5}},
            {{"enemy_lobster",6,150000,3},{"enemy_cobra",15,8000,6}},
            {{"enemy_lobster",5,150000,3},{"enemy_sand_scorpion",10,40000,5}},
            {{"enemy_king_cobra",1,1.2e+06,4}},
            {{"enemy_baby_octopus",5,350000,3}},
            {{"enemy_baby_octopus",5,300000,3},{"enemy_king_octopus",1,500000,4}},
            {{"enemy_lobster",15,150000,3},{"enemy_sand_scorpion",5,40000,5}},
            {{"enemy_baby_octopus",9,300000,3}},
            {{"enemy_king_cobra",1,2.25e+06,4}},
        },
    },
}

-- Характеристики юнитов из дампа (фолбэк, если require конфигов не сработал)
-- dps = Damage * APM / 60
local UNIT_FALLBACK = {
	unit_bonsai = {
		Name = "Bonsai Tree", UnitType = "unit_ranged", Cost = 250, MaxPlaced = 6,
		Range = 8, Damage = 8, APM = 30, Income = 15, Interval = 5,
		Upgrades = {
			{Cost = 300,  Range = 10, Damage = 16,  APM = 34, Income = 30, Interval = 4.5},
			{Cost = 450,  Range = 12, Damage = 25,  APM = 40, Income = 40, Interval = 4},
			{Cost = 650,  Range = 14, Damage = 35,  APM = 48, Income = 50, Interval = 3.5},
			{Cost = 900,  Range = 17, Damage = 50,  APM = 60, Income = 60, Interval = 3},
		},
	},
	unit_lawnmower = {
		Name = "Lawnmower", UnitType = "unit_trap", Cost = 700, PlacementCooldown = 3,
		Damage = 300, Speed = 12, ActivationDistance = 2,
		Upgrades = {
			{Cost = 700,  Damage = 600},
			{Cost = 1400, Damage = 900},
			{Cost = 1800, Damage = 1200},
			{Cost = 2300, Damage = 1500},
		},
	},
	unit_bronze_lawnmower = {BaseUnit = "unit_lawnmower", Name = "Bronze Lawnmower", Cost = 700},
	unit_rafflesia = {
		Name = "Rafflesia", UnitType = "unit_trap", Cost = 1250, MaxPlaced = 6,
		PlacementCooldown = 15, Damage = 600, APM = 12, DamageDistance = 6, ActivationDistance = 1,
		Upgrades = { {Cost = 8000, Damage = 1500, APM = 50} },
	},
	unit_brightflower = {
		Name = "Petalray", UnitType = "unit_ranged", Cost = 2500, MaxPlaced = 4,
		Range = 15, Damage = 50, APM = 21,
		Upgrades = {
			{Cost = 2250, Range = 20, Damage = 100,  APM = 24},
			{Cost = 5750, Range = 25, Damage = 200,  APM = 30},
			{Cost = 7000, Range = 30, Damage = 350,  APM = 40},
			{Cost = 9000, Range = 35, Damage = 500,  APM = 60},
		},
	},
	unit_seed_wing = {
		Name = "Zapseed", UnitType = "unit_ranged", Cost = 3000, MaxPlaced = 5,
		Range = 12, Damage = 100, APM = 30, MovesAround = true,
		Upgrades = {
			{Cost = 5000,  Damage = 400},
			{Cost = 9000,  Damage = 1000},
			{Cost = 14000, Damage = 2400},
			{Cost = 20000, Damage = 4000},
		},
	},
	unit_shroom_overlord = {
		Name = "Shroom Overlord", UnitType = "unit_ranged", Cost = 4250, MaxPlaced = 2,
		Range = 24, Damage = 80, APM = 30, FireDamage = 10,
		Upgrades = {
			{Cost = 13000, Range = 29, Damage = 650,  APM = 35},
			{Cost = 32000, Range = 33, Damage = 1350, APM = 40},
			{Cost = 37000, Range = 38, Damage = 2500, APM = 50},
			{Cost = 46250, Range = 44, Damage = 3875, APM = 60},
		},
	},
}

local ENEMY_FALLBACK = {
	enemy_aphid      = {Name = "Aphid",      MaxHealth = 8,    Speed = 3},
	enemy_ant        = {Name = "Ant",        MaxHealth = 30,   Speed = 2},
	enemy_roach      = {Name = "Roach",      MaxHealth = 60,   Speed = 6},
	enemy_worm       = {Name = "Worm",       MaxHealth = 500,  Speed = 2},
	enemy_ladybug    = {Name = "Ladybug",    MaxHealth = 1000, Speed = 5},
	enemy_snail      = {Name = "Snail",      MaxHealth = 2000, Speed = 1},
	enemy_snail_king = {Name = "Snail King", MaxHealth = 3000, Speed = 2, IsBoss = true},
	enemy_sand_beetle= {Name = "Sand Beetle",MaxHealth = 10,   Speed = 5},
	enemy_stag_beetle= {Name = "Stag Beetle",MaxHealth = 110,  Speed = 5},
}

-- ================================================================
-- 🌉 МОСТ К МОДУЛЯМ ИГРЫ (require уже загруженных клиентских модулей)
--    require() кэшируется по инстансу → получаем ЖИВЫЕ таблицы игры
-- ================================================================
local Bridge = {}
local BridgeTried = 0

local function initBridge(waitSeconds)
	BridgeTried = BridgeTried + 1
	local pg = LP:FindFirstChild("PlayerGui")
	if not pg then
		local okp, resp = pcall(function() return LP.PlayerGui end)
		if okp then pg = resp end
	end
	if not pg then
		log("⚠️ PlayerGui недоступен — работаю на фолбэках")
		return
	end

	local holder = pg:FindFirstChild("LogicHolder")
	if not holder and waitSeconds then
		holder = pg:WaitForChild("LogicHolder", waitSeconds)
	end
	if not holder then
		log("⚠️ PlayerGui.LogicHolder не найден (игра ещё грузится?) — работаю на фолбэках")
		return
	end
	local CL = holder:FindFirstChild("ClientLoader")
	if not CL then
		log("⚠️ LogicHolder.ClientLoader не найден — работаю на фолбэках")
		return
	end

	local function try(path, need)
		local inst = CL
		for _, part in ipairs(path) do
			inst = inst and inst:FindFirstChild(part)
		end
		if not inst then
			return nil, "нет инстанса " .. table.concat(path, ".")
		end
		if not inst:IsA("ModuleScript") then
			return nil, table.concat(path, ".") .. " не ModuleScript"
		end
		local ok2, mod = pcall(require, inst)
		if not ok2 then
			return nil, "require выдал ошибку: " .. tostring(mod):sub(1, 80)
		end
		if type(mod) ~= "table" then
			return nil, "модуль вернул не таблицу"
		end
		if need and type(mod[need]) ~= "function" then
			return nil, "в модуле нет функции " .. need
		end
		return mod
	end

	local function grab(key, path, need)
		if Bridge[key] then return end
		local mod, why = try(path, need)
		if mod then
			Bridge[key] = mod
			log("  ✓ мост " .. key)
		else
			log("  ✗ мост " .. key .. ": " .. tostring(why) .. " (использую фолбэк)")
		end
	end

	grab("ItemData",    {"Modules", "SharedItemData"}, "GetItem")
	grab("Placement",   {"Modules", "SharedModelPlacement"}, "IsPlacementValid")
	grab("Helper",      {"Modules", "SharedHelper"}, "GetPlaceableModels")
	grab("PathHandler", {"Modules", "SharedTowerDefenseHandler", "PathHandler"}, "GetActivePath")
	grab("UnitsBase",   {"SharedConfig", "ItemData", "Units", "Behaviors", "base"}, "GetActiveEntities")

	-- валидация: модуль должен быть ЖИВЫМ (тем самым, что использует игра),
	-- иначе require создаст пустую копию и будет врать
	if Bridge.ItemData then
		local ok, item = pcall(function() return Bridge.ItemData.GetItem("unit_bonsai") end)
		if not ok or type(item) ~= "table" or type(item.Params) ~= "table" then
			log("  ✗ ItemData не отвечает на GetItem — отключаю мост")
			Bridge.ItemData = nil
		end
	end
	if Bridge.UnitsBase then
		local map = workspace:FindFirstChild("Map")
		local ents = map and map:FindFirstChild("Entities")
		local models = ents and #ents:GetChildren() or 0
		local ok, list = pcall(function() return Bridge.UnitsBase.GetActiveEntities() end)
		local got = (ok and type(list) == "table") and #list or -1
		if not ok then
			log("  ✗ UnitsBase.GetActiveEntities() errored:", list)
			Bridge.UnitsBase = nil
		elseif models > 0 and got == 0 then
			log(string.format("  ✗ UnitsBase врёт (в Map.Entities %.0f моделей, реестр пуст) — отключаю", models))
			Bridge.UnitsBase = nil
		else
			log(string.format("  ✓ UnitsBase: сущностей %.0f (в Map.Entities %.0f)", got, models))
		end
	end
	-- IsPlacementValid специально не "пробуем" здесь: он трогает общий
	-- Region3 игры, проверяем только наличие функции (см. grab выше)
end

-- ================================================================
-- 💰 СОСТОЯНИЕ ИГРОКА / ИГРЫ
-- ================================================================
local function getCash()      return tonumber(LP:GetAttribute("Cash")) or 0 end
local function getTeamIndex() return tonumber(LP:GetAttribute("TeamIndex")) or 1 end
local function usedSlots()    return tonumber(LP:GetAttribute("UnitsPlaced")) or 0 end

local function maxSlots()
	local v = tonumber(LP:GetAttribute("PropertyTotalValue_MaxUnitsPlaced")) or 20
	local force = tonumber(workspace:GetAttribute("ForceMaxPlacedUnits"))
	if force then v = math.min(v, force) end
	return v
end

local function getRound()
	return tonumber(workspace:GetAttribute("Round")) or 0
end

-- реальная сложность текущего забега (сервер пишет её в workspace)
local function currentDifficulty()
	local d = workspace:GetAttribute("Difficulty")
	if type(d) == "string" and d ~= "" then return d end
	return CFG.difficulty
end

local function getMaxRound()
	local v = workspace:GetAttribute("MaxRound")
	if type(v) == "number" then return v end
	-- "inf" в эндлессе
	return 9999
end

local function gameEnded()
	return workspace:GetAttribute("GameEndTime") ~= nil
end

local function gameStarted()
	return workspace:GetAttribute("GameStartTime") ~= nil or getRound() > 0
end

local function isPaused()
	return workspace:GetAttribute("GamePaused") == true
end

local function canPlaceNow()
	if destroyed or stopAI then return false end
	if workspace:GetAttribute("CanPlaceUnits") == false then return false end
	if LP:GetAttribute("PlacementEnabled") == false then return false end
	if LP:GetAttribute("Ghost") then return false end
	if isPaused() then return false end
	local ch = LP.Character
	if ch and ch:GetAttribute("Downed") then return false end
	return true
end

-- ================================================================
-- 🏰 БАЗА (из дампа: workspace.Map.BaseHP + атрибуты BaseHP/MaxBaseHP)
-- ================================================================
local Base = {pos = nil, hp = 250, maxHp = 250, part = nil}

local function updateBase()
	local team = getTeamIndex()
	local hp    = tonumber(workspace:GetAttribute("BaseHP_" .. team))
	    or tonumber(workspace:GetAttribute("BaseHP"))
	local maxHp = tonumber(workspace:GetAttribute("MaxBaseHP_" .. team))
	    or tonumber(workspace:GetAttribute("MaxBaseHP"))
	Base.hp    = hp or Base.hp or 250
	Base.maxHp = maxHp or Base.maxHp or 250

	if not Base.pos then
		local map = workspace:FindFirstChild("Map")
		local part = map and map:FindFirstChild("BaseHP")
		if part and part:IsA("BasePart") then
			Base.part = part
			Base.pos  = part.Position
		end
	end
	return Base
end

-- ================================================================
-- 🛤️ ПУТЬ — точная копия алгоритма PathHandler.LoadPath из дампа
-- ================================================================
local Paths = {}       -- [index] = path object
local ActivePath = nil -- путь, по которому реально идут враги
local ActivePathIndex = 1
local AllSamples = {}  -- точки семплирования ВСЕХ путей (для покрытия)
local SamplesByPath = {}  -- [idx] = точки только этой дорожки (ускоряет расчёт ловушек)
local SampleCover = {} -- [i] = true, если этот кусок пути уже простреливается
local PathUsage = {}   -- [idx] = {count=, hp=, minTtb=}
local RoadParts = {}   -- части дороги (для проверки "не на дороге ли")

local function makePath(pts)
	local segs, cum, total = {}, {}, 0
	for i = 1, #pts - 1 do
		local len = (pts[i + 1] - pts[i]).Magnitude
		segs[i] = len
		total = total + len
		cum[i] = total
	end

	local path = {
		Points = pts, Segs = segs, Cum = cum, Length = total, Samples = {},
	}

	function path.GetPosition(d)
		d = clamp(d, 0, total)
		local acc = 0
		for i = 1, #segs do
			if d <= acc + segs[i] then
				local t = segs[i] > 0 and (d - acc) / segs[i] or 0
				return pts[i]:Lerp(pts[i + 1], t)
			end
			acc = acc + segs[i]
		end
		return pts[#pts]
	end

	function path.GetDistance(pos)
		local best, bestD, acc = 0, math.huge, 0
		for i = 1, #segs do
			local a, b = pts[i], pts[i + 1]
			local ab = b - a
			local den = ab:Dot(ab)
			local t = 0
			if den > 0 then t = clamp((pos - a):Dot(ab) / den, 0, 1) end
			local proj = a + ab * t
			local dd = (pos - proj).Magnitude
			if dd < bestD then
				bestD = dd
				best = acc + t * segs[i]
			end
			acc = acc + segs[i]
		end
		return best, bestD
	end

	-- точки вдоль пути (для расчёта покрытия уроном)
	local step = CFG.pathSampleStep
	local n = math.max(2, math.floor(total / step))
	for i = 0, n do
		local d = total * i / n
		local p = path.GetPosition(d)
		table.insert(path.Samples, {pos = p, d = d, w = total / n})
	end

	return path
end

local function loadPathFromNodes(folder)
	if not folder then return nil end
	local nodes, maxn = {}, 0
	for _, c in ipairs(folder:GetChildren()) do
		if c:IsA("BasePart") then
			local n = tonumber(tostring(c.Name):match("WP_(%d+)"))
			if n then
				nodes[n] = c.Position
				if n > maxn then maxn = n end
			end
		end
	end
	local pts = {}
	for i = 1, maxn do
		if nodes[i] then table.insert(pts, nodes[i]) end
	end
	if #pts < 2 then return nil end
	return makePath(pts)
end

local function collectRoadParts()
	RoadParts = {}
	local map = workspace:FindFirstChild("Map")
	local pm = map and map:FindFirstChild("Path")
	if not pm then return end
	for _, d in ipairs(pm:GetDescendants()) do
		if d:IsA("BasePart") and d.Name ~= "Start" and d.Name ~= "End" then
			table.insert(RoadParts, {
				inv = d.CFrame:Inverse(),
				half = d.Size / 2,
			})
		end
	end
end

-- расстояние от точки до поверхности дорожных частей (0 = внутри)
local function roadDist(pos)
	local best = math.huge
	for _, r in ipairs(RoadParts) do
		local lp = r.inv * pos
		local dx = math.max(math.abs(lp.X) - r.half.X, 0)
		local dz = math.max(math.abs(lp.Z) - r.half.Z, 0)
		local dy = math.max(math.abs(lp.Y) - r.half.Y, 0)
		local d = math.sqrt(dx * dx + dy * dy + dz * dz)
		if d < best then best = d end
	end
	return best
end

local function buildPaths()
	Paths = {}
	local map = workspace:FindFirstChild("Map")
	if not map then return 0 end

	local count = tonumber(map:GetAttribute("Paths")) or 1
	count = clamp(count, 1, 4)

	for i = 1, count do
		local name = "PathNodes"
		if i > 1 then name = "PathNodes" .. i end
		local p = loadPathFromNodes(map:FindFirstChild(name))
		if p then table.insert(Paths, p) end
	end

	-- фолбэк: части с атрибутами StartNode/EndNode (дорога)
	if #Paths == 0 and Bridge.PathHandler then
		local ok, p = pcall(function() return Bridge.PathHandler.GetActivePath(getTeamIndex()) end)
		if ok and type(p) == "table" and p.Length then
			local pts = {}
			for _, wp in ipairs(p.Waypoints or {}) do table.insert(pts, wp) end
			if #pts >= 2 then table.insert(Paths, makePath(pts)) end
		end
	end

	ActivePathIndex = getTeamIndex()
	ActivePath = Paths[ActivePathIndex]
	if not ActivePath then
		ActivePathIndex = 1
		ActivePath = Paths[1]
	end
	-- единый список точек ВСЕХ путей (карта может иметь 1..4 дорожки)
	AllSamples = {}
	SamplesByPath = {}
	for idx, pth in ipairs(Paths) do
		local perPath = {}
		for _, smp in ipairs(pth.Samples) do
			local e = {pos = smp.pos, w = smp.w, d = smp.d, path = idx, gi = #AllSamples + 1}
			table.insert(AllSamples, e)
			table.insert(perPath, e)
		end
		SamplesByPath[idx] = perPath
	end
	collectRoadParts()
	return #Paths
end

local function distToPath(pos)
	if not ActivePath then return math.huge, 0 end
	local d, dd = ActivePath.GetDistance(pos)
	return dd, d
end

-- ════════════════════════════════════════════════════════════════
-- РОТАЦИЯ ДОРОЖЕК (точно как на сервере, дамп строка 173822-173831):
--   local u862 = split(workspace.AllowedPaths, ";")   -- например "1;2"
--   local idx  = (wave - 1) % #u862 + 1
--   enemy.PathIndex = u862[idx]
-- Значит НА КАЖДОЙ ВОЛНЕ враги идут по предсказуемой дорожке, и юнит,
-- поставленный "под текущую волну", на следующей оказывается в пустоте.
-- Выгодны только точки, бьющие по НЕСКОЛЬКИМ дорожкам сразу
-- (пересечения, центр петли) — их и ищем.
-- ════════════════════════════════════════════════════════════════
local AllowedCache = nil
local function allowedPaths()
	local raw = workspace:GetAttribute("AllowedPaths")
	if AllowedCache and AllowedCache.raw == raw then return AllowedCache.list end
	local list = {}
	if type(raw) == "string" and raw ~= "" then
		for token in string.gmatch(raw, "[^;]+") do
			local n = tonumber(token)
			if n and Paths[n] then table.insert(list, n) end
		end
	end
	if #list == 0 then
		for i = 1, #Paths do table.insert(list, i) end
	end
	if #list == 0 then list = {1} end
	AllowedCache = {raw = raw, list = list}
	return list
end

local function laneForRound(r)
	local list = allowedPaths()
	return list[((math.max(r, 1) - 1) % #list) + 1]
end

local function laneCount()
	return #allowedPaths()
end

-- ближайшая дорожка из всех (на карте может быть 1..4 пути)
local function nearestPath(pos)
	local bestIdx, bestPerp, bestAlong = ActivePathIndex, math.huge, 0
	for idx, pth in ipairs(Paths) do
		local along, perp = pth.GetDistance(pos)
		if perp < bestPerp then
			bestPerp, bestIdx, bestAlong = perp, idx, along
		end
	end
	return bestIdx, bestPerp, bestAlong
end

-- ================================================================
-- 👾 ВРАГИ: живые сущности + HP (из дампа)
--   1) реестр сущностей игры: entity.Data.Health / MaxHealth / Position
--   2) фолбэк: workspace.Map.Entities + бар HPDisplay.Frame.ImageLabel.Health
-- ================================================================
-- ОБЪЯВЛЕНО ЗАРАНЕЕ: эти таблицы используются в scanEnemies(), которая
-- определена выше раздела "кандидаты". Если объявить их там, внутри
-- scanEnemies они будут nil-глобалами → "invalid argument #1 to 'ipairs'".
local MyUnits     = {}  -- [uid] = {uid, id, base, level, pos, info, key, along=, pathIdx=}
local NoCoverage  = {}  -- id юнита → os.clock(), до которого мест с покрытием нет
local DefenseCritical = false  -- dps доски < dps, нужной для ближайших волн
local ChokeSpots  = {}  -- изученные картой лучшие точки (пересечения/центры петель)
local GroundSpots = {}  -- {pos=, key=, road=, along=, cov={}}
local PathSpots   = {}  -- {pos=, key=, along=, pathIndex=}
local BadSpots    = {}  -- key → os.clock() (сервер отказал)
local SpotGrid    = {}

local Enemies = {}       -- последний скан
local EnemyHeat = {}     -- [bucket] = сумма HP врагов в этом участке пути
local HEAT_BUCKET = 10

local function enemyConfig(id)
	local cfg = nil
	if Bridge.ItemData then
		local ok, item = pcall(function() return Bridge.ItemData.GetItem(id) end)
		if ok and type(item) == "table" and item.Params then cfg = item.Params end
	end
	if not cfg then
		local folder = LP.PlayerGui:FindFirstChild("LogicHolder")
		folder = folder and folder:FindFirstChild("ClientLoader")
		folder = folder and folder:FindFirstChild("SharedConfig")
		folder = folder and folder:FindFirstChild("ItemData")
		folder = folder and folder:FindFirstChild("Units")
		folder = folder and folder:FindFirstChild("Configs")
		local m = folder and folder:FindFirstChild(id)
		if m and m:IsA("ModuleScript") then
			local ok, c = pcall(require, m)
			if ok and type(c) == "table" then cfg = c end
		end
	end
	if not cfg then cfg = ENEMY_FALLBACK[id] end
	return cfg or {}
end

local function readHpFromBar(model)
	local hpGui = model:FindFirstChild("HPDisplay", true)
	if not hpGui then return nil, nil end
	local frame = hpGui:FindFirstChild("Frame")
	if not frame then return nil, nil end
	local img = frame:FindFirstChild("ImageLabel")
	local bar = img and img:FindFirstChild("Health")
	local ratio = bar and bar.Size.X.Scale or nil
	local txt = frame:FindFirstChild("TextLabel")
	local cur, maxv = nil, nil
	if txt then
		local a, b = tostring(txt.Text):match("([%d%.]+[KM BTkm bt]?)%s*/%s*([%d%.]+[KM BTkm bt]?)")
		cur = parseAbbrev(a)
		maxv = parseAbbrev(b)
	end
	if cur == nil and ratio and maxv then cur = ratio * maxv end
	return cur, maxv, ratio
end

local function scanEnemies()
	local list = {}

	-- 1) живой реестр игры (самый точный источник)
	if Bridge.UnitsBase then
		local ok, ents = pcall(function() return Bridge.UnitsBase.GetActiveEntities() end)
		if ok and type(ents) == "table" then
			for _, e in ipairs(ents) do
				if e.UnitType == "enemy" and not e.Destroyed then
					local d = e.Data or {}
					local pos = d.Position
					if not pos and e.Instance and e.Instance.PrimaryPart then
						pos = e.Instance.PrimaryPart.Position
					end
					if pos then
						local spd = d.Speed or 5
						if e.GetActualSpeed then
							local ok2, s = pcall(function() return e.GetActualSpeed(e) end)
							if ok2 and type(s) == "number" and s > 0 then spd = s end
						end
						table.insert(list, {
							id      = e.UnitId,
							pos     = pos,
							hp      = tonumber(d.Health) or 0,
							maxHp   = tonumber(d.MaxHealth) or 0,
							speed   = spd,
							along   = tonumber(d.DistanceTravelled),
							isBoss  = (e.Config and e.Config.IsBoss) == true,
							src     = "entity",
						})
					end
				end
			end
		end
	end

	-- 2) фолбэк по моделям
	if #list == 0 then
		local map = workspace:FindFirstChild("Map")
		local ents = map and map:FindFirstChild("Entities")
		if ents then
			for _, m in ipairs(ents:GetChildren()) do
				local nm = tostring(m.Name)
				if nm:sub(1, 6) == "enemy_" and m:IsA("Model") then
					local part = m.PrimaryPart or m:FindFirstChild("Anchor")
						or m:FindFirstChildWhichIsA("BasePart")
					if part then
						local cfg = enemyConfig(nm)
						local uc = cfg.UnitConfig or cfg
						local cur, maxv = readHpFromBar(m)
						maxv = maxv or tonumber(uc.MaxHealth) or 100
						cur = cur or maxv
						table.insert(list, {
							id     = nm,
							pos    = part.Position,
							hp     = cur,
							maxHp  = maxv,
							speed  = tonumber(uc.Speed) or 5,
							isBoss = uc.IsBoss == true,
							src    = "model",
						})
					end
				end
			end
		end
	end

	-- привязываем каждого врага к ЕГО дорожке (на карте может быть 1..4 пути)
	local heat = {}
	local usage = {}
	for _, e in ipairs(list) do
		local bestIdx, bestPerp, bestAlong = ActivePathIndex, math.huge, 0
		for idx, pth in ipairs(Paths) do
			local along, perp = pth.GetDistance(e.pos)
			if perp < bestPerp then
				bestPerp, bestIdx, bestAlong = perp, idx, along
			end
		end
		e.pathIdx = bestIdx
		e.perp    = bestPerp
		e.along   = e.along or bestAlong
		local pth = Paths[bestIdx] or ActivePath
		if pth then
			e.pathLen = pth.Length
			e.leftToBase = math.max(0, pth.Length - e.along)
			e.ttb = e.leftToBase / math.max(e.speed or 5, 0.5)
		end
		local u = usage[bestIdx]
		if not u then
			u = {count = 0, hp = 0, minTtb = math.huge}
			usage[bestIdx] = u
		end
		u.count = u.count + 1
		u.hp = u.hp + (e.hp or 0)
		if (e.ttb or 9999) < u.minTtb then u.minTtb = e.ttb end
		local b = bestIdx .. "_" .. math.floor(e.along / HEAT_BUCKET)
		heat[b] = (heat[b] or 0) + math.max(e.hp or 0, 1)
	end
	EnemyHeat = heat
	PathUsage = usage
	Enemies = list

	-- активный путь = тот, где сейчас больше всего врагов (нужно для ловушек)
	if #Paths > 1 and #list > 0 then
		local bestIdx = ActivePathIndex
		local bestCount = (usage[ActivePathIndex] and usage[ActivePathIndex].count) or 0
		for idx, u in pairs(usage) do
			if u.count > bestCount then
				bestCount, bestIdx = u.count, idx
			end
		end
		if bestIdx ~= ActivePathIndex and bestCount >= 2 then
			ActivePathIndex = bestIdx
			ActivePath = Paths[bestIdx]
			log("🔀 Основная дорожка теперь #" .. bestIdx .. " (врагов: " .. bestCount ..
				", длина " .. string.format("%.0f", ActivePath.Length) .. ")")
		end
	end

	return list
end

-- что придёт на следующих волнах.
-- Источник №1 — живой модуль карты (работает для ЛЮБОЙ карты):
--   ...SharedConfig.ItemData.Maps.maps.<mapId>.Load(stub, function(id, params) ... end)
--   → params.Waves / Waves_dif_normal / Waves_dif_hard / ...
-- Источник №2 — встроенная таблица из дампа (map_farm).
local function normGroup(g)
	if type(g) ~= "table" or type(g[1]) ~= "string" then return nil end
	local hp, sp = 0, 0
	local pr = g[3]
	if type(pr) == "table" then
		hp = tonumber(pr.Health) or tonumber(pr.MaxHealth) or 0
		sp = tonumber(pr.Speed) or 0
	elseif type(pr) == "number" then
		hp = pr
		sp = tonumber(g[4]) or 0
	end
	if hp <= 0 or sp <= 0 then
		local cfg = enemyConfig(g[1])
		local uc = cfg.UnitConfig or cfg
		if hp <= 0 then hp = tonumber(uc.MaxHealth) or 100 end
		if sp <= 0 then sp = tonumber(uc.Speed) or 5 end
	end
	return {g[1], tonumber(g[2]) or 1, hp, sp}
end

local function normWaves(waves)
	if type(waves) ~= "table" then return nil end
	local out = {}
	for wi, wave in ipairs(waves) do
		local groups = {}
		for _, g in ipairs(wave) do
			local ng = normGroup(g)
			if ng then table.insert(groups, ng) end
		end
		out[wi] = groups
	end
	return out
end

local DynWaves = nil
local DynMapId = nil

local function ensureMapWaves()
	local mapId = tostring(workspace:GetAttribute("MapId") or "")
	if mapId == "" then return nil end
	if DynMapId == mapId then return DynWaves end
	DynMapId = mapId
	DynWaves = WAVE_DB[mapId]   -- встроенная таблица (если есть)

	-- пробуем вытащить настоящие волны из модуля карты
	local ok, res = pcall(function()
		local pg = LP:FindFirstChild("PlayerGui")
		local holder = pg and pg:FindFirstChild("LogicHolder")
		local CL = holder and holder:FindFirstChild("ClientLoader")
		local f = CL and CL:FindFirstChild("SharedConfig")
		f = f and f:FindFirstChild("ItemData")
		f = f and f:FindFirstChild("Maps")
		f = f and f:FindFirstChild("maps")
		local mod = f and f:FindFirstChild(mapId)
		if not mod or not mod:IsA("ModuleScript") then return nil end
		local m = require(mod)
		if type(m) ~= "table" or type(m.Load) ~= "function" then return nil end
		local stub = {
			Modules = {
				SharedItemData = Bridge.ItemData or {
					GetItem = function() return {Params = {Image = "", Name = ""}} end,
				},
				SharedHelper = Bridge.Helper or {},
			},
		}
		local captured = nil
		m.Load(stub, function(id, params) captured = params end)
		return captured
	end)

	if ok and type(res) == "table" and (res.Waves or res.Waves_dif_normal) then
		local converted = {}
		converted.dif_easy = normWaves(res.Waves)
		for _, dif in ipairs({"dif_normal", "dif_hard", "dif_insane", "dif_impossible", "dif_endless"}) do
			converted[dif] = normWaves(res["Waves_" .. dif]) or converted.dif_easy
		end
		DynWaves = converted
		local difNow = currentDifficulty()
		local tbl = converted[difNow] or converted.dif_normal or converted.dif_easy or {}
		local n = 0
		for _ in ipairs(tbl) do n = n + 1 end
		log("✓ Волны карты " .. mapId .. " загружены из модуля игры (" .. n .. " волн на " .. difNow .. ")")
	elseif DynWaves then
		log("✓ Волны карты " .. mapId .. " — из встроенной таблицы дампа")
	else
		log("⚠️ Волн для карты " .. mapId .. " нет — нужная DPS считается по живым врагам")
	end
	return DynWaves
end

local function waveInfo(round, dif)
	local byMap = ensureMapWaves()
	if not byMap then return nil end
	local waves = byMap[dif] or byMap[currentDifficulty()] or byMap.dif_normal or byMap.dif_easy
	if not waves then return nil end
	return waves[round]
end

local BossCache = {}
local function isBossEnemy(id)
	if BossCache[id] ~= nil then return BossCache[id] end
	local v = false
	local fb = ENEMY_FALLBACK[id]
	if fb and fb.IsBoss then v = true end
	if not v then
		local cfg = enemyConfig(id)
		local uc = cfg.UnitConfig or cfg
		if uc and uc.IsBoss == true then v = true end
	end
	BossCache[id] = v
	return v
end

local function upcomingThreat(round, dif, lookahead)
	lookahead = lookahead or 3
	local hp, cnt, spd, boss = 0, 0, 0, false
	for w = round, round + lookahead do
		local wave = waveInfo(w, dif)
		if wave then
			for _, g in ipairs(wave) do
				local n = g[2] or 1
				hp = hp + (g[3] or 0) * n
				cnt = cnt + n
				local sp = g[4]
				if not sp or sp <= 0 then
					local fb = ENEMY_FALLBACK[g[1]]
					sp = (fb and fb.Speed) or 5
				end
				spd = math.max(spd, sp)
				if isBossEnemy(g[1]) then boss = true end
			end
		end
	end
	if spd <= 0 then spd = 5 end
	return {hp = hp, count = cnt, speed = spd, boss = boss}
end

-- ================================================================
-- 🎒 ИНВЕНТАРЬ + КОНФИГИ ЮНИТОВ (с разрешением BaseUnit!)
-- ================================================================
local ConfigCache = {}

local function rawConfig(id)
	if ConfigCache[id] ~= nil then return ConfigCache[id] end
	local cfg = nil
	if Bridge.ItemData then
		local ok, item = pcall(function() return Bridge.ItemData.GetItem(id) end)
		if ok and type(item) == "table" and item.Params then cfg = item.Params end
	end
	if not cfg then
		local f = LP.PlayerGui:FindFirstChild("LogicHolder")
		f = f and f:FindFirstChild("ClientLoader")
		f = f and f:FindFirstChild("SharedConfig")
		f = f and f:FindFirstChild("ItemData")
		f = f and f:FindFirstChild("Units")
		f = f and f:FindFirstChild("Configs")
		local m = f and f:FindFirstChild(id)
		if m and m:IsA("ModuleScript") then
			local ok, c = pcall(require, m)
			if ok and type(c) == "table" then cfg = c end
		end
	end
	if not cfg then cfg = UNIT_FALLBACK[id] end
	ConfigCache[id] = cfg or false
	return ConfigCache[id]
end

-- полный конфиг с учётом BaseUnit (скины вроде bronze_lawnmower)
local function resolveUnit(id)
	local cfg = rawConfig(id)
	if type(cfg) ~= "table" then cfg = {} end
	local uc = cfg.UnitConfig or {}
	local baseId = cfg.BaseUnit
	local unitType = cfg.UnitType
	local name = cfg.Name
	local placeable = cfg.Placeable
	local internal = cfg.Internal

	-- скин наследует всё от базового юнита (например bronze_lawnmower → lawnmower)
	if baseId and baseId ~= id then
		local base = rawConfig(baseId)
		if type(base) == "table" then
			local buc = base.UnitConfig or base
			local merged = {}
			for k, v in pairs(buc) do merged[k] = v end
			for k, v in pairs(uc) do merged[k] = v end
			uc = merged
			unitType  = unitType or base.UnitType
			name      = name or base.Name
			if placeable == nil then placeable = base.Placeable end
		end
	end

	-- последний фолбэк — данные из дампа
	if not next(uc) and UNIT_FALLBACK[id] then
		local fb = UNIT_FALLBACK[id]
		if fb.BaseUnit and fb.BaseUnit ~= id and UNIT_FALLBACK[fb.BaseUnit] then
			fb = UNIT_FALLBACK[fb.BaseUnit]
		end
		uc = fb
		unitType = unitType or fb.UnitType
		name = name or fb.Name
	end
	if not next(uc) and baseId and UNIT_FALLBACK[baseId] then
		uc = UNIT_FALLBACK[baseId]
		unitType = unitType or uc.UnitType
	end

	unitType = unitType or "unit_ranged"
	local isPath = (unitType == "unit_trap") or (uc.PlaceOnPath == true)

	local dmg = tonumber(uc.Damage) or 0
	local apm = tonumber(uc.APM) or 0
	local dps = dmg * apm / 60
	local incAmount = tonumber(uc.Income) or 0
	local incInterval = tonumber(uc.Interval) or 0
	local income = (incAmount > 0 and incInterval > 0) and (incAmount / incInterval) or 0

	return {
		id        = id,
		base      = baseId or id,
		name      = name or id,
		unitType  = unitType,
		isPath    = isPath,
		cost      = tonumber(uc.Cost) or 0,
		maxPlaced = tonumber(uc.MaxPlaced) or math.huge,
		range     = tonumber(uc.Range) or tonumber(uc.PatrolRange) or 0,
		damage    = dmg,
		apm       = apm,
		dps       = dps,
		income    = income,
		incAmount = incAmount,
		incInterval = incInterval,
		cooldown  = tonumber(uc.PlacementCooldown) or 0,
		spacing   = tonumber(uc.MinPlacementSpacing) or 0,
		dmgDist   = tonumber(uc.DamageDistance) or 0,
		trapSpeed = tonumber(uc.Speed) or 0,
		uses      = tonumber(uc.Uses) or 0,
		moves     = uc.MovesAround == true,
		upgrades  = uc.Upgrades or {},
		placeable = placeable ~= false,
		internal  = internal == true,
	}
end

-- характеристики юнита на уровне lvl (учитывает Changes из апгрейдов)
local function unitAtLevel(info, lvl)
	lvl = math.max(1, lvl or 1)
	local dmg, apm, range = info.damage, info.apm, info.range
	local incA, incI = info.incAmount or 0, info.incInterval or 0

	for i = 1, lvl - 1 do
		local up = info.upgrades[i]
		if up then
			local ch = up.Changes or up
			if tonumber(ch.Damage) then dmg = ch.Damage end
			if tonumber(ch.APM) then apm = ch.APM end
			if tonumber(ch.Range) then range = ch.Range end
			if tonumber(ch.Income) then incA = ch.Income end
			if tonumber(ch.Interval) then incI = ch.Interval end
		end
	end
	return {
		dps    = dmg * apm / 60,
		range  = range or 0,
		income = (incA > 0 and incI > 0) and (incA / incI) or 0,
		damage = dmg,
	}
end

local function upgradeCost(info, lvl)
	local up = info.upgrades[lvl]
	if not up then return nil end
	return tonumber(up.Cost)
end

local Owned = {}   -- доступные к размещению юниты из Backpack

local function discoverOwned()
	Owned = {}
	local seen = {}

	local function scan(container)
		if not container then return end
		for _, tool in ipairs(container:GetChildren()) do
			if tool:IsA("Tool") then
				local handle = tool:FindFirstChild("Handle")
				local id = (handle and handle:GetAttribute("UnitId")) or tool:GetAttribute("UnitId")
				if not id then
					local item = tool:GetAttribute("ItemID")
					if item then id = tostring(item):match("unitplacer_(.+)$") end
				end
				if id and not seen[id] then
					local info = resolveUnit(id)
					if info.placeable and not info.internal and info.unitType ~= "enemy" then
						local toolCost = tonumber(tool:GetAttribute("UnitPlacementCost"))
						info.cost = toolCost or info.cost
						info.tool = tool
						info.toolName = tool.Name
						seen[id] = true
						table.insert(Owned, info)
					end
				end
			end
		end
	end

	pcall(function() scan(LP:FindFirstChild("Backpack")) end)
	pcall(function() scan(LP.Character) end)
	table.sort(Owned, function(a, b) return a.cost < b.cost end)
	return #Owned
end

local function unitSize(id)
	local m = RS:FindFirstChild("Models")
	m = m and m:FindFirstChild("Units")
	m = m and m:FindFirstChild(id)
	if m then
		local pp = m.PrimaryPart or m:FindFirstChild("Anchor")
		if pp and pp:IsA("BasePart") then return pp.Size end
	end
	return Vector3.new(3, 3, 3)
end

-- ================================================================
-- 🧭 КАНДИДАТЫ: земля (только Map.Placeable!) + точки на пути
-- ================================================================

local function keyOf(pos) return string.format("%.1f_%.1f", pos.X, pos.Z) end

local function collectPlaceableParts()
	local set, parts = {}, {}
	local map = workspace:FindFirstChild("Map")
	local pm = map and map:FindFirstChild("Placeable")

	local function addPart(p)
		if p:IsA("BasePart") and not set[p] and p.Size.X >= 1 and p.Size.Z >= 1 then
			set[p] = true
			table.insert(parts, p)
		end
	end

	if pm then
		for _, d in ipairs(pm:GetDescendants()) do addPart(d) end
	end
	if Bridge.Helper and Bridge.Helper.GetPlaceableModels then
		local ok, models = pcall(function() return Bridge.Helper.GetPlaceableModels() end)
		if ok and type(models) == "table" then
			for _, m in ipairs(models) do
				if m and m:IsA("BasePart") then
					addPart(m)
				elseif m then
					local ok2, desc = pcall(function() return m:GetDescendants() end)
					if ok2 and desc then
						for _, d in ipairs(desc) do addPart(d) end
					end
				end
			end
		end
	end
	return parts
end

-- сколько студов пути (по ВСЕМ дорожкам карты) попадает в радиус
local function coverageAt(pos, range)
	if #AllSamples == 0 or range <= 0 then return 0 end
	local covered = 0
	local r2 = range * range
	for i = 1, #AllSamples do
		local s = AllSamples[i]
		local dx, dz = s.pos.X - pos.X, s.pos.Z - pos.Z
		if dx * dx + dz * dz <= r2 then covered = covered + s.w end
	end
	return covered
end

-- маржинальное покрытие ОТДЕЛЬНО по каждой дорожке + число линий.
-- Возвращает: таблица {lane -> покрыто студов}, общее покрытие, runs по текущей линии
local function marginalPerLane(pos, range)
	local per, total, runs, prev = {}, 0, 0, false
	if #AllSamples == 0 or range <= 0 then return per, 0, 0 end
	local r2 = range * range
	for i = 1, #AllSamples do
		local inside = false
		if not SampleCover[i] then
			local s = AllSamples[i]
			local dx, dz = s.pos.X - pos.X, s.pos.Z - pos.Z
			if dx * dx + dz * dz <= r2 then
				inside = true
				per[s.path] = (per[s.path] or 0) + s.w
				total = total + s.w
			end
		end
		if inside and not prev then runs = runs + 1 end
		prev = inside
	end
	return per, total, runs
end

local function marginalCoverage(pos, range)
	if #AllSamples == 0 or range <= 0 then return 0, 0 end
	local covered, runs, prev = 0, 0, false
	local r2 = range * range
	for i = 1, #AllSamples do
		local inside = false
		if not SampleCover[i] then
			local s = AllSamples[i]
			local dx, dz = s.pos.X - pos.X, s.pos.Z - pos.Z
			if dx * dx + dz * dz <= r2 then
				covered = covered + s.w
				inside = true
			end
		end
		if inside and not prev then runs = runs + 1 end
		prev = inside
	end
	return covered, runs
end

-- пересчитать, какие куски пути уже покрыты стоящими юнитами
local function rebuildSampleCover()
	SampleCover = {}
	for _, u in pairs(MyUnits) do
		local info = u.info or resolveUnit(u.id)
		local st = unitAtLevel(info, u.level)
		if info.isPath then
			-- ловушка бьёт по полосе пути ±(DamageDistance+2) вокруг своей точки
			local band = math.max(info.dmgDist or 0, 2) + 2
			local pidx = u.pathIdx or ActivePathIndex
			local along = u.along or 0
			local list = SamplesByPath[pidx] or {}
			if info.trapSpeed and info.trapSpeed > 0 then
				-- косилка прочёсывает всю дорожку от точки постановки до спавна
				for _, smp in ipairs(list) do
					if smp.d <= along then SampleCover[smp.gi] = true end
				end
			else
				for _, smp in ipairs(list) do
					if math.abs(smp.d - along) <= band then SampleCover[smp.gi] = true end
				end
			end
		elseif st.range > 0 and u.pos then
			local r2 = st.range * st.range
			for i = 1, #AllSamples do
				if not SampleCover[i] then
					local smp = AllSamples[i]
					local dx, dz = smp.pos.X - u.pos.X, smp.pos.Z - u.pos.Z
					if dx * dx + dz * dz <= r2 then SampleCover[i] = true end
				end
			end
		end
	end
end

-- сколько всего студов пути на всех дорожках
local function totalPathLength()
	local sum = 0
	for _, pth in ipairs(Paths) do sum = sum + pth.Length end
	return sum
end

local function buildSpots()
	GroundSpots, PathSpots, SpotGrid = {}, {}, {}
	NoCoverage = {}
	if #Paths == 0 then return end

	-- --- ЗЕМЛЯ: семплируем верх Placeable-частей ---
	local parts = collectPlaceableParts()
	local step = CFG.sampleStep

	-- подбираем шаг так, чтобы точки достались ВСЕМ частям, а не первым попавшимся
	local function gridOf(sz, st) return clamp(math.floor(sz / st), 1, 6) end
	local total = 0
	for _, part in ipairs(parts) do
		total = total + (gridOf(part.Size.X, step) + 1) * (gridOf(part.Size.Z, step) + 1)
	end
	if total > CFG.maxCandidates then
		step = step * math.sqrt(total / CFG.maxCandidates)
	end

	for _, part in ipairs(parts) do
		if #GroundSpots >= CFG.maxCandidates then break end
		local cf, size = part.CFrame, part.Size
		local top = size.Y / 2 + 0.06
		local nx = gridOf(size.X, step)
		local nz = gridOf(size.Z, step)
		for ix = 0, nx do
			for iz = 0, nz do
				if #GroundSpots >= CFG.maxCandidates then break end
				local ox = -size.X / 2 + size.X * ix / nx
				local oz = -size.Z / 2 + size.Z * iz / nz
				local pos = cf:PointToWorldSpace(Vector3.new(ox, top, oz))
				local k = keyOf(pos)
				if not SpotGrid[k] then
					local rd = roadDist(pos)
					if rd >= 1.4 then
						-- ближайшая дорожка (их на карте может быть 1..4)
						local pidx, perp, along = nearestPath(pos)
						if perp <= CFG.maxSpotPathDist then
							SpotGrid[k] = true
							table.insert(GroundSpots, {
								pos = pos, key = k, road = rd,
								pathIdx = pidx, pdist = perp, along = along,
								cov = {},
							})
						end
					end
				end
			end
		end
	end

	-- --- ЗЕМЛЯ №2: Terrain рейкастом ---
	-- Placeable-части есть не везде: центр квадратной петли / пересечения часто
	-- лежат на голом Terrain, а ставить туда МОЖНО (в боксе юнита нет частей).
	-- Без этих точек AI физически не мог встать в центр петли.
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, smp in ipairs(AllSamples) do
		if smp.pos.X < minX then minX = smp.pos.X end
		if smp.pos.X > maxX then maxX = smp.pos.X end
		if smp.pos.Z < minZ then minZ = smp.pos.Z end
		if smp.pos.Z > maxZ then maxZ = smp.pos.Z end
	end
	minX, maxX = minX - 30, maxX + 30
	minZ, maxZ = minZ - 30, maxZ + 30

	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local filt = {}
	if LP.Character then table.insert(filt, LP.Character) end
	local map0 = workspace:FindFirstChild("Map")
	local eh = workspace:FindFirstChild("EffectHolder")
	if eh then table.insert(filt, eh) end
	local ents0 = map0 and map0:FindFirstChild("Entities")
	if ents0 then table.insert(filt, ents0) end  -- юниты/враги не должны мешать лучу
	rp.FilterDescendantsInstances = filt
	rp.IgnoreWater = true

	-- адаптивный шаг: точки должны достаться ВСЕЙ карте, а не первому краю
	local tstep = CFG.terrainStep
	local area = math.max(1, (maxX - minX) * (maxZ - minZ))
	local est = area / (tstep * tstep)
	if est > CFG.maxTerrainSpots then
		tstep = math.sqrt(area / CFG.maxTerrainSpots)
	end
	local added = 0
	local x = minX
	while x <= maxX and added < CFG.maxTerrainSpots do
		local z = minZ
		while z <= maxZ and added < CFG.maxTerrainSpots do
			local hit = workspace:Raycast(Vector3.new(x, 200, z), Vector3.new(0, -400, 0), rp)
			if hit and hit.Instance and hit.Instance:IsA("Terrain") and hit.Normal.Y > 0.65 then
				local pos = hit.Position + Vector3.new(0, 0.06, 0)
				local k = keyOf(pos)
				if not SpotGrid[k] then
					local rd = roadDist(pos)
					if rd >= 1.6 then
						local pidx, perp, along = nearestPath(pos)
						if perp <= CFG.maxSpotPathDist then
							SpotGrid[k] = true
							table.insert(GroundSpots, {
								pos = pos, key = k, road = rd,
								pathIdx = pidx, pdist = perp, along = along,
								cov = {}, terrain = true,
							})
							added = added + 1
						end
					end
				end
			end
			z = z + tstep
		end
		x = x + tstep
	end
	if added > 0 then
		log(string.format("  + точек на Terrain: %.0f (центр петель / пересечения)", added))
	end

	-- ════════════════════════════════════════════════════════════
	-- 🗺 ИЗУЧЕНИЕ КАРТЫ: ищем choke-точки — места, откуда один юнит
	-- простреливает максимум линий пути сразу (пересечения дорожек,
	-- центр петель). Считаем один раз при постройке точек.
	-- ════════════════════════════════════════════════════════════
	ChokeSpots = {}
	local REF = 20   -- эталонный радиус для оценки choke-точек
	local scored = {}
	for _, sp in ipairs(GroundSpots) do
		local per, total, runs = marginalPerLane(sp.pos, REF)
		local v = total + math.max(0, runs - 1) * 25
		if total > 0 then
			table.insert(scored, {sp = sp, v = v, total = total, runs = runs})
		end
	end
	table.sort(scored, function(a, b) return a.v > b.v end)
	for _, c in ipairs(scored) do
		if #ChokeSpots >= 6 then break end
		local far = true
		for _, ex in ipairs(ChokeSpots) do
			if flat(ex.sp.pos, c.sp.pos) < 18 then far = false break end
		end
		if far and c.runs >= 2 then
			table.insert(ChokeSpots, c)
		end
	end
	if #ChokeSpots > 0 then
		log("🗺 ИЗУЧЕНИЕ КАРТЫ: найдены choke-точки (бьют по нескольким линиям сразу):")
		for i, c in ipairs(ChokeSpots) do
			log(string.format("    %d) (%.0f, %.0f) — %.0f студов пути, линий: %.0f%s",
				i, c.sp.pos.X, c.sp.pos.Z, c.total, c.runs,
				c.sp.terrain and " (terrain)" or ""))
		end
	else
		log("🗺 ИЗУЧЕНИЕ КАРТЫ: явных пересечений нет — ставим вдоль дорожек")
	end

	-- точек может стать очень много: оставляем ближайшие к дорожкам,
	-- далеко от пути юнит всё равно ничего не прострелит
	if #GroundSpots > CFG.maxGroundSpots then
		table.sort(GroundSpots, function(a, b) return (a.pdist or 999) < (b.pdist or 999) end)
		for i = #GroundSpots, CFG.maxGroundSpots + 1, -1 do
			SpotGrid[GroundSpots[i].key] = nil
			GroundSpots[i] = nil
		end
	end

	-- --- ТОЧКИ НА КАЖДОЙ ДОРОЖКЕ (для ловушек) ---
	for idx, pth in ipairs(Paths) do
		local L = pth.Length
		local n = math.max(4, math.floor(L / 5))
		for i = 1, n do
			local d = L * i / n
			local pos = pth.GetPosition(d)
			table.insert(PathSpots, {
				pos = pos, key = "P" .. idx .. "_" .. keyOf(pos),
				along = d, pathIndex = idx, rel = i / n, len = L,
			})
		end
	end

	log(string.format("Точек: земля=%.0f (из %.0f Placeable-частей, шаг %.1f) | на дорожках=%.0f (%.0f шт.) | суммарная длина %.0f",
		#GroundSpots, #parts, step, #PathSpots, #Paths, totalPathLength()))
end


-- ================================================================
-- 📐 БАЗОВЫЕ ОЦЕНКИ (используются и выбором места, и стратегией)
-- ================================================================
local COV_NORM = 40   -- "хорошее" покрытие пути в студах (нормировка)

local function remainingSeconds(round)
	local wavesLeft = math.max(1, getMaxRound() - round)
	return clamp(wavesLeft * 28, 45, 1400)
end

-- тип ловушки:
--   charger  — едет по пути и сгорает (Lawnmower: Speed>0)
--   repeater — стоит и бьёт постоянно (Rafflesia: APM>0)
local function trapKind(info, st)
	st = st or unitAtLevel(info, 1)
	if info.trapSpeed > 0 then return "charger", st end
	if st.dps > 0 then return "repeater", st end
	return "static", st
end

-- оценка покрытия ОДНОЙ дорожки (в среднем за волну): при ротации юнит
-- работает только на своей линии, поэтому K делим на число дорожек
local function covFactorByRange(range)
	local laneLen = totalPathLength() / math.max(laneCount(), 1)
	local cov = math.min(2 * (range or 0), laneLen)
	return clamp(cov / COV_NORM, 0.05, 1.6)
end

local function covFactorByPos(pos, range)
	if not pos or #AllSamples == 0 or (range or 0) <= 0 then return 0.4 end
	-- покрытие на дорожке ТЕКУЩЕЙ волны (остальные линии учтёт ротация)
	local lane = laneForRound(getRound())
	local cov = 0
	local r2 = range * range
	for i = 1, #AllSamples do
		local smp = AllSamples[i]
		if smp.path == lane then
			local dx, dz = smp.pos.X - pos.X, smp.pos.Z - pos.Z
			if dx * dx + dz * dz <= r2 then cov = cov + smp.w end
		end
	end
	local laneLen = (Paths[lane] and Paths[lane].Length) or COV_NORM
	return clamp(cov / COV_NORM, 0.05, 1.6) * clamp(laneLen / laneLen, 1, 1)
end

-- покрытие пути для точки (кэш): возвращает covered, runs
local function spotCoverage(spot, range)
	local rk = tostring(math.floor(range))
	local e = spot.cov[rk]
	if e == nil then
		local covered, runs, prev = 0, 0, false
		local r2 = range * range
		for i = 1, #AllSamples do
			local s = AllSamples[i]
			local dx, dz = s.pos.X - spot.pos.X, s.pos.Z - spot.pos.Z
			local inside = dx * dx + dz * dz <= r2
			if inside then
				covered = covered + s.w
				if not prev then runs = runs + 1 end
			end
			prev = inside
		end
		e = {c = covered, r = runs}
		spot.cov[rk] = e
	end
	return e.c, e.r
end

-- ================================================================
-- 🧠 МОЗГ (обучение на реальных исходах)
-- ================================================================
local Brain = {
	grid = {}, units = {}, traps = {},
	games = 0, wins = 0, best = 0,
	wavesPlayed = 0, wavesClean = 0, leaked = 0,
}

local function saveBrain()
	Brain.difficulty = CFG.difficulty
	if type(isfolder) ~= "function" or type(writefile) ~= "function" then return end
	pcall(function()
		if not isfolder(CFG.folder) then makefolder(CFG.folder) end
	end)
	local ok, json = pcall(function() return HttpService:JSONEncode(Brain) end)
	if ok then pcall(writefile, CFG.brain, json) end
end

local function loadBrain()
	if type(isfile) ~= "function" or type(readfile) ~= "function" then return end
	if not isfile(CFG.brain) then return end
	local ok, d = pcall(function() return HttpService:JSONDecode(readfile(CFG.brain)) end)
	if ok and type(d) == "table" then
		Brain.grid  = d.grid or {}
		Brain.units = d.units or {}
		Brain.traps = d.traps or {}
		Brain.games = d.games or 0
		Brain.wins  = d.wins or 0
		Brain.best  = d.best or 0
		Brain.wavesPlayed = d.wavesPlayed or 0
		Brain.wavesClean  = d.wavesClean or 0
		Brain.leaked      = d.leaked or 0
		if CFG.rememberDifficulty and MY_DIFFICULTY == ""
			and type(d.difficulty) == "string" and d.difficulty ~= "" then
			CFG.difficulty = d.difficulty
			log("📌 Сложность из brain.json (авто):", CFG.difficulty)
		end
	end
end

local function gridScore(key)
	local g = Brain.grid[key]
	return g and g.score or 0
end

-- мягкое обучение после каждой волны (не ждём конца игры)
local function learnStep(reward, placements)
	local lr = CFG.learnRate * 0.35
	for _, p in ipairs(placements) do
		if p.key then
			local g = Brain.grid[p.key] or {score = 0, visits = 0}
			g.visits = g.visits + 1
			g.score = g.score * (1 - lr) + reward * lr
			Brain.grid[p.key] = g
		end
		local u = Brain.units[p.id] or {score = 0.5, games = 0, placed = 0}
		u.placed = (u.placed or 0)
		u.score = u.score * (1 - lr) + reward * lr
		Brain.units[p.id] = u
	end
end

local function learn(round, won, placements)
	Brain.games = Brain.games + 1
	if won then Brain.wins = Brain.wins + 1 end
	if round > Brain.best then Brain.best = round end
	local reward = won and 1.0 or clamp(round / 25, 0, 0.85)
	local lr = CFG.learnRate
	for _, p in ipairs(placements) do
		if p.key then
			local g = Brain.grid[p.key] or {score = 0, visits = 0}
			g.visits = g.visits + 1
			g.score = g.score * (1 - lr) + reward * lr
			Brain.grid[p.key] = g
		end
		local u = Brain.units[p.id] or {score = 0.5, games = 0, placed = 0}
		u.games = u.games + 1
		u.placed = (u.placed or 0) + 1
		u.score = u.score * (1 - lr) + reward * lr
		Brain.units[p.id] = u
	end
	for _, g in pairs(Brain.grid) do g.score = g.score * 0.97 end
	saveBrain()
end

-- ================================================================
-- 📦 МОИ ЮНИТЫ (точный учёт по entityId, который возвращает сервер)
-- ================================================================
-- (таблица MyUnits объявлена вверху: rebuildSampleCover использует её раньше)

-- регистрация исчезнувших юнитов: ловушка сработала или пропала зря?
local function noteDisappeared(removed)
	for _, u in ipairs(removed) do
		local info = u.info
		if info and info.isPath then
			local t = Brain.traps[info.base]
			if not t then
				t = {bought = 0, used = 0, wasted = 0}
				Brain.traps[info.base] = t
			end
			if #Enemies > 0 then
				t.used = t.used + 1
			else
				t.wasted = t.wasted + 1
			end
		end
	end
end

local function syncMyUnits()
	-- вариант 1: живой реестр игры
	if Bridge.UnitsBase and Bridge.UnitsBase.GetEntitiesOwnedBy then
		local ok, list = pcall(function() return Bridge.UnitsBase.GetEntitiesOwnedBy(LP) end)
		if ok and type(list) == "table" and #list > 0 then
			local fresh = {}
			for _, e in ipairs(list) do
				local d = e.Data or {}
				local uid = tostring(e.ID)
				local old = MyUnits[uid]
				fresh[uid] = {
					uid   = e.ID,
					placedAt = (old and old.placedAt) or 0,
					id    = e.UnitId,
					base  = e.BaseUnit or e.UnitId,
					level = tonumber(d.Level) or (old and old.level) or 1,
					pos   = d.Position or (old and old.pos),
					key   = (old and old.key) or (d.Position and keyOf(d.Position)),
					info  = (old and old.info) or resolveUnit(e.UnitId),
					along = tonumber(d.DistanceAlongPath) or (old and old.along),
					pathIdx = tonumber(d.PathIndex) or (old and old.pathIdx),
				}
			end
			local removed = {}
			for uid, u in pairs(MyUnits) do
				if not fresh[uid] then table.insert(removed, u) end
			end
			if #removed > 0 then noteDisappeared(removed) end
			MyUnits = fresh
			return true
		end
		if ok and type(list) == "table" and #list == 0 then
			-- реестр пуст: либо юнитов правда нет, либо мост не тот — проверяем модели
			local tracked = 0
			for _ in pairs(MyUnits) do tracked = tracked + 1 end
			if tracked > 0 then
				local map = workspace:FindFirstChild("Map")
				local ents = map and map:FindFirstChild("Entities")
				local found = 0
				if ents then
					for _, m in ipairs(ents:GetChildren()) do
						local aid = m:GetAttribute("ID")
						if aid and MyUnits[tostring(aid)] then found = found + 1 end
					end
				end
				if found > 0 then
					log("⚠️ Реестр сущностей игры недоступен — перехожу на скан Map.Entities")
					Bridge.UnitsBase = nil
				end
			end
		end
	end

	-- вариант 2: чистим тех, чьих моделей больше нет в Map.Entities
	local alive = {}
	local map = workspace:FindFirstChild("Map")
	local ents = map and map:FindFirstChild("Entities")
	if ents then
		for _, m in ipairs(ents:GetChildren()) do
			local idattr = m:GetAttribute("ID")
			if idattr then alive[tostring(idattr)] = m end
		end
	end
	local now = os.clock()
	local removed = {}
	for uid, u in pairs(MyUnits) do
		if not alive[uid] then
			-- модель могла ещё не доехать по сети → даём 5 секунд форы,
			-- иначе мы "теряли" только что купленный юнит и покупали его заново
			if not (u.placedAt and now - u.placedAt < 5) then
				MyUnits[uid] = nil
				table.insert(removed, u)
			end
		end
	end
	if #removed > 0 then noteDisappeared(removed) end
	for uid, m in pairs(alive) do
		if not MyUnits[uid] then
			local nm = tostring(m.Name)
			if nm:sub(1, 5) == "unit_" then
				local part = m.PrimaryPart or m:FindFirstChild("Anchor")
				MyUnits[uid] = {
					uid = tonumber(uid) or uid, id = nm, base = nm, level = 1,
					pos = part and part.Position, key = part and keyOf(part.Position),
					info = resolveUnit(nm), placedAt = os.clock(),
				}
			end
		end
	end
	return false
end

local function countByBase(baseId)
	local n = 0
	for _, u in pairs(MyUnits) do
		if u.base == baseId then n = n + 1 end
	end
	return n
end

local function myPositions()
	local t = {}
	for _, u in pairs(MyUnits) do
		if u.pos then table.insert(t, u.pos) end
	end
	return t
end

-- эффективная DPS ПРОТИВ ТЕКУЩЕЙ ВОЛНЫ: при ротации дорожек юнит,
-- стоящий только на линии 1, на волне линии 2 просто простаивает
local function boardStats()
	local dps, income, covSum, traps = 0, 0, 0, 0
	local lane = laneForRound(getRound())
	local laneLen = (Paths[lane] and Paths[lane].Length) or 1
	for _, u in pairs(MyUnits) do
		local info = u.info or resolveUnit(u.id)
		local st = unitAtLevel(info, u.level)
		if info.isPath then
			if (u.pathIdx or lane) == lane then
				traps = traps + 1
				local tdps = st.dps
				if tdps <= 0 then tdps = (st.damage or 0) / 10 end
				dps = dps + tdps * 0.6
			end
		else
			local cov = 0
			if u.pos and st.range > 0 then
				local r2 = st.range * st.range
				for i = 1, #AllSamples do
					local smp = AllSamples[i]
					if smp.path == lane then
						local dx, dz = smp.pos.X - u.pos.X, smp.pos.Z - u.pos.Z
						if dx * dx + dz * dz <= r2 then cov = cov + smp.w end
					end
				end
			end
			local frac = clamp(cov / laneLen, 0, 1)
			covSum = covSum + frac
			dps = dps + st.dps * math.max(frac, 0.15)
		end
		income = income + st.income
	end
	return {dps = dps, income = income, coverage = covSum, traps = traps}
end

-- ================================================================
-- 🚦 ПРОВЕРКИ ПЕРЕД РАЗМЕЩЕНИЕМ
-- ================================================================
local function cooldownLeft(info)
	local pc = LP:FindFirstChild("PlacementCooldowns")
	if not pc then return 0, nil end
	local name = info.base .. "/" .. getTeamIndex()
	local v = pc:FindFirstChild(name)
	if v and v:IsA("NumberValue") and v.Value > 0 then return v.Value, "placement" end
	local r = pc:FindFirstChild("Resell/" .. info.base)
	if r and r:IsA("NumberValue") and r.Value > 0 then return r.Value, "resell" end
	return 0, nil
end

local function charPos()
	local ch = LP.Character
	local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
	return hrp and hrp.Position
end

-- полная валидация точки так, как это делает сервер
local function validateGround(pos, info)
	local cp = charPos()
	if cp and (pos - cp).Magnitude > CFG.charRangeLimit then
		return false, "distance"
	end
	local size = unitSize(info.id)
	local rd = roadDist(pos)
	local half = math.max(size.X, size.Z) / 2
	if rd < half + 0.3 then return false, "on_road" end

	for _, p in ipairs(myPositions()) do
		if flat(p, pos) < math.max(CFG.minGap, 1.1) then return false, "overlap" end
	end

	if Bridge.Placement and Bridge.Placement.IsPlacementValid then
		size = size + Vector3.new(0.2, 0.2, 0.2)
		local ok, valid, why = pcall(function()
			return Bridge.Placement.IsPlacementValid(
				CFrame.new(pos), size, nil, cp, 100, getTeamIndex())
		end)
		if ok and valid == false then return false, tostring(why or "invalid") end
	end
	return true
end

local function validatePathSpot(spot, info)
	if not ActivePath then return false, "no_path" end
	for _, p in ipairs(myPositions()) do
		if flat(p, spot.pos) < 1.2 then return false, "overlap" end
	end
	return true
end

-- ================================================================
-- 📦 РАЗМЕЩЕНИЕ (точные аргументы как у клиента игры)
-- ================================================================
local function classifyReject(msg)
	if msg == nil then return "noanswer" end
	local m = tostring(msg):lower()
	if m:find("can't place there") or m:find("collision") then return "badspot" end
	if m:find("cash") or m:find("enough") then return "nocash" end
	if m:find("too many units") then return "slots" end
	if m:find("max ") and m:find("units") then return "unitmax" end
	if m:find("every") or m:find("again in") or m:find("seconds") then return "cooldown" end
	if m:find("right now") or m:find("paused") then return "notnow" end
	if m:find("banned") or m:find("can not be") or m:find("cannot") then return "permanent" end
	if m:find("distance") then return "distance" end
	if m:find("triangles") or m:find("studs away") then return "spacing" end
	return "other"
end

local PlacementLog = {}
local SessionPlacements = {}
local walkCloser

local invokeErrLogged = false
local function invokePlace(info, args)
	if not Remotes.PlaceUnit then return nil, "нет RemoteFunction PlaceUnit" end
	local ok, a, b = pcall(function()
		return Remotes.PlaceUnit:InvokeServer(info.id, args)
	end)
	if not ok then
		if not invokeErrLogged then
			invokeErrLogged = true
			log("⚠️ InvokeServer(PlaceUnit) бросил ошибку (больше не повторяю):", tostring(a))
		end
		return nil, tostring(a)
	end
	if a == nil and not invokeErrLogged then
		invokeErrLogged = true
		log("⚠️ Сервер вернул nil на PlaceUnit — нет тула / юнит internal / бан. Ответ:", tostring(b))
	end
	return a, b
end

-- попытка поставить юнит в конкретную точку
local function tryPlace(info, spot, attempt)
	local isPath = info.isPath
	local args
	if isPath then
		local d = spot.along or 0
		local cf = CFrame.new(spot.pos)
		if ActivePath then
			local a = ActivePath.GetPosition(d)
			local b = ActivePath.GetPosition(d - 0.001)
			cf = CFrame.new(a, b)
		end
		args = {
			Valid = true,
			Position = spot.pos,
			CF = cf,
			Rotation = 0,
			PathIndex = spot.pathIndex or ActivePathIndex,
			DistanceAlongPath = d,
			Attempt = attempt or 1,
			WasFastPlaced = false,
		}
	else
		local rot = math.random(0, 3) * 90
		args = {
			Valid = true,
			Position = spot.pos,
			CF = CFrame.new(spot.pos) * CFrame.Angles(0, math.rad(rot), 0),
			Rotation = rot,
			Attempt = attempt or 1,
			WasFastPlaced = false,
		}
	end

	local res, second = invokePlace(info, args)

	if res == true then
		local uid = second
		local u = {
			uid = uid, id = info.id, base = info.base, level = 1,
			pos = spot.pos, key = spot.key, info = info,
			along = spot.along, pathIdx = spot.pathIndex,
		}
		u.placedAt = os.clock()
		if uid ~= nil then MyUnits[tostring(uid)] = u end
		if info.isPath then
			local t = Brain.traps[info.base]
			if not t then
				t = {bought = 0, used = 0, wasted = 0}
				Brain.traps[info.base] = t
			end
			t.bought = t.bought + 1
		end
		table.insert(PlacementLog, {id = info.id, key = spot.key, uid = uid})
		table.insert(SessionPlacements, {id = info.id, key = spot.key, uid = uid})
		BadSpots[spot.key] = nil
		return true, u
	end

	local msg = nil
	if res == false then msg = second end
	if res == nil then msg = second end
	return false, classifyReject(res == false and second or nil), msg
end

-- дорожка, по которой сейчас реально идут враги (для ловушек)
local function busiestPath()
	local bestIdx, bestCount = nil, 0
	for idx, u in pairs(PathUsage) do
		if u.count > bestCount then bestCount, bestIdx = u.count, idx end
	end
	-- врагов ещё нет → ловушку готовим на дорожке ТЕКУЩЕЙ волны (ротация!)
	return bestIdx or laneForRound(getRound())
end

-- новое покрытие полосы пути от повторяющейся ловушки в точке s
local function trapMarginal(s, band, pidx)
	local marg = 0
	local list = SamplesByPath[pidx]
	if not list then return 0 end
	for _, smp in ipairs(list) do
		if math.abs(smp.d - s.along) <= band and not SampleCover[smp.gi] then
			marg = marg + smp.w
		end
	end
	return marg
end

-- ================================================================
-- 🎯 ТОЧКА НА ДОРОЖКЕ (ловушки)
--   repeater (Rafflesia, APM>0) — бьёт всех в полосе пути ±(DamageDistance+2).
--     Ставим туда, где эта полоса накрывает максимум НЕ простреленного ещё пути;
--     пересечения дорожек выигрывают автоматически (один куст бьёт по двум).
--   charger (Lawnmower, Speed>0) — по коду игры едет НАЗАД к спавну
--     (DistanceAlongPath -= dt*Speed) и бьёт каждого врага ОДИН раз, а исчезает
--     на d<=0. Значит ставить её надо В КОНЕЦ дорожки — тогда она прочёсывает
--     всю линию от базы до спавна и цепляет всех, кто на ней есть.
-- ================================================================
local function pickPathSpot(info)
	local kind = trapKind(info)
	local pidx = busiestPath()
	local pth = Paths[pidx] or ActivePath
	if not pth then return nil, "no_path" end

	local band = math.max(info.dmgDist or 0, 2) + 2
	local myPos = myPositions()
	local best, bestScore, bestMarg = nil, -math.huge, 0

	for _, s in ipairs(PathSpots) do
		if s.pathIndex == pidx then
			local bad = BadSpots[s.key]
			if not (bad and bad > os.clock()) then
				local free = true
				for _, mp in ipairs(myPos) do
					if flat(mp, s.pos) < 1.2 then free = false break end
				end
				if free then
					local score, marg = 0, 0
					if kind == "charger" then
						-- косилка едет НАЗАД: чем ближе к концу дорожки поставим,
						-- тем больший её участок она прочешет (в идеале — весь)
						score = s.rel * 10
						if s.rel > 0.995 then score = score - 3 end
						marg = s.rel
					else
						marg = trapMarginal(s, band, pidx)
						score = marg / COV_NORM * 3.0 + gridScore(s.key) * 0.6
						local hb = pidx .. "_" .. math.floor(s.along / HEAT_BUCKET)
						if EnemyHeat[hb] then score = score + 0.5 end
						-- У повторяющейся ловушки полоса покрытия одинакова в любой
						-- точке, поэтому нужны тай-брейкеры:
						--  1) не у самой базы — там враги уже добитые, урон уходит
						--     в "оверкилл" (последний рубеж — работа косилки);
						--  2) разносим ловушки по дорожке, а не кучкуем.
						local rel = s.rel or 0.5
						score = score + 0.9 * clamp(1 - math.abs(rel - CFG.trapIdealRel) / 0.45, 0, 1)
						-- у базы раффлезия бессмысленна: враги там уже добитые,
						-- урон уходит в оверкилл, а добивает их косилка
						if rel > 0.80 then score = score - 1.2 end
						if rel > 0.93 then score = score - 2.0 end
						for _, mu in pairs(MyUnits) do
							if mu.info and mu.info.isPath and mu.along
								and (mu.pathIdx or pidx) == pidx then
								local dAlong = math.abs(mu.along - s.along)
								local minSep = (Paths[pidx] and Paths[pidx].Length or 300) / (CFG.maxRepeaters + 1)
								if dAlong < minSep then
									score = score - 1.5 * (1 - dAlong / minSep)
								end
							end
						end
					end
					if math.random() < CFG.exploration then score = score + rnd(-0.25, 0.25) end
					if score > bestScore then bestScore, best, bestMarg = score, s, marg end
				end
			end
		end
	end

	if not best then return nil, "нет точек на дорожке" end
	if kind ~= "charger" and bestMarg <= 0 then return nil, "no_coverage" end
	return best
end

-- ================================================================
-- 🎯 ТОЧКА НА ЗЕМЛЕ (стрелки / фермы)
--   Главный критерий — НОВОЕ покрытие: сколько студов дорожек, которые ещё
--   НЕ простреливаются моими юнитами, попадёт в радиус. Поэтому:
--     • юниты сами расползаются по карте и не кучкуются у базы;
--     • пересечение двух дорожек в радиусе даёт двойную ценность;
--     • к базе встанет только если этот кусок пути больше нечем достать.
-- ================================================================
local function pickGroundSpot(info)
	local range = math.max(info.range, 0)
	local cp = charPos()
	local isFarm = (info.income > 0 and info.dps < 12)

	local pool, anyInRange = {}, false
	for _, s in ipairs(GroundSpots) do
		local bad = BadSpots[s.key]
		if not (bad and bad > os.clock()) then
			local okDist = true
			if cp then okDist = (s.pos - cp).Magnitude <= CFG.charRangeLimit end
			if okDist then
				anyInRange = true
				local cov = range > 0 and spotCoverage(s, range) or 0
				table.insert(pool, {spot = s, cov = cov})
			end
		end
	end
	if #pool == 0 then
		if not anyInRange and cp and #GroundSpots > 0 then return nil, "distance" end
		return nil, "нет доступных точек"
	end
	table.sort(pool, function(a, b) return a.cov > b.cov end)

	local topN = math.min(#pool, CFG.shortlistSize)
	local laneNow = laneForRound(getRound())
	local laneNext = laneForRound(getRound() + 1)
	local nLanes = laneCount()

	local best, bestScore, bestMarg, bestFMarg = nil, -math.huge, 0, 0
	for i = 1, topN do
		local s = pool[i].spot
		local score = 0
		local margNow = 0
		if range > 0 then
			-- покрытие ПО КАЖДОЙ дорожке отдельно: ротация волн значит, что
			-- ценна только точка, бьющая по нескольким линиям сразу
			local per, total, runs = marginalPerLane(s.pos, range)
			margNow = total
			local mNow = per[laneNow] or 0
			local mNext = (nLanes > 1) and (per[laneNext] or 0) or mNow
			local both = math.min(mNow, mNext)          -- пересечение / общая зона
			local fper, ftotal = {}, 0
			if CFG.planRangeMult > 1 then
				fper, ftotal = marginalPerLane(s.pos, range * CFG.planRangeMult)
			end
			local fNow = fper[laneNow] or 0
			local fNext = (nLanes > 1) and (fper[laneNext] or 0) or fNow
			if isFarm and not DefenseCritical then
				score = -(total / COV_NORM) * 3.0 + (s.road > 3 and 0.15 or 0)
			else
				score = (mNow / COV_NORM) * 2.4
					+ (mNext / COV_NORM) * 1.2
					+ (both / COV_NORM) * CFG.crossingBonus * 3.0
					+ math.max(0, runs - 1) * CFG.crossingBonus * 0.5
					+ (fNow / COV_NORM) * 0.8 + (fNext / COV_NORM) * 0.4
					+ ((math.min(fNow, fNext)) / COV_NORM) * CFG.crossingBonus
					+ gridScore(s.key) * 0.6
				local hb = tostring(s.pathIdx) .. "_" .. math.floor((s.along or 0) / HEAT_BUCKET)
				if EnemyHeat[hb] then score = score + 0.4 end
				score = score - clamp(2.2 - (s.road or 0), 0, 1) * 0.25
				-- рядом с изученной choke-точкой — дополнительный бонус
				for _, ck in ipairs(ChokeSpots) do
					if flat(ck.sp.pos, s.pos) < 8 then
						score = score + 1.2
						break
					end
				end
			end
			s._dbg = {mNow = mNow, mNext = mNext, both = both, runs = runs}
		end
		if math.random() < CFG.exploration then score = score + rnd(-0.25, 0.25) end
		if score > bestScore then
			bestScore, best, bestMarg, bestFMarg = score, s, margNow, (s._dbg and (s._dbg.mNow + s._dbg.mNext)) or 0
		end
	end
	-- если изученная choke-точка далеко за лимитом 100 студов от персонажа,
	-- но явно лучше всего доступного рядом — идём к ней пешком и ставим там
	if not isFarm and range > 0 and cp then
		for _, ck in ipairs(ChokeSpots) do
			local csp = ck.sp
			local bad = BadSpots[csp.key]
			if not (bad and bad > os.clock())
				and (csp.pos - cp).Magnitude > CFG.charRangeLimit then
				local per, total, runs = marginalPerLane(csp.pos, range)
				local sc = (total / COV_NORM) * 2.4
					+ math.max(0, runs - 1) * CFG.crossingBonus * 0.5 + 1.2
				if sc > bestScore + CFG.walkScoreMargin then
					walkCloser(csp.pos)
					return nil, "walking"
				end
			end
		end
	end

	if not best then return nil, "нет доступных точек" end

	-- стрелок, который не накрывает ничего ни на одной дорожке, — слив кэша
	if not isFarm and range > 0 and bestMarg <= 0 and bestFMarg <= 0 then
		return nil, "no_coverage"
	end

	local ok, why = validateGround(best.pos, info)
	if not ok then
		BadSpots[best.key] = os.clock() + 45
		return nil, "validate:" .. tostring(why)
	end
	return best
end

local function pickSpot(info)
	if info.isPath then return pickPathSpot(info) end
	return pickGroundSpot(info)
end

-- экипировать инструмент (сервер проверяет HasTool("tl_unitplacer_"..id))
local function equipTool(info)
	local tool = info.tool
	if not tool or not tool.Parent then return false end
	local ch = LP.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if not hum then return false end
	local ok = pcall(function() hum:EquipTool(tool) end)
	if ok then task.wait(0.15) end
	return ok
end

-- полная процедура размещения юнита (с ретраями и классификацией отказов)
local function placeUnit(info)
	if not canPlaceNow() then return false, "notnow" end
	if usedSlots() >= maxSlots() then return false, "slots" end
	if countByBase(info.base) >= info.maxPlaced then return false, "unitmax" end
	if getCash() < info.cost + CFG.reserveCash then return false, "nocash" end
	local cd, cdKind = cooldownLeft(info)
	if cd > 0 then
		return false, string.format("cooldown:%s(%.1fs)", cdKind or "", cd)
	end

	local equipped = false
	local walked = false
	local lastErr = "no_spot"

	for attempt = 1, 5 do
		if destroyed or stopAI then return false, "stopped" end

		local spot, err = pickSpot(info)
		if not spot then
			lastErr = tostring(err or "no_spot")
			if lastErr:find("distance") and CFG.walkToSpots and not walked then
				walked = true
				walkCloser()
			elseif lastErr:find("validate") then
				-- точка уже помечена плохой — берём следующую
				waitHuman(0.15, 0.3)
			elseif lastErr:find("no_coverage") then
				NoCoverage[info.id] = os.clock() + 45
				return false, "no_coverage"
			elseif lastErr:find("no_coverage") then
				return false, "no_coverage"
			else
				return false, lastErr
			end
		else
			local ok, res, msg = tryPlace(info, spot, attempt)
			if ok then
				local cov, runs = 0, 0
				if not info.isPath then
					cov, runs = spotCoverage(spot, math.max(info.range, 1))
				end
				local dbg = spot._dbg or {}
				log(string.format("✓ %s (%s) → %s | uid=%s | кэш %.0f",
					info.name, info.id,
					info.isPath
						and string.format("ПУТЬ #%s d=%.0f/%.0f", tostring(spot.pathIndex), spot.along or 0,
							(Paths[spot.pathIndex] or ActivePath) and (Paths[spot.pathIndex] or ActivePath).Length or 0)
						or  string.format("земля %.0f,%.0f%s | сейчас L%d:%.0f L%d:%.0f | обе:%.0f | линий:%.0f",
							spot.pos.X, spot.pos.Z, spot.terrain and " (terrain)" or "",
							laneForRound(getRound()), dbg.mNow or 0,
							laneForRound(getRound() + 1), dbg.mNext or 0,
							dbg.both or 0, runs),
					tostring(res and res.uid), getCash()))
				-- занимаем место: соседние точки больше не предлагать.
				-- Для земли — навсегда (юнит стоит), для пути — временно:
				-- одноразовая ловушка сгорает и место снова свободно.
				local list = info.isPath and PathSpots or GroundSpots
				local expireAt = info.isPath and (os.clock() + 12) or (os.clock() + 1e6)
				for _, other in ipairs(list) do
					if flat(other.pos, spot.pos) < CFG.minGap then
						BadSpots[other.key] = expireAt
					end
				end
				return true, res
			end

			lastErr = tostring(res)
			if res == "badspot" or res == "overlap" or res == "spacing" then
				BadSpots[spot.key] = os.clock() + 45
				waitHuman(0.2, 0.4)
			elseif res == "distance" then
				BadSpots[spot.key] = os.clock() + 20
				if CFG.walkToSpots and not walked then
					walked = true
					walkCloser()
				end
			elseif res == "noanswer" then
				if CFG.equipOnFail and not equipped then
					equipped = equipTool(info)
					log("сервер промолчал — экипирую", info.toolName or info.id,
						"(" .. tostring(equipped) .. ")")
				else
					BadSpots[spot.key] = os.clock() + 30
					waitHuman(0.3, 0.6)
				end
			else
				-- nocash / slots / unitmax / cooldown / permanent / notnow
				return false, res .. (msg and (" (" .. tostring(msg) .. ")") or "")
			end
		end
	end
	return false, lastErr
end

-- дойти персонажем к цели (лимит сервера — 100 студов от персонажа).
-- Идём КОНКРЕТНО к нужной точке (choke/центр петли), а не к "средней по карте".
walkCloser = function(target)
	if not CFG.walkToSpots then return end
	local ch = LP.Character
	local hum = ch and ch:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	if not target then
		local sum, n = Vector3.new(0, 0, 0), 0
		for i, sp in ipairs(GroundSpots) do
			if i % 7 == 1 then
				sum = sum + sp.pos
				n = n + 1
			end
		end
		if n == 0 then return end
		target = sum / n
	end
	local cp = charPos()
	if cp and (target - cp).Magnitude < 30 then return end
	log(string.format("🚶 Иду к точке (%.0f, %.0f) — она вне 100 студов...", target.X, target.Z))
	pcall(function() hum:MoveTo(target) end)
	task.wait(1.6)
end

-- ================================================================
-- ⬆️ АПГРЕЙД / 💸 ПРОДАЖА
-- ================================================================
local function upgradeUnit(uid)
	if not Remotes.UpgradeUnit then return false, "нет remote" end
	local ok, a, b = pcall(function() return Remotes.UpgradeUnit:InvokeServer(uid) end)
	if ok and a == true then
		local u = MyUnits[tostring(uid)]
		if u then
			u.level = (tonumber(b) and tonumber(b)) or (u.level + 1)
		end
		return true, b
	end
	return false, tostring(b or a)
end

local function sellUnit(uid)
	if not Remotes.SellUnit then return false end
	local ok, a = pcall(function() return Remotes.SellUnit:InvokeServer(uid) end)
	if ok and a == true then
		MyUnits[tostring(uid)] = nil
		return true
	end
	return false
end

local function toggleAutoUpgrade(uid)
	if not Remotes.ToggleAutoUpgrade then return false end
	local ok = pcall(function() Remotes.ToggleAutoUpgrade:InvokeServer(uid) end)
	return ok
end

-- ================================================================
-- 🎯 СТРАТЕГИЯ: ЕДИНАЯ МЕТРИКА «суммарный урон на 1 кэш»
-- ================================================================
-- Всё (поставить стрелка / поставить ловушку / апгрейд) приводится к одному:
-- сколько ВСЕГО урона мы получим до конца игры на 1 вложенный кэш.
--
--   K   = сколько ещё врагов придёт (из таблицы волн карты)
--   V   = средняя скорость врагов
--   cov = сколько студов дорожки накрывает юнит (реальное покрытие, с учётом
--         всех дорожек карты и пересечений)
--
--   стрелок / повторяющаяся ловушка:  value = dps * (cov / V) * K / cost
--       (dps × время, которое враг проводит в радиусе, × число врагов)
--   одноразовая косилка:              value = Σ min(damage, hp врага) / cost
--       (бьёт один раз каждого, кого встретит на своём обратном пути)
--   ферма:                            value = income * T * 0.5 * cashToDps / cost
--
-- Отсюда само собой получается "подкопить или купить": поздняя косилка
-- (K маленькое) проигрывает апгрейду раффлезии, а на последней волне наоборот.

local function wavesTableNow()
	local byMap = ensureMapWaves()
	if not byMap then return nil end
	return byMap[currentDifficulty()] or byMap.dif_normal or byMap.dif_easy
end

-- сколько ещё врагов придёт и их средняя скорость
local WaveCacheRound, WaveCacheK, WaveCacheV = -1, 0, 4
local function remainingWaveStats(round)
	if WaveCacheRound == round then return WaveCacheK, WaveCacheV end
	WaveCacheRound = round
	local waves = wavesTableNow()
	local k, vsum, vn = 0, 0, 0
	if waves then
		for w = math.max(round, 1), #waves do
			for _, g in ipairs(waves[w]) do
				local n = g[2] or 1
				k = k + n
				vsum = vsum + math.max(g[4] or 4, 1) * n
				vn = vn + n
			end
		end
	end
	if k <= 0 then
		k = 8 * math.max(1, getMaxRound() - round)
	end
	WaveCacheK = k
	WaveCacheV = (vn > 0) and (vsum / vn) or 4
	return WaveCacheK, WaveCacheV
end

-- сколько DPS нужно, чтобы не слить ближайшие волны
local function requiredDps(round)
	local t = upcomingThreat(math.max(round, 1), currentDifficulty(), 2)
	if t.hp <= 0 then
		for _, e in ipairs(Enemies) do
			t.hp = t.hp + (e.hp or 0)
			t.count = t.count + 1
			t.speed = math.max(t.speed, e.speed or 5)
			if e.isBoss then t.boss = true end
		end
	end
	if t.hp <= 0 then
		t.hp = 150 * math.max(round, 1)
		t.speed = math.max(t.speed, 4)
	end
	if not ActivePath then return 0, t end
	local time = ActivePath.Length / math.max(t.speed, 1)
	return t.hp / math.max(time, 1), t
end

-- множитель из обучения (0.75 … 1.35)
local function brainUnitMult(id)
	local u = Brain.units[id]
	if not u then return 1.0 end
	return clamp(0.75 + (u.score or 0.5) * 0.5, 0.75, 1.35)
end

-- насколько этот тип ловушки реально срабатывал (used / wasted из brain.json)
local function trapEfficiency(base)
	local t = Brain.traps[base]
	if not t then return 1.0 end
	local tot = (t.used or 0) + (t.wasted or 0)
	if tot < 3 then return 1.0 end
	return clamp(0.4 + 0.9 * (t.used / tot), 0.4, 1.3)
end

-- сколько урона нанесёт одноразовая косилка прямо сейчас (по живым врагам)
local function chargerDamageNow(info, st, pidx)
	local total = 0
	for _, e in ipairs(Enemies) do
		if (not pidx or e.pathIdx == pidx) and (e.hp or 0) > 0 then
			total = total + math.min(st.damage, e.hp)
		end
	end
	return total
end

-- ценность ПОСТАНОВКИ (урон за кэш до конца игры)
local function valueOfPlacement(info, state)
	local st = unitAtLevel(info, 1)
	local K, V = remainingWaveStats(state.round)

	if info.isPath then
		local kind = trapKind(info, st)
		if kind == "charger" then
			local dmg = chargerDamageNow(info, st, busiestPath())
			return dmg / info.cost * trapEfficiency(info.base), kind
		end
		local cov = math.max(2 * ((info.dmgDist or 0) + 2), 8)
		local nL = math.max(laneCount(), 1)
		return st.dps * (cov / COV_NORM) * (K / nL) / V / info.cost
			* trapEfficiency(info.base), kind
	end

	if st.income > 0 and st.dps < 12 then
		local T = remainingSeconds(state.round)
		local inc = (st.income * T * 0.5 * CFG.cashToDps) / info.cost
		return inc + st.dps * covFactorByRange(info.range) / info.cost, "farm"
	end

	local nL = math.max(laneCount(), 1)
	return st.dps * covFactorByRange(info.range) * (K / nL) / V / info.cost, "dps"
end

-- ценность АПГРЕЙДА в той же метрике
local function valueOfUpgrade(u, state)
	local info = u.info or resolveUnit(u.id)
	local cost = upgradeCost(info, u.level)
	if not cost or cost <= 0 then return 0, nil end
	local cur = unitAtLevel(info, u.level)
	local nxt = unitAtLevel(info, u.level + 1)
	local K, V = remainingWaveStats(state.round)

	if info.isPath then
		local kind = trapKind(info, cur)
		if kind == "charger" then
			local stNow = {damage = nxt.damage - cur.damage}
			local dmg = chargerDamageNow(info, stNow, u.pathIdx or busiestPath())
			return dmg / cost, kind
		end
		local cov = math.max(2 * ((info.dmgDist or 0) + 2), 8)
		local nL = math.max(laneCount(), 1)
		return (nxt.dps - cur.dps) * (cov / COV_NORM) * (K / nL) / V / cost, kind
	end

	local covF = covFactorByPos(u.pos, math.max(cur.range, nxt.range))
	local nL = math.max(laneCount(), 1)
	local val = math.max(0, nxt.dps - cur.dps) * covF * (K / nL) / V / cost
	local dinc = nxt.income - cur.income
	if dinc > 0 and state.round <= CFG.farmUntilWave + 5 then
		local T = remainingSeconds(state.round)
		val = val + (dinc * T * 0.5 * CFG.cashToDps) / cost
	end
	return val, "dps"
end

-- ограничения: не спамим расходниками и фермами
local function placementAllowed(info, state)
	if info.isPath then
		local kind = trapKind(info)
		if kind == "charger" then
			-- косилка = аварийный инструмент. Планово покупаем только если
			-- CFG.chargersProactive = true; иначе — исключительно chargerEmergency().
			if not CFG.chargersProactive then return false end
			if state.chargers >= CFG.maxChargers then return false end
			if state.enemiesOnPath <= 0 then return false end
			if state.cash < info.cost * CFG.chargerCashMult then return false end
		else
			if state.repeaters >= CFG.maxRepeaters then return false end
		end
		return true
	end

	local st = unitAtLevel(info, 1)
	if st.income > 0 and st.dps < 12 then
		if state.farms >= CFG.farmsEarly then return false end
		if state.round > CFG.farmUntilWave then return false end
	end
	local nc = NoCoverage[info.id]
	if nc and nc > os.clock() then return false end
	return true
end

-- кого мы НЕ успеем добить до базы: время до базы меньше времени убийства
local function predictLeaks(state)
	local leaks = {}
	local dps = math.max(state.dps, 0.1)
	for _, e in ipairs(Enemies) do
		if (e.hp or 0) > 0 and e.ttb and e.ttb >= 0 then
			local tKill = e.hp / dps
			if e.ttb < tKill or (e.leftToBase or 99999) <= CFG.chargerTriggerStuds then
				table.insert(leaks, e)
			end
		end
	end
	return leaks
end

-- ЭКСТРЕННО: предсказан слив, который косилка может закрыть.
-- Возвращает: info, enemy  — покупать сейчас
--             nil, "save", info — денег нет, КОПИТЬ (резервируем цену)
local function chargerEmergency(state)
	local leaks = predictLeaks(state)
	if #leaks == 0 then return nil end
	local info, dmg = nil, 0
	for _, c in ipairs(Owned) do
		if c.isPath and trapKind(c) == "charger" and cooldownLeft(c) <= 0
			and countByBase(c.base) < c.maxPlaced then
			local st = unitAtLevel(c, 1)
			if st.damage > dmg then dmg, info = st.damage, c end
		end
	end
	if not info then return nil end
	local limit = dmg + CFG.chargerHpMargin
	local target = nil
	for _, e in ipairs(leaks) do
		if (e.hp or 0) <= limit then
			if not target or (e.ttb or 999) < (target.ttb or 999) then target = e end
		end
	end
	if not target then return nil end          -- косилка его не убьёт — копить бессмысленно
	if state.cash < info.cost then
		return nil, "save", info
	end
	return info, target
end

local function bestUpgradeCandidate(state)
	local best, bestVal = nil, 0
	for _, u in pairs(MyUnits) do
		local info = u.info or resolveUnit(u.id)
		local cost = upgradeCost(info, u.level)
		if cost and cost > 0 and cost <= state.cash - (state.reserve or 0) then
			local val, kind = valueOfUpgrade(u, state)
			val = val * CFG.upgradeBias * brainUnitMult(info.id)
			if val > bestVal then
				bestVal = val
				best = {kind = "upgrade", u = u, info = info, cost = cost, value = val, vkind = kind}
			end
		end
	end
	return best, bestVal
end

-- продажа, когда слоты кончились, а урона не хватает
local function maybeSell(state)
	if state.freeSlots > 0 then return false end
	if state.dps >= state.needDps then return false end
	if state.round < 4 then return false end
	local worst, worstVal = nil, math.huge
	for _, u in pairs(MyUnits) do
		local info = u.info or resolveUnit(u.id)
		local st = unitAtLevel(info, u.level)
		if st.income > 0 and st.dps < 25 and not info.isPath then
			local v = st.dps + st.income * 1.5
			if v < worstVal then worstVal, worst = v, u end
		end
	end
	if worst then
		log(string.format("💸 Продаю %s (L%.0f) — слоты кончились, нужен урон", worst.info.name, worst.level))
		return sellUnit(worst.uid)
	end
	return false
end

-- ГЛАВНОЕ РЕШЕНИЕ
local lastBossWarn = -1
local function decideAction(state)
	DefenseCritical = state.dps < state.needDps
	-- босс придёт в ближайшие волны → требуем запас прочности и копим под него
	local threat = upcomingThreat(state.round, currentDifficulty(), 3)
	if threat.boss and state.dps < state.needDps * 1.3 then
		DefenseCritical = true
		if lastBossWarn ~= state.round then
			lastBossWarn = state.round
			log(string.format("👑 БОСС на волнах %d-%d: HP %.0f при наших DPS %.0f (нужно ~%.0f с запасом) — коплю и апгрейжу сильнейших",
				state.round, state.round + 3, threat.hp, state.dps, state.needDps * 1.3))
		end
	end
	local best = nil
	-- держим слот под аварийную косилку: плановые покупки до maxSlots-1
	local reserve = (CFG.keepEmergencySlot and state.freeSlots > 1) and 1 or 0
	local freeForPlan = state.freeSlots - reserve

	-- 0) предсказан слив: косилка его закрывает → покупаем СЕЙЧАС,
	--    денег не хватает → КОПИМ (резерв = цена косилки, апгрейды стоп)
	local emerg, emergEnemy, emergSave = chargerEmergency(state)
	if emerg then
		return {kind = "place", info = emerg, value = math.huge, vkind = "charger_emergency",
			why = emergEnemy}
	end
	if emergSave then
		state.reserve = emergSave.cost
	end
	local reserve = state.reserve or 0

	if freeForPlan > 0 then
		for _, info in ipairs(Owned) do
			if info.cost > 0 and info.cost <= state.cash - reserve
				and countByBase(info.base) < info.maxPlaced
				and cooldownLeft(info) <= 0
				and placementAllowed(info, state) then
				local val, kind = valueOfPlacement(info, state)
				val = val * brainUnitMult(info.id)
				if val > 0 and (not best or val > best.value) then
					best = {kind = "place", info = info, value = val, vkind = kind}
				end
			end
		end
	end

	local up = bestUpgradeCandidate(state)
	if up and (not best or up.value > best.value) then best = up end

	return best
end

local function collectState()
	local st = boardStats()
	local farms, chargers, repeaters = 0, 0, 0
	for _, u in pairs(MyUnits) do
		local info = u.info or resolveUnit(u.id)
		local us = unitAtLevel(info, u.level)
		if info.isPath then
			local kind = trapKind(info, us)
			if kind == "charger" then chargers = chargers + 1 else repeaters = repeaters + 1 end
		elseif us.income > 0 and us.dps < 12 then
			farms = farms + 1
		end
	end
	local ms = maxSlots()
	local used = usedSlots()
	return {
		cash      = getCash(),
		round     = getRound(),
		slots     = used,
		maxSlots  = ms,
		freeSlots = ms - used,
		dps       = st.dps,
		income    = st.income,
		traps     = st.traps,
		chargers  = chargers,
		repeaters = repeaters,
		farms     = farms,
		enemiesOnPath = #Enemies,
		needDps   = requiredDps(getRound()),
		baseHp    = Base.hp,
	}
end

-- ================================================================
-- 🎚 СЛОЖНОСТЬ (фиксированная, переключается клавишами 1…5)
-- ================================================================
local function voteDifficulty()
	if not (CFG.voteDifficulty and Remotes.PlaceDifficultyVote) then return end
	local ok, res = pcall(function()
		return Remotes.PlaceDifficultyVote:InvokeServer(CFG.difficulty)
	end)
	if not ok then
		log("⚠️ Голосование за сложность errored:", res)
	else
		log("🗳 Проголосовал за сложность:", CFG.difficulty, "(ответ сервера:", tostring(res), ")")
	end
end

local function setDifficulty(id)
	local found = false
	for _, d in ipairs(DIFFICULTIES) do
		if d == id then found = true end
	end
	if not found then
		log("❌ Нет такой сложности:", id, "| доступны:", table.concat(DIFFICULTIES, ", "))
		return
	end
	CFG.difficulty = id
	WaveCacheRound = -1          -- сброс кэша волн
	DynMapId = nil               -- перечитать волны под новую сложность
	log("🎚 Сложность установлена:", id)
	voteDifficulty()
	saveBrain()
	local real = currentDifficulty()
	if real ~= id then
		log("ℹ️ Сервер сейчас считает активной:", real,
			"— голос засчитается, если окно голосования ещё открыто")
	end
end

-- ================================================================
-- 🔁 РЕСТАРТ
-- ================================================================
local function clickEndButton()
	local ok = pcall(function()
		for _, d in ipairs(LP.PlayerGui:GetDescendants()) do
			if d:IsA("TextButton") or d:IsA("ImageButton") then
				local n = tostring(d.Name):lower()
				local t = ""
				if d:IsA("TextButton") then t = tostring(d.Text):lower() end
				local vis = d.Visible
				local par = d.Parent
				while vis and par do
					if par:IsA("GuiObject") and not par.Visible then vis = false end
					par = par.Parent
				end
				if vis and (n:find("restart") or n:find("playagain") or n:find("again")
					or t:find("restart") or t:find("play again") or t:find("ещё раз")) then
					d:Activate()
					return true
				end
			end
		end
	end)
	return ok
end

local function restartGame()
	if Remotes.RestartGame then
		pcall(function() Remotes.RestartGame:InvokeServer() end)
	end
	task.wait(rnd(1.2, 2.2))
	if gameEnded() then
		pcall(function() Remotes.RestartGame:InvokeServer(true) end)
		task.wait(rnd(1.0, 1.8))
	end
	if gameEnded() then clickEndButton() end
end

-- ================================================================
-- 🌊 ГЛАВНЫЙ ЦИКЛ
-- ================================================================
local statusFn
local guiWritable = true      -- некоторые экзекуторы не дают потоку из task.spawn
local lastStatusText = ""     -- писать в GUI ("lacking capability Plugin")

local function setStatus(t, bad)
	if statusFn then
		statusFn(t, bad)   -- внутри pcall, AI не убьёт
	end
	if not guiWritable and t ~= lastStatusText then
		lastStatusText = t
		log("[статус]", (tostring(t):gsub("\n", " | ")))
	end
end

local function diagnostics()
	updateBase()
	log("======== ДИАГНОСТИКА ========")
	log("Карта:", tostring(workspace:GetAttribute("MapId")),
		"| сложность:", currentDifficulty(),
		"| волна", getRound(), "/", getMaxRound(),
		"| врагов осталось:", tostring(workspace:GetAttribute("EnemiesLeft")))
	log(string.format("БАЗА: HP %.0f/%.0f | позиция %s",
		Base.hp, Base.maxHp,
		Base.pos and string.format("%.0f, %.0f, %.0f", Base.pos.X, Base.pos.Y, Base.pos.Z) or "не найдена"))
	log("Кэш:", getCash(), "| слоты:", usedSlots(), "/", maxSlots(), "| место на карте:", tostring(workspace:GetAttribute("MapId")))
	log("Путей:", #Paths, "| активный #" .. ActivePathIndex,
		ActivePath and ("| длина " .. string.format("%.0f", ActivePath.Length)) or "")
	if laneCount() > 1 then
		local r = getRound()
		log(string.format("РОТАЦИЯ ДОРОЖЕК (AllowedPaths): волна %.0f → #%d | волна %.0f → #%d | волна %.0f → #%d",
			r, laneForRound(r), r + 1, laneForRound(r + 1), r + 2, laneForRound(r + 2)))
	end
	log("Точек: земля =", #GroundSpots, "| на пути =", #PathSpots)
	log("Инвентарь:", #Owned)
	for _, u in ipairs(Owned) do
		log(string.format("  • %-22s %-22s cost=%-7.0f max=%-4s range=%-5.0f dps=%-8.1f %s%s",
			u.name, u.id, u.cost,
			u.maxPlaced == math.huge and "∞" or tostring(u.maxPlaced),
			u.range, u.dps,
			u.isPath and "НА ПУТЬ " or "",
			u.income > 0 and ("доход " .. string.format("%.1f/с", u.income)) or ""))
	end
	local bs = boardStats()
	local need, threat = requiredDps(getRound())
	local cs = collectState()
	log(string.format("ДОСКА: dps=%.1f (нужно ~%.1f) | доход=%.1f/с | юнитов=%.0f | ферм=%.0f | раффлезий=%.0f | косилок=%.0f",
		bs.dps, need, bs.income, cs.slots, cs.farms, cs.repeaters, cs.chargers))
	local parts = {}
	for base, t in pairs(Brain.traps) do
		table.insert(parts, string.format("%s: куплено %.0f, сработало %.0f, впустую %.0f",
			base, t.bought or 0, t.used or 0, t.wasted or 0))
	end
	if #parts > 0 then
		log("ЛОВУШКИ (статистика обучения): " .. table.concat(parts, " | "))
	else
		log("ЛОВУШКИ: статистики пока нет")
	end
	log(string.format("ОБУЧЕНИЕ: игр %.0f | побед %.0f | рекорд волна %.0f | волн сыграно %.0f | чисто %.0f | слито HP базы %.0f",
		Brain.games, Brain.wins, Brain.best, Brain.wavesPlayed, Brain.wavesClean, Brain.leaked))
	local scores = {}
	for id, u in pairs(Brain.units) do
		table.insert(scores, string.format("%s=%.2f", id:gsub("unit_", ""), u.score or 0.5))
	end
	table.sort(scores)
	if #scores > 0 then log("ОЦЕНКИ ЮНИТОВ (brain.json): " .. table.concat(scores, " ")) end
	log(string.format("УГРОЗА (3 волны): HP=%.0f, врагов=%.0f, скорость=%.0f, босс=%s",
		threat.hp, threat.count, threat.speed, tostring(threat.boss)))
	local en = scanEnemies()
	log("ВРАГИ СЕЙЧАС:", #en)
	table.sort(en, function(a, b) return (a.ttb or 999) < (b.ttb or 999) end)
	for i, e in ipairs(en) do
		if i <= 8 then
			log(string.format("  %.0f) %-22s HP %.0f/%.0f | скорость %.1f | путь %.0f/%.0f | до базы %.1fс %s",
				i, e.id, e.hp or 0, e.maxHp or 0, e.speed or 0, e.along or 0,
				ActivePath and ActivePath.Length or 0, e.ttb or -1,
				e.isBoss and "⚠️БОСС" or ""))
		end
	end
	log("=============================")
end

local function waitGameStart()
	for _ = 1, 200 do
		if destroyed or stopAI then return false end
		if gameEnded() then return false end
		if canPlaceNow() and (gameStarted() or getRound() >= 0) then
			if ActivePath then return true end
		end
		task.wait(0.3)
	end
	return canPlaceNow()
end

local function runAI()
	if running then return end
	running = true
	stopAI = false

	local function step(name, fn)
		local ok, err = pcall(fn)
		if ok then
			log("  ✓ " .. name)
		else
			log("  ✗ " .. name .. " → " .. tostring(err))
		end
		return ok
	end

	log("=== ИНИЦИАЛИЗАЦИЯ v9 ===")
	loadBrain()
	step("мост к модулям игры", function() initBridge(20) end)
	step("база", updateBase)
	step("инвентарь", discoverOwned)
	step("путь", buildPaths)
	step("точки постройки", buildSpots)
	step("мои юниты", syncMyUnits)
	step("враги", scanEnemies)
	diagnostics()

	if #Owned == 0 then
		log("❌ В Backpack нет ни одного Tool с UnitId.")
		setStatus("Нет юнитов в Backpack!", true)
		running = false
		return
	end
	if not ActivePath then
		log("❌ Путь не найден (Map.PathNodes / PathNodes2).")
		setStatus("Путь не найден", true)
		running = false
		return
	end
	if #GroundSpots == 0 then
		log("❌ Не найдено ни одной Placeable-точки.")
		setStatus("Нет мест для постройки", true)
		running = false
		return
	end

	local session, breakIn = 0, math.random(CFG.breakEveryMin, CFG.breakEveryMax)
	local placements = {}

	while not stopAI and not destroyed do
		session = session + 1
		if session > CFG.sessionCap then
			log("Лимит сессии — стоп.")
			break
		end
		if session > breakIn then
			local t = rnd(CFG.breakTimeMin, CFG.breakTimeMax)
			setStatus("☕ Перерыв " .. math.floor(t) .. "с", false)
			task.wait(t)
			session = 1
			breakIn = math.random(CFG.breakEveryMin, CFG.breakEveryMax)
		end

		setStatus("Ожидание старта игры...", false)
		if not waitGameStart() then
			if gameEnded() then
				log("Игра уже окончена — перезапускаю.")
			else
				break
			end
		end

		-- подготовка к новой игре
		pcall(initBridge)
		updateBase()
		discoverOwned()
		buildPaths()
		buildSpots()
		MyUnits = {}
		syncMyUnits()
		placements = {}
		SessionPlacements = {}
		table.clear(BadSpots)

		voteDifficulty()
		waitHuman(0.4, 0.8)
		local realDif = currentDifficulty()
		if realDif ~= CFG.difficulty then
			log("ℹ️ Фактическая сложность забега: " .. realDif .. " (в CFG стоит " .. CFG.difficulty .. ") — учитываю фактическую")
		end

		log(string.format("=== НОВАЯ ИГРА | кэш %.0f | слотов %.0f | волн %.0f | база %.0f HP ===",
			getCash(), maxSlots(), getMaxRound(), Base.hp))
		setStatus("Игра началась\nСтрою...", false)

		-- -------- основной эконом-цикл --------
		local lastAction, idleSince = 0, os.clock()
		local lastEnemyScan = os.clock()
		local lastRediscover = os.clock()
		local lastRound = getRound()
		local lastBaseHp = Base.hp
		local lastSave = os.clock()

		local loopErrors = 0

		-- одна итерация вынесена в функцию: ошибка логируется, но НЕ убивает AI
		local function iterate()
		updateBase()
		local round = getRound()

		-- конец игры?
		if gameEnded() or Base.hp <= 0 then
			local won = Base.hp > 0 and round >= getMaxRound()
			log(string.format("🏁 Игра окончена | волна %.0f | база %.0f/%.0f | %s",
				round, Base.hp, Base.maxHp, won and "ПОБЕДА" or "поражение"))
			learn(round, won, SessionPlacements)
			setStatus(string.format("%s | волна %.0f\nИгр: %.0f | побед: %.0f | рекорд: %.0f",
				won and "ПОБЕДА" or "Поражение", round, Brain.games, Brain.wins, Brain.best), false)

			task.wait(rnd(1.5, 3))
			restartGame()
			task.wait(rnd(2, 3.5))
			return true
		end

		-- 📚 ОБУЧЕНИЕ: волна сменилась → оцениваем, как мы её прожили
		if round ~= lastRound then
			local dmg = math.max(0, (lastBaseHp or Base.maxHp) - Base.hp)
			Brain.wavesPlayed = Brain.wavesPlayed + 1
			if dmg <= 0 then
				Brain.wavesClean = Brain.wavesClean + 1
			else
				Brain.leaked = Brain.leaked + dmg
			end
			local reward = dmg <= 0 and 1.0
				or clamp(1 - dmg / math.max(Base.maxHp, 1), 0, 0.9)
			learnStep(reward, SessionPlacements)
			log(string.format("📚 Волна %.0f → %.0f | урон базе %.0f | награда %.2f | чисто пройдено %.0f/%.0f",
				lastRound, round, dmg, reward, Brain.wavesClean, Brain.wavesPlayed))
			lastRound = round
			lastBaseHp = Base.hp
			if os.clock() - lastSave > 45 then
				saveBrain()
				lastSave = os.clock()
			end
		end

		-- скан врагов (не чаще раза в 1.5с)
		if os.clock() - lastEnemyScan > 1.5 then
			scanEnemies()
			lastEnemyScan = os.clock()
		end
		syncMyUnits()
		if os.clock() - lastRediscover > 20 then
			discoverOwned()
			lastRediscover = os.clock()
		end

		-- какие куски пути уже простреливаются (нужно для "нового покрытия")
		rebuildSampleCover()

		local state = collectState()
		state.needDps = requiredDps(round)

		-- статус
		setStatus(string.format("Волна %.0f/%.0f | база %.0f/%.0f\nКэш %.0f | DPS %.0f (нужно %.0f)\nЮнитов %.0f/%.0f | врагов %.0f",
			round, getMaxRound(), Base.hp, Base.maxHp,
			state.cash, state.dps, state.needDps,
			state.slots, state.maxSlots, #Enemies), false)

		if not canPlaceNow() then
			task.wait(0.6)
		else
			local acted = false

			-- решение принимает decideAction (в нём же экстренная косилка у базы)
			-- 2) плановое решение: поставить / апгрейднуть / продать
			if not acted then
				local act = decideAction(state)
				if act and act.kind == "place" then
					if act.vkind == "charger_emergency" and act.why then
						log(string.format("🚨 %s (%.0f HP) в %.0f студах от базы — кидаю %s в конец дорожки",
							act.why.id, act.why.hp or 0, act.why.leftToBase or -1, act.info.name))
					elseif act.value < 1e8 then
						log(string.format("🛒 %s [%s] ценность %.1f урона/кэш", act.info.name, tostring(act.vkind), act.value))
					end
					local ok, why = placeUnit(act.info)
					if ok then
						acted = true
					else
						local w = tostring(why)
						local quiet = w:find("nocash") or w:find("cooldown") or w:find("no_coverage")
							or w:find("unitmax") or w:find("slots") or w:find("notnow")
							or w:find("walking")
						if not quiet then log("✗ не поставить", act.info.id, "→", w) end
						if w:find("distance") then walkCloser() end
						if w:find("no_spot") or w:find("validate") then buildSpots() end
						if w:find("no_coverage") then
							-- свободных мест с покрытием пути нет → лучше апгрейд
							local upAlt = bestUpgradeCandidate(state)
							if upAlt then
								log(string.format("⬆️ Апгрейд %s (L%.0f→L%.0f) за %.0f",
									upAlt.info.name, upAlt.u.level, upAlt.u.level + 1, upAlt.cost))
								if upgradeUnit(upAlt.u.uid) then acted = true end
							end
						end
					end
					waitHuman(CFG.placeDelay[1], CFG.placeDelay[2])
				elseif act and act.kind == "upgrade" then
					log(string.format("⬆️ Апгрейд %s (L%.0f→L%.0f) за %.0f (ценность %.1f)",
						act.info.name, act.u.level, act.u.level + 1, act.cost, act.value or 0))
					local okUp = upgradeUnit(act.u.uid)
					if okUp then acted = true end
					waitHuman(0.25, 0.55)
				else
					-- ничего не можем купить → может, продать ферму ради слота?
					if maybeSell(state) then acted = true end
				end
			end

			if acted then
				lastAction = os.clock()
				idleSince = os.clock()
			else
				-- нечего делать: ждём денег / кулдаунов
				if os.clock() - idleSince > 30 and os.clock() - lastAction > 30 then
					idleSince = os.clock()
					buildSpots()
					table.clear(BadSpots)
				end
				task.wait(rnd(0.6, 1.4))
			end
		end
			return false
		end

		while not stopAI and not destroyed do
			task.wait(rnd(CFG.actionDelay[1], CFG.actionDelay[2]))
			local okIter, a, b = pcall(iterate)
			if not okIter then
				loopErrors = loopErrors + 1
				log("❌ Ошибка итерации #" .. loopErrors .. ":", a)
				setStatus("Ошибка цикла:\n" .. tostring(a):sub(1, 95), true)
				if loopErrors > 25 then
					log("Слишком много ошибок подряд — останавливаюсь.")
					break
				end
				task.wait(1.2)
			elseif a then
				break
			end
		end
	end

	saveBrain()
	running = false
	log("Остановлено.")
end

-- ================================================================
-- 🖥 GUI
-- ================================================================
local guiParent = game.CoreGui
if type(gethui) == "function" then
	local ok, h = pcall(gethui)
	if ok and h then guiParent = h end
end
if guiParent:FindFirstChild("AI_GardenTD9") then
	guiParent.AI_GardenTD9:Destroy()
end

guiRef = Instance.new("ScreenGui")
guiRef.Name = "AI_GardenTD9"
guiRef.ResetOnSpawn = false
guiRef.Parent = guiParent

local bg  = Color3.fromRGB(14, 16, 24)
local acc = Color3.fromRGB(80, 200, 120)

local Main = Instance.new("Frame")
Main.Size = UDim2.new(0, 250, 0, 180)
Main.Position = UDim2.new(0, 10, 0.35, 0)
Main.BackgroundColor3 = bg
Main.BorderSizePixel = 0
Main.Active = true
Main.Parent = guiRef
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 10)

local Header = Instance.new("Frame")
Header.Size = UDim2.new(1, 0, 0, 28)
Header.BackgroundColor3 = Color3.fromRGB(22, 26, 38)
Header.BorderSizePixel = 0
Header.Parent = Main

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -12, 1, 0)
title.Position = UDim2.new(0, 10, 0, 0)
title.BackgroundTransparency = 1
title.Text = "🧠 Garden AI v9.7  [M] destroy"
title.TextColor3 = Color3.fromRGB(230, 230, 250)
title.Font = Enum.Font.GothamBold
title.TextSize = 11
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = Header

local Status = Instance.new("TextLabel")
Status.Size = UDim2.new(1, -16, 0, 78)
Status.Position = UDim2.new(0, 8, 0, 32)
Status.BackgroundTransparency = 1
Status.Text = "Ready\nStart — запуск\nG — диагностика, 1-5 — сложность\nM — уничтожить"
Status.TextColor3 = Color3.fromRGB(150, 150, 180)
Status.Font = Enum.Font.Gotham
Status.TextSize = 10
Status.TextWrapped = true
Status.TextXAlignment = Enum.TextXAlignment.Left
Status.TextYAlignment = Enum.TextYAlignment.Top
Status.Parent = Main

statusFn = function(text, bad)
	if destroyed or not guiWritable then return end
	-- ВАЖНО: запись в GUI из потока task.spawn может быть запрещена экзекутором
	-- ("The current thread cannot access 'Instance' (lacking capability Plugin)").
	-- Поэтому только через pcall: ошибка не должна ронять AI.
	local ok = pcall(function()
		Status.Text = text
		Status.TextColor3 = bad and Color3.fromRGB(230, 90, 90) or acc
	end)
	if not ok then
		guiWritable = false
		log("⚠️ GUI-статус недоступен из этого потока — переключаюсь на консоль (AI продолжает работать)")
	end
end

local function btn(text, x, w, color, fn)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, w, 0, 26)
	b.Position = UDim2.new(0, x, 1, -34)
	b.BackgroundColor3 = color
	b.Text = text
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 10
	b.BorderSizePixel = 0
	b.Parent = Main
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	connect(b.MouseButton1Click, fn)
	return b
end

btn("Start", 8, 62, acc, function()
	task.spawn(function()
		local ok, err = pcall(runAI)
		if not ok then
			log("❌ КРИТИЧЕСКАЯ ОШИБКА runAI:", err)
			if statusFn then statusFn("Ошибка:\n" .. tostring(err):sub(1, 110), true) end
		end
	end)
end)
btn("Stop", 76, 52, Color3.fromRGB(180, 60, 60), function() stopAI = true end)
btn("Diag", 134, 52, Color3.fromRGB(70, 110, 190), function()
	task.spawn(function()
		local ok, err = pcall(function()
			initBridge(10)
			updateBase()
			discoverOwned()
			buildPaths()
			buildSpots()
			syncMyUnits()
			diagnostics()
		end)
		if not ok then log("❌ Ошибка диагностики:", err) end
	end)
end)

-- Drag
local drag, startP, startPos
connect(Header.InputBegan, function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then
		drag, startP, startPos = true, i.Position, Main.Position
	end
end)
connect(UIS.InputChanged, function(i)
	if drag and i.UserInputType == Enum.UserInputType.MouseMovement then
		local d = i.Position - startP
		pcall(function()
			Main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end)
	end
end)
connect(UIS.InputEnded, function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 then drag = false end
end)

connect(UIS.InputBegan, function(i, processed)
	if processed then return end
	local kc = i.KeyCode
	if kc == Enum.KeyCode.M then
		destroyAll()
	elseif kc == Enum.KeyCode.One or kc == Enum.KeyCode.KeypadOne then
		setDifficulty(DIFFICULTIES[1])
	elseif kc == Enum.KeyCode.Two or kc == Enum.KeyCode.KeypadTwo then
		setDifficulty(DIFFICULTIES[2])
	elseif kc == Enum.KeyCode.Three or kc == Enum.KeyCode.KeypadThree then
		setDifficulty(DIFFICULTIES[3])
	elseif kc == Enum.KeyCode.Four or kc == Enum.KeyCode.KeypadFour then
		setDifficulty(DIFFICULTIES[4])
	elseif kc == Enum.KeyCode.Five or kc == Enum.KeyCode.KeypadFive then
		setDifficulty(DIFFICULTIES[5])
	elseif kc == Enum.KeyCode.G then
		task.spawn(function()
			local ok, err = pcall(function()
				updateBase(); discoverOwned(); syncMyUnits(); scanEnemies()
				rebuildSampleCover(); diagnostics()
			end)
			if not ok then log("❌ Ошибка диагностики:", err) end
		end)
	elseif kc == Enum.KeyCode.H then
		log("Горячие клавиши: 1-5 = сложность (easy…impossible), G = диагностика, M = уничтожить скрипт")
		log("Текущая сложность:", CFG.difficulty, "| серверная:", currentDifficulty())
	end
end)

log("✅ v9.7 загружен (сборка 7). Сложность:", CFG.difficulty,
	"| клавиши: 1-5 сложность, G диагностика, H справка, M уничтожить")
