--!strict
--[[
	Every image asset ID in the codebase lives here: flat, one named entry per
	unique ID, PLUS grouped nested tables for a large same-shaped set (e.g.
	ThemeIcons below, one per Cosmetics keycap theme) so that set doesn't have
	to be 131 flat top-level entries. Everything here, flat or nested, is
	preloaded at boot via `AssetIds/Preloader.luau` (which recurses into
	nested groups) plus the loading screen.

	Monetization IDs (PassID/GiftID/ProductID, GroupID/Admins) are NOT content
	assets and must never be added here -- see Config/Passes.luau,
	Config/Products.luau, Config/Packs.luau, Config/General.luau.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local Images = {
	LaunchTarget = 72382621618473, -- LaunchController drop-target marker icon
	TopbarSettings = 106769461169677, -- TopbarUIController topbar button that opens Settings
	DailyRewardDay1 = 73989013612789, -- DailyRewards day 1
	SecretPack = 88132060004695, -- DailyRewards day 2 + Promotion "Secret Pack"
	DailyRewardDay3 = 135629275004235, -- DailyRewards day 3
	StarterPack = 73167539394400, -- DailyRewards day 4 + Promotion "Starter Pack"
	Cash = 110024503496390, -- DailyRewards day 5 + every WheelSpin cash reward
	DailyRewardDay6 = 127607991886697, -- DailyRewards day 6
	DailyRewardDay7 = 137945076270111, -- DailyRewards day 7
	PlaytimeReward = 112943806732824, -- every PlaytimeRewards slot
	VipPass = 122420734012429, -- Promotion "VIP"
	TeleporterPass = 113198463459379, -- Promotion "Teleporter"
	SpeedPass = 130304640405359, -- Promotion "x2 Speed"
	Cash100K = 72195296200818, -- Promotion "100K Cash"
	Wheel = 101212300915466, -- Promotion "x5 Spins" (asset's real name is "Wheel")

	--[[
		Cosmetics keycap-theme card icons (COSMETICS_PLAN.md), keyed by
		CosmeticsCatalog theme id, in catalog order (matches
		CosmeticsCatalog.KeycapThemes / KeyCapsController.THEMES). Read
		directly by CosmeticsController's per-slot icon-override lookup --
		see its iconOverridesForSlot. Extracted 2026-07-23 from the place's
		IconForge Icons ScreenGui; all 131 catalog ids verified present.
	]]
	ThemeIcons = {
		ChocolateBar = 88434280686971,
		SakuraLacquer = 112461410926657,
		Bauhaus = 101682727782395,
		NordicDusk = 127449826550677,
		MatchaInk = 73599589284932,
		MoonRabbit = 109486229938580,
		SorbetSplit = 129951825628101,
		BlackCherry = 82576176586213,
		Solarized = 139482421411383,
		ToyBlocks = 85619330641264,
		RetroConsole = 111078079362844,
		CyberY2K = 131887566990212,
		CandyCircuit = 124395807436961,
		BubbleTea = 108668349007999,
		PopArt = 88649882966686,
		NeonGrid = 134875528114589,
		AcidPulse = 82994312029814,
		SolarFlare = 132527096536633,
		BlueReactor = 85668591574409,
		Ultraviolet = 124583884110874,
		AutumnOrchard = 78693648767456,
		BambooInk = 114980429816697,
		MahoganyStudy = 86119666160194,
		PaintedWorkshop = 134369833722021,
		NordicCabin = 78067344178964,
		Boardwalk = 91909100304992,
		Driftwood = 108796636990344,
		PirateMap = 87523029785172,
		MarbleNoir = 70400648428518,
		VerdeMarble = 76045874693070,
		RoseMarble = 110057319747403,
		ImperialMarble = 128116920784250,
		BlackBeach = 117315735004493,
		ObsidianGold = 100780724280414,
		Stormfront = 137378391954887,
		Monsoon = 104775338542864,
		Inkstone = 85475713855842,
		CrateredEmber = 125009614777862,
		ArcaneMagma = 108570455112218,
		ToxicCore = 72711657750711,
		ConcreteMinimal = 134684747190725,
		BrutalistSignal = 73106350810895,
		GraffitiWall = 137304979006038,
		Cathedral = 125174251797095,
		FossilBed = 92397557774466,
		IvoryGarden = 106293101281070,
		LunarGranite = 139578301128126,
		GraniteRose = 115979074025601,
		SpeckledTerrazzo = 80667901345638,
		MetroPlatform = 94993336029335,
		RainyAlley = 101424459631366,
		ChalkCourt = 126483255445128,
		BrickGarden = 111117449906235,
		PaintedBrick = 87106230653247,
		MidnightBrick = 139789118949215,
		RiverStones = 124339641280133,
		ZenPebble = 131431136246942,
		CandyPebbles = 92435119210349,
		OldHarbor = 90194067548780,
		MossTemple = 125198681115556,
		WinterSquare = 101739674080120,
		CrystalCave = 76228798399709,
		CavernMoss = 129025503836965,
		DesertGeode = 123500398613825,
		RedMesa = 103712694862238,
		Sunstone = 103788521363448,
		CanyonTwilight = 112843276056177,
		RustBloom = 81865175405345,
		Shipwreck = 78228592609148,
		JunkyardNeon = 98898448163078,
		IndustrialHazard = 135054785279349,
		MechaWhite = 140042514408071,
		DesertRig = 106268578518448,
		Mercury = 125230658830300,
		RoseFoil = 136923507049964,
		OilSlick = 79058982153315,
		BrassObservatory = 126804833276180,
		CopperPatina = 117641914607390,
		GunmetalOrange = 79262952667618,
		ChromePop = 116157622723316,
		OrbitalLab = 83440152513725,
		AlpineMeadow = 130532836766959,
		MeadowPicnic = 80663908366217,
		BiolumGrove = 129771795036237,
		RainforestFruit = 110866826704916,
		EnchantedFoliage = 122633343050603,
		AutumnCanopy = 108482797051993,
		DesertMirage = 140314868698509,
		MoonSand = 133794354382192,
		CoralDunes = 134473976962522,
		RoyalVelvet = 133919896290069,
		Tartan = 115697828190433,
		SunflowerDenim = 101690886306066,
		KimonoNight = 126720942864026,
		PolarNight = 108162010916175,
		Snowberry = 115603846508975,
		AlpineSunrise = 95194978412845,
		MuddyBoots = 126692236317372,
		ClaySwamp = 72513707551061,
		Petrichor = 107315934141961,
		TundraGround = 102600457718909,
		CityCrosswalk = 83574495043000,
		SunsetBoulevard = 77576307516375,
		SaltFlats = 129855129245288,
		HimalayanSalt = 132083993025030,
		Frostfire = 79660706752612,
		BlackIce = 83395542869756,
		GlacierVein = 135962259222320,
		AncientIce = 108025323141771,
		SeaGlass = 101962335361606,
		StainedGlass = 137371839675469,
		SunsetGlass = 108251535155184,
		SmokedGlass = 129216525391729,
		HolographicPearl = 114152789306601,
		SpectralError = 140542546751259,
		PaperToy = 118223752089802,
		Newspaper = 104038057896911,
		DesertRug = 113644646961721,
		ArcadeCarpet = 128969495433750,
		MediterraneanTiles = 78185294683194,
		Kintsugi = 113578258282755,
		TuscanRoof = 118695566104308,
		FestivalRoof = 112935679255826,
		RooftopRain = 85456638832813,
		GingerbreadRoof = 111378821388040,
		Leatherbound = 108285712817247,
		RacingLeather = 84174680425671,
		ChalkStucco = 140409079624587,
		ArtDecoPlaster = 138568507820150,
		RubberDuck = 79172199450122,
		StealthRubber = 108500065453603,
	} :: { [string]: number },
}

export type Images = typeof(Images)

return Images
