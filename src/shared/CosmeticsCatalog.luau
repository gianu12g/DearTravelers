--!strict
--[[
	Single id authority for owned cosmetics (COSMETICS_PLAN.md). Two slots
	today -- keycap Themes and squishy launch Trails -- each an ordered list of
	{Id, DisplayName}. Future shop bundles grant ids through
	CosmeticsService.grant and must reference the SAME ids listed here.

	Deliberately id + DisplayName ONLY: the ~1600-line visual THEMES table
	(colors, material) stays client-side in KeyCapsController, because nothing
	server-side or in the equip flow ever needs to render a theme, only to
	validate and persist its id. KeyCapsController.Init runs a drift guard
	against this list in both directions -- see its own comment.

	A plain module (name ends in neither Service nor Controller, so the Loader
	ignores it, ARCHITECTURE.md Recipe 3). Require it directly.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MergeConfig = require(ReplicatedStorage.Shared.MergeConfig)

export type Slot = "KeycapThemes" | "SquishyTrails"

export type CatalogEntry = {
	Id: string,
	DisplayName: string,
}

local CosmeticsCatalog = {}

-- CollectionService tag on every key MeshPart, and the attribute
-- KeyCapsController reads to pick a theme. CosmeticsService stamps this
-- attribute; it does not own the tag itself (Studio-authored).
CosmeticsCatalog.KEY_TAG = "Key"
CosmeticsCatalog.THEME_ATTRIBUTE = "Theme"

-- Unequip always reverts to these -- the equipped id is never empty
-- (COSMETICS_PLAN.md "Decisions").
CosmeticsCatalog.DEFAULT_KEYCAP_THEME_ID = "ChocolateBar"
CosmeticsCatalog.DEFAULT_SQUISHY_TRAIL_ID = MergeConfig.DEFAULT_LAUNCH_TRAIL_MODEL_NAME

-- Every id in KeyCapsController's THEMES table, same top-to-bottom order.
-- Keep in sync manually -- KeyCapsController.Init's drift guard warns (not
-- errors) if this ever falls behind or ahead of THEMES.
CosmeticsCatalog.KeycapThemes = {
	{ Id = "ChocolateBar", DisplayName = "Chocolate Bar" },
	{ Id = "SakuraLacquer", DisplayName = "Sakura Lacquer" },
	{ Id = "Bauhaus", DisplayName = "Bauhaus" },
	{ Id = "NordicDusk", DisplayName = "Nordic Dusk" },
	{ Id = "MatchaInk", DisplayName = "Matcha Ink" },
	{ Id = "MoonRabbit", DisplayName = "Moon Rabbit" },
	{ Id = "SorbetSplit", DisplayName = "Sorbet Split" },
	{ Id = "BlackCherry", DisplayName = "Black Cherry" },
	{ Id = "Solarized", DisplayName = "Solarized" },
	{ Id = "ToyBlocks", DisplayName = "Toy Blocks" },
	{ Id = "RetroConsole", DisplayName = "Retro Console" },
	{ Id = "CyberY2K", DisplayName = "Cyber Y2K" },
	{ Id = "CandyCircuit", DisplayName = "Candy Circuit" },
	{ Id = "BubbleTea", DisplayName = "Bubble Tea" },
	{ Id = "PopArt", DisplayName = "Pop Art" },
	{ Id = "NeonGrid", DisplayName = "Neon Grid" },
	{ Id = "AcidPulse", DisplayName = "Acid Pulse" },
	{ Id = "SolarFlare", DisplayName = "Solar Flare" },
	{ Id = "BlueReactor", DisplayName = "Blue Reactor" },
	{ Id = "Ultraviolet", DisplayName = "Ultraviolet" },
	{ Id = "AutumnOrchard", DisplayName = "Autumn Orchard" },
	{ Id = "BambooInk", DisplayName = "Bamboo Ink" },
	{ Id = "MahoganyStudy", DisplayName = "Mahogany Study" },
	{ Id = "PaintedWorkshop", DisplayName = "Painted Workshop" },
	{ Id = "NordicCabin", DisplayName = "Nordic Cabin" },
	{ Id = "Boardwalk", DisplayName = "Boardwalk" },
	{ Id = "Driftwood", DisplayName = "Driftwood" },
	{ Id = "PirateMap", DisplayName = "Pirate Map" },
	{ Id = "MarbleNoir", DisplayName = "Marble Noir" },
	{ Id = "VerdeMarble", DisplayName = "Verde Marble" },
	{ Id = "RoseMarble", DisplayName = "Rose Marble" },
	{ Id = "ImperialMarble", DisplayName = "Imperial Marble" },
	{ Id = "BlackBeach", DisplayName = "Black Beach" },
	{ Id = "ObsidianGold", DisplayName = "Obsidian Gold" },
	{ Id = "Stormfront", DisplayName = "Stormfront" },
	{ Id = "Monsoon", DisplayName = "Monsoon" },
	{ Id = "Inkstone", DisplayName = "Inkstone" },
	{ Id = "CrateredEmber", DisplayName = "Cratered Ember" },
	{ Id = "ArcaneMagma", DisplayName = "Arcane Magma" },
	{ Id = "ToxicCore", DisplayName = "Toxic Core" },
	{ Id = "ConcreteMinimal", DisplayName = "Concrete Minimal" },
	{ Id = "BrutalistSignal", DisplayName = "Brutalist Signal" },
	{ Id = "GraffitiWall", DisplayName = "Graffiti Wall" },
	{ Id = "Cathedral", DisplayName = "Cathedral" },
	{ Id = "FossilBed", DisplayName = "Fossil Bed" },
	{ Id = "IvoryGarden", DisplayName = "Ivory Garden" },
	{ Id = "LunarGranite", DisplayName = "Lunar Granite" },
	{ Id = "GraniteRose", DisplayName = "Granite Rose" },
	{ Id = "SpeckledTerrazzo", DisplayName = "Speckled Terrazzo" },
	{ Id = "MetroPlatform", DisplayName = "Metro Platform" },
	{ Id = "RainyAlley", DisplayName = "Rainy Alley" },
	{ Id = "ChalkCourt", DisplayName = "Chalk Court" },
	{ Id = "BrickGarden", DisplayName = "Brick Garden" },
	{ Id = "PaintedBrick", DisplayName = "Painted Brick" },
	{ Id = "MidnightBrick", DisplayName = "Midnight Brick" },
	{ Id = "RiverStones", DisplayName = "River Stones" },
	{ Id = "ZenPebble", DisplayName = "Zen Pebble" },
	{ Id = "CandyPebbles", DisplayName = "Candy Pebbles" },
	{ Id = "OldHarbor", DisplayName = "Old Harbor" },
	{ Id = "MossTemple", DisplayName = "Moss Temple" },
	{ Id = "WinterSquare", DisplayName = "Winter Square" },
	{ Id = "CrystalCave", DisplayName = "Crystal Cave" },
	{ Id = "CavernMoss", DisplayName = "Cavern Moss" },
	{ Id = "DesertGeode", DisplayName = "Desert Geode" },
	{ Id = "RedMesa", DisplayName = "Red Mesa" },
	{ Id = "Sunstone", DisplayName = "Sunstone" },
	{ Id = "CanyonTwilight", DisplayName = "Canyon Twilight" },
	{ Id = "RustBloom", DisplayName = "Rust Bloom" },
	{ Id = "Shipwreck", DisplayName = "Shipwreck" },
	{ Id = "JunkyardNeon", DisplayName = "Junkyard Neon" },
	{ Id = "IndustrialHazard", DisplayName = "Industrial Hazard" },
	{ Id = "MechaWhite", DisplayName = "Mecha White" },
	{ Id = "DesertRig", DisplayName = "Desert Rig" },
	{ Id = "Mercury", DisplayName = "Mercury" },
	{ Id = "RoseFoil", DisplayName = "Rose Foil" },
	{ Id = "OilSlick", DisplayName = "Oil Slick" },
	{ Id = "BrassObservatory", DisplayName = "Brass Observatory" },
	{ Id = "CopperPatina", DisplayName = "Copper Patina" },
	{ Id = "GunmetalOrange", DisplayName = "Gunmetal Orange" },
	{ Id = "ChromePop", DisplayName = "Chrome Pop" },
	{ Id = "OrbitalLab", DisplayName = "Orbital Lab" },
	{ Id = "AlpineMeadow", DisplayName = "Alpine Meadow" },
	{ Id = "MeadowPicnic", DisplayName = "Meadow Picnic" },
	{ Id = "BiolumGrove", DisplayName = "Biolum Grove" },
	{ Id = "RainforestFruit", DisplayName = "Rainforest Fruit" },
	{ Id = "EnchantedFoliage", DisplayName = "Enchanted Foliage" },
	{ Id = "AutumnCanopy", DisplayName = "Autumn Canopy" },
	{ Id = "DesertMirage", DisplayName = "Desert Mirage" },
	{ Id = "MoonSand", DisplayName = "Moon Sand" },
	{ Id = "CoralDunes", DisplayName = "Coral Dunes" },
	{ Id = "RoyalVelvet", DisplayName = "Royal Velvet" },
	{ Id = "Tartan", DisplayName = "Tartan" },
	{ Id = "SunflowerDenim", DisplayName = "Sunflower Denim" },
	{ Id = "KimonoNight", DisplayName = "Kimono Night" },
	{ Id = "PolarNight", DisplayName = "Polar Night" },
	{ Id = "Snowberry", DisplayName = "Snowberry" },
	{ Id = "AlpineSunrise", DisplayName = "Alpine Sunrise" },
	{ Id = "MuddyBoots", DisplayName = "Muddy Boots" },
	{ Id = "ClaySwamp", DisplayName = "Clay Swamp" },
	{ Id = "Petrichor", DisplayName = "Petrichor" },
	{ Id = "TundraGround", DisplayName = "Tundra Ground" },
	{ Id = "CityCrosswalk", DisplayName = "City Crosswalk" },
	{ Id = "SunsetBoulevard", DisplayName = "Sunset Boulevard" },
	{ Id = "SaltFlats", DisplayName = "Salt Flats" },
	{ Id = "HimalayanSalt", DisplayName = "Himalayan Salt" },
	{ Id = "Frostfire", DisplayName = "Frostfire" },
	{ Id = "BlackIce", DisplayName = "Black Ice" },
	{ Id = "GlacierVein", DisplayName = "Glacier Vein" },
	{ Id = "AncientIce", DisplayName = "Ancient Ice" },
	{ Id = "SeaGlass", DisplayName = "Sea Glass" },
	{ Id = "StainedGlass", DisplayName = "Stained Glass" },
	{ Id = "SunsetGlass", DisplayName = "Sunset Glass" },
	{ Id = "SmokedGlass", DisplayName = "Smoked Glass" },
	{ Id = "HolographicPearl", DisplayName = "Holographic Pearl" },
	{ Id = "SpectralError", DisplayName = "Spectral Error" },
	{ Id = "PaperToy", DisplayName = "Paper Toy" },
	{ Id = "Newspaper", DisplayName = "Newspaper" },
	{ Id = "DesertRug", DisplayName = "Desert Rug" },
	{ Id = "ArcadeCarpet", DisplayName = "Arcade Carpet" },
	{ Id = "MediterraneanTiles", DisplayName = "Mediterranean Tiles" },
	{ Id = "Kintsugi", DisplayName = "Kintsugi" },
	{ Id = "TuscanRoof", DisplayName = "Tuscan Roof" },
	{ Id = "FestivalRoof", DisplayName = "Festival Roof" },
	{ Id = "RooftopRain", DisplayName = "Rooftop Rain" },
	{ Id = "GingerbreadRoof", DisplayName = "Gingerbread Roof" },
	{ Id = "Leatherbound", DisplayName = "Leatherbound" },
	{ Id = "RacingLeather", DisplayName = "Racing Leather" },
	{ Id = "ChalkStucco", DisplayName = "Chalk Stucco" },
	{ Id = "ArtDecoPlaster", DisplayName = "Art Deco Plaster" },
	{ Id = "RubberDuck", DisplayName = "Rubber Duck" },
	{ Id = "StealthRubber", DisplayName = "Stealth Rubber" },
} :: { CatalogEntry }

-- ReplicatedStorage.Assets.VFX.LaunchTrails children (Studio-authored, not
-- Rojo-mounted -- MergeService.Start reads them the same way it already
-- reads the default). Id == the Model's Name.
CosmeticsCatalog.SquishyTrails = {
	{ Id = "DefaultLaunchTrail", DisplayName = "Default" },
	{ Id = "SlimeLaunchTrail", DisplayName = "Slime" },
	{ Id = "CoolLaunchTrail", DisplayName = "Cool" },
	{ Id = "RedAndBlackLaunchTrail", DisplayName = "Red & Black" },
	{ Id = "XLaunchTrail", DisplayName = "X" },
	{ Id = "WaterDropLaunchTrail", DisplayName = "Water Drop" },
} :: { CatalogEntry }

local keycapThemeIds: { [string]: true } = {}
for _, entry in CosmeticsCatalog.KeycapThemes do
	keycapThemeIds[entry.Id] = true
end

local squishyTrailIds: { [string]: true } = {}
for _, entry in CosmeticsCatalog.SquishyTrails do
	squishyTrailIds[entry.Id] = true
end

function CosmeticsCatalog.isKeycapTheme(id: string): boolean
	return keycapThemeIds[id] == true
end

function CosmeticsCatalog.isSquishyTrail(id: string): boolean
	return squishyTrailIds[id] == true
end

return CosmeticsCatalog
