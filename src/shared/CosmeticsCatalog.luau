--!strict
--[[
	Single id authority for owned cosmetics (COSMETICS_PLAN.md). Three slots
	today -- keycap Themes, squishy launch Beams, and Merge Pops -- each an
	ordered list of {Id, DisplayName}. Future shop bundles grant ids through
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

export type Slot = "KeycapThemes" | "SquishyBeams" | "MergePops"

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
CosmeticsCatalog.DEFAULT_SQUISHY_BEAM_ID = MergeConfig.DEFAULT_LAUNCH_BEAM_MODEL_NAME
CosmeticsCatalog.DEFAULT_MERGE_POP_ID = MergeConfig.MERGE_VFX_TEMPLATE_NAME

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

-- ReplicatedStorage.Assets.VFX.LaunchBeams children (Studio-authored, not
-- Rojo-mounted -- MergeService.Start reads them the same way it already
-- reads the default). Id == the Model's Name.
CosmeticsCatalog.SquishyBeams = {
	{ Id = "FallingBeams", DisplayName = "Default" },
	{ Id = "01_Ember", DisplayName = "Ember" },
	{ Id = "02_Sunset", DisplayName = "Sunset" },
	{ Id = "03_Aurora", DisplayName = "Aurora" },
	{ Id = "04_Ocean", DisplayName = "Ocean" },
	{ Id = "05_Arcane", DisplayName = "Arcane" },
	{ Id = "06_Prism", DisplayName = "Prism" },
	{ Id = "07_Toxic", DisplayName = "Toxic" },
	{ Id = "08_Void", DisplayName = "Void Rift" },
	{ Id = "09_BloodMoon", DisplayName = "Blood Moon" },
	{ Id = "10_Celestial", DisplayName = "Celestial Gold" },
	{ Id = "11_RoseGold", DisplayName = "Rose Gold" },
	{ Id = "12_Icefire", DisplayName = "Icefire" },
	{ Id = "13_Emerald", DisplayName = "Emerald" },
	{ Id = "14_CottonCandy", DisplayName = "Cotton Candy" },
	{ Id = "15_SolarFlare", DisplayName = "Solar Flare" },
	{ Id = "16_Thunderstorm", DisplayName = "Thunderstorm" },
	{ Id = "17_Monochrome", DisplayName = "Monochrome" },
	{ Id = "18_Holographic", DisplayName = "Holographic" },
	{ Id = "19_ObsidianLava", DisplayName = "Obsidian Lava" },
	{ Id = "20_Nuclear", DisplayName = "Nuclear" },
	{ Id = "21_RoyalFortune", DisplayName = "Royal Fortune" },
	{ Id = "22_Frostbite", DisplayName = "Frostbite" },
	{ Id = "23_CherryBlossom", DisplayName = "Cherry Blossom" },
	{ Id = "24_Sandstorm", DisplayName = "Sandstorm" },
	{ Id = "25_CoralReef", DisplayName = "Coral Reef" },
	{ Id = "26_Cyberpunk", DisplayName = "Cyberpunk" },
	{ Id = "27_Haunted", DisplayName = "Haunted" },
	{ Id = "28_Amethyst", DisplayName = "Amethyst" },
	{ Id = "29_Ruby", DisplayName = "Ruby" },
	{ Id = "30_Sapphire", DisplayName = "Sapphire" },
} :: { CatalogEntry }

-- ReplicatedStorage.Assets.VFX.Merge children. The 30 gradient ids intentionally
-- mirror SquishyBeams, because both authored studies use the same named
-- palettes; only the unequip/default template differs.
local mergePops: { CatalogEntry } = {
	{ Id = CosmeticsCatalog.DEFAULT_MERGE_POP_ID, DisplayName = "Default" },
}
for index = 2, #CosmeticsCatalog.SquishyBeams do
	local entry = CosmeticsCatalog.SquishyBeams[index]
	table.insert(mergePops, { Id = entry.Id, DisplayName = entry.DisplayName })
end
CosmeticsCatalog.MergePops = mergePops

local keycapThemeIds: { [string]: true } = {}
for _, entry in CosmeticsCatalog.KeycapThemes do
	keycapThemeIds[entry.Id] = true
end

local squishyBeamIds: { [string]: true } = {}
for _, entry in CosmeticsCatalog.SquishyBeams do
	squishyBeamIds[entry.Id] = true
end

local mergePopIds: { [string]: true } = {}
for _, entry in CosmeticsCatalog.MergePops do
	mergePopIds[entry.Id] = true
end

function CosmeticsCatalog.isKeycapTheme(id: string): boolean
	return keycapThemeIds[id] == true
end

function CosmeticsCatalog.isSquishyBeam(id: string): boolean
	return squishyBeamIds[id] == true
end

function CosmeticsCatalog.isMergePop(id: string): boolean
	return mergePopIds[id] == true
end

-- Boot-time guard: the defaults are unequip targets (COSMETICS_PLAN.md
-- "Decisions") and must always resolve to a real catalog entry. The squishy
-- default is sourced from MergeConfig, owned elsewhere, so it can drift out
-- of sync silently without this.
assert(
	CosmeticsCatalog.isKeycapTheme(CosmeticsCatalog.DEFAULT_KEYCAP_THEME_ID),
	"default keycap theme id missing from KeycapThemes catalog"
)
assert(
	CosmeticsCatalog.isSquishyBeam(CosmeticsCatalog.DEFAULT_SQUISHY_BEAM_ID),
	"default beam id missing from SquishyBeams catalog"
)
assert(
	CosmeticsCatalog.isMergePop(CosmeticsCatalog.DEFAULT_MERGE_POP_ID),
	"default merge pop id missing from MergePops catalog"
)

return CosmeticsCatalog
