--!strict
--[[
	Client-side keyboard interaction for every MeshPart tagged `Key`.

	Each key receives a random letter plus the color and material configured by
	the theme named in its `Theme` attribute. A missing or invalid Theme is
	normalized to ChocolateBar. Attribute changes are observed so themes can be
	swapped while the game is running.

	Each key's base part (key.Parent.Parent, the BasePart under KeyCaps) is
	also tinted with the theme's Colors[1] (the anchor/darkest color) by
	reading the same `Theme` attribute CosmeticsService stamps on the base --
	this side is read-only on the client, since the server is the attribute's
	only writer. Bases are tracked separately from keys so a base with many
	keys gets exactly one attribute connection, torn down and its original
	color restored once its last key is untagged.

	Press detection follows the local player's HumanoidRootPart every frame. All
	motion, UI, color selection, and audio are local-only. Sounds are created per
	press and destroyed after playback, so keys need no child Sound instances and
	overlapping presses never cut each other off.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local CosmeticsCatalog = require(ReplicatedStorage.Shared.CosmeticsCatalog)
local Images = require(ReplicatedStorage.Shared.AssetIds.Images)
local Log = require(ReplicatedStorage.Shared.Log)
local Sounds = require(ReplicatedStorage.Shared.AssetIds.Sounds)

local log = Log.new("LightUpKeysController")

local KEY_TAG = CosmeticsCatalog.KEY_TAG
local THEME_ATTRIBUTE = CosmeticsCatalog.THEME_ATTRIBUTE
local DEFAULT_THEME = CosmeticsCatalog.DEFAULT_KEYCAP_THEME_ID

local KEY_GUI_NAME = "KeyGui"
local LETTER_LABEL_NAME = "LetterLabel"
local LETTER_STROKE_NAME = "LetterStroke"

local SOUND_NAME = "ClickSound"
local SOUND_ID = `rbxassetid://{Sounds.KeyPress}`
local SOUND_VOLUME = 0.75
local SOUND_GROUP_NAME = "Keyboard"
local SOUND_LOAD_TIMEOUT = 3
local PLAYBACK_SPEED_MIN = 1
local PLAYBACK_SPEED_MAX = 1.2

local DROP_DISTANCE = 1.4
local HORIZONTAL_MARGIN = 1
local HEIGHT_ABOVE_KEY = 6
local HEIGHT_BELOW_KEY = 2
local KEY_QUERY_SIZE = Vector3.new(HORIZONTAL_MARGIN * 2, HEIGHT_ABOVE_KEY + HEIGHT_BELOW_KEY, HORIZONTAL_MARGIN * 2)
local KEY_QUERY_OFFSET = Vector3.new(0, (HEIGHT_BELOW_KEY - HEIGHT_ABOVE_KEY) / 2, 0)

local PRESS_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

type KeyTheme = {
	Colors: { Color3 },
	Material: Enum.Material,
}

local THEMES: { [string]: KeyTheme } = {

	ChocolateBar = {
		Colors = {
			Color3.fromRGB(54, 31, 23),
			Color3.fromRGB(84, 46, 30),
			Color3.fromRGB(119, 67, 42),
			Color3.fromRGB(159, 96, 60),
			Color3.fromRGB(202, 139, 91),
		},
		Material = Enum.Material.Plastic,
	},
	--// SYNTHETIC / CLEAN

	-- SmoothPlastic
	SakuraLacquer = {
		Colors = {
			Color3.fromRGB(38, 25, 45),
			Color3.fromRGB(93, 45, 72),
			Color3.fromRGB(180, 84, 123),
			Color3.fromRGB(244, 151, 181),
			Color3.fromRGB(255, 226, 232),
		},
		Material = Enum.Material.SmoothPlastic,
	},

	Bauhaus = {
		Colors = {
			Color3.fromRGB(24, 24, 23),
			Color3.fromRGB(239, 234, 216),
			Color3.fromRGB(209, 48, 47),
			Color3.fromRGB(39, 93, 173),
			Color3.fromRGB(240, 190, 45),
		},
		Material = Enum.Material.SmoothPlastic,
	},

	NordicDusk = {
		Colors = {
			Color3.fromRGB(42, 52, 61),
			Color3.fromRGB(83, 107, 124),
			Color3.fromRGB(199, 116, 78),
			Color3.fromRGB(216, 169, 75),
			Color3.fromRGB(235, 226, 205),
		},
		Material = Enum.Material.SmoothPlastic,
	},

	MatchaInk = {
		Colors = {
			Color3.fromRGB(16, 24, 20),
			Color3.fromRGB(53, 94, 63),
			Color3.fromRGB(127, 155, 91),
			Color3.fromRGB(231, 226, 195),
			Color3.fromRGB(91, 48, 68),
		},
		Material = Enum.Material.SmoothPlastic,
	},

	MoonRabbit = {
		Colors = {
			Color3.fromRGB(22, 28, 57),
			Color3.fromRGB(53, 68, 111),
			Color3.fromRGB(166, 197, 224),
			Color3.fromRGB(246, 241, 222),
			Color3.fromRGB(229, 148, 166),
		},
		Material = Enum.Material.SmoothPlastic,
	},

	SorbetSplit = {
		Colors = {
			Color3.fromRGB(250, 106, 104),
			Color3.fromRGB(255, 170, 116),
			Color3.fromRGB(248, 225, 159),
			Color3.fromRGB(124, 210, 184),
			Color3.fromRGB(183, 155, 226),
		},
		Material = Enum.Material.SmoothPlastic,
	},

	BlackCherry = {
		Colors = {
			Color3.fromRGB(20, 16, 20),
			Color3.fromRGB(61, 21, 34),
			Color3.fromRGB(122, 30, 54),
			Color3.fromRGB(203, 61, 91),
			Color3.fromRGB(244, 175, 185),
		},
		Material = Enum.Material.SmoothPlastic,
	},

	Solarized = {
		Colors = {
			Color3.fromRGB(15, 42, 51),
			Color3.fromRGB(25, 80, 88),
			Color3.fromRGB(42, 137, 137),
			Color3.fromRGB(225, 178, 55),
			Color3.fromRGB(231, 97, 47),
		},
		Material = Enum.Material.SmoothPlastic,
	},

	-- Plastic
	ToyBlocks = {
		Colors = {
			Color3.fromRGB(222, 45, 55),
			Color3.fromRGB(247, 169, 31),
			Color3.fromRGB(248, 219, 63),
			Color3.fromRGB(38, 154, 92),
			Color3.fromRGB(36, 112, 200),
			Color3.fromRGB(111, 56, 177),
		},
		Material = Enum.Material.Plastic,
	},

	RetroConsole = {
		Colors = {
			Color3.fromRGB(49, 47, 40),
			Color3.fromRGB(99, 89, 67),
			Color3.fromRGB(178, 151, 103),
			Color3.fromRGB(216, 178, 111),
			Color3.fromRGB(191, 84, 50),
		},
		Material = Enum.Material.Plastic,
	},

	CyberY2K = {
		Colors = {
			Color3.fromRGB(91, 101, 122),
			Color3.fromRGB(145, 157, 184),
			Color3.fromRGB(184, 170, 226),
			Color3.fromRGB(108, 213, 226),
			Color3.fromRGB(242, 157, 205),
		},
		Material = Enum.Material.Plastic,
	},

	CandyCircuit = {
		Colors = {
			Color3.fromRGB(37, 20, 48),
			Color3.fromRGB(255, 70, 143),
			Color3.fromRGB(255, 183, 91),
			Color3.fromRGB(75, 220, 185),
			Color3.fromRGB(142, 116, 225),
			Color3.fromRGB(242, 228, 91),
		},
		Material = Enum.Material.Plastic,
	},

	BubbleTea = {
		Colors = {
			Color3.fromRGB(37, 30, 29),
			Color3.fromRGB(141, 88, 56),
			Color3.fromRGB(225, 180, 121),
			Color3.fromRGB(179, 148, 196),
			Color3.fromRGB(120, 155, 96),
			Color3.fromRGB(245, 221, 183),
		},
		Material = Enum.Material.Plastic,
	},

	PopArt = {
		Colors = {
			Color3.fromRGB(22, 22, 24),
			Color3.fromRGB(245, 242, 226),
			Color3.fromRGB(235, 43, 126),
			Color3.fromRGB(0, 166, 210),
			Color3.fromRGB(249, 205, 41),
		},
		Material = Enum.Material.Plastic,
	},

	--// EMISSIVE / NEON

	-- Neon
	NeonGrid = {
		Colors = {
			Color3.fromRGB(20, 10, 46),
			Color3.fromRGB(77, 17, 133),
			Color3.fromRGB(207, 25, 215),
			Color3.fromRGB(255, 43, 144),
			Color3.fromRGB(0, 220, 245),
		},
		Material = Enum.Material.Neon,
	},

	AcidPulse = {
		Colors = {
			Color3.fromRGB(15, 18, 13),
			Color3.fromRGB(45, 28, 65),
			Color3.fromRGB(105, 39, 150),
			Color3.fromRGB(158, 238, 34),
			Color3.fromRGB(231, 255, 72),
		},
		Material = Enum.Material.Neon,
	},

	SolarFlare = {
		Colors = {
			Color3.fromRGB(89, 30, 3),
			Color3.fromRGB(177, 65, 2),
			Color3.fromRGB(242, 126, 9),
			Color3.fromRGB(255, 190, 37),
			Color3.fromRGB(255, 235, 112),
			Color3.fromRGB(247, 255, 223),
		},
		Material = Enum.Material.Neon,
	},

	BlueReactor = {
		Colors = {
			Color3.fromRGB(6, 19, 48),
			Color3.fromRGB(9, 55, 118),
			Color3.fromRGB(13, 123, 205),
			Color3.fromRGB(31, 211, 246),
			Color3.fromRGB(188, 249, 255),
		},
		Material = Enum.Material.Neon,
	},

	Ultraviolet = {
		Colors = {
			Color3.fromRGB(12, 8, 20),
			Color3.fromRGB(38, 15, 71),
			Color3.fromRGB(76, 25, 137),
			Color3.fromRGB(129, 42, 211),
			Color3.fromRGB(208, 157, 255),
		},
		Material = Enum.Material.Neon,
	},

	--// WOOD / HANDCRAFTED

	-- Wood
	AutumnOrchard = {
		Colors = {
			Color3.fromRGB(45, 60, 34),
			Color3.fromRGB(88, 115, 46),
			Color3.fromRGB(177, 41, 45),
			Color3.fromRGB(224, 97, 36),
			Color3.fromRGB(240, 176, 54),
			Color3.fromRGB(237, 219, 169),
		},
		Material = Enum.Material.Wood,
	},

	BambooInk = {
		Colors = {
			Color3.fromRGB(27, 31, 25),
			Color3.fromRGB(54, 72, 42),
			Color3.fromRGB(91, 113, 55),
			Color3.fromRGB(151, 158, 87),
			Color3.fromRGB(221, 211, 151),
		},
		Material = Enum.Material.Wood,
	},

	MahoganyStudy = {
		Colors = {
			Color3.fromRGB(46, 24, 21),
			Color3.fromRGB(80, 34, 29),
			Color3.fromRGB(119, 47, 39),
			Color3.fromRGB(164, 91, 55),
			Color3.fromRGB(197, 150, 83),
			Color3.fromRGB(230, 205, 158),
		},
		Material = Enum.Material.Wood,
	},

	PaintedWorkshop = {
		Colors = {
			Color3.fromRGB(38, 34, 31),
			Color3.fromRGB(36, 102, 105),
			Color3.fromRGB(45, 82, 151),
			Color3.fromRGB(207, 149, 49),
			Color3.fromRGB(190, 70, 49),
			Color3.fromRGB(235, 218, 178),
		},
		Material = Enum.Material.Wood,
	},

	-- WoodPlanks
	NordicCabin = {
		Colors = {
			Color3.fromRGB(39, 52, 43),
			Color3.fromRGB(77, 95, 65),
			Color3.fromRGB(194, 54, 51),
			Color3.fromRGB(228, 221, 198),
			Color3.fromRGB(133, 174, 197),
		},
		Material = Enum.Material.WoodPlanks,
	},

	Boardwalk = {
		Colors = {
			Color3.fromRGB(75, 58, 46),
			Color3.fromRGB(137, 99, 66),
			Color3.fromRGB(42, 113, 144),
			Color3.fromRGB(88, 181, 190),
			Color3.fromRGB(237, 121, 91),
			Color3.fromRGB(245, 196, 79),
		},
		Material = Enum.Material.WoodPlanks,
	},

	Driftwood = {
		Colors = {
			Color3.fromRGB(60, 62, 66),
			Color3.fromRGB(95, 92, 90),
			Color3.fromRGB(142, 128, 111),
			Color3.fromRGB(93, 141, 151),
			Color3.fromRGB(199, 128, 105),
			Color3.fromRGB(226, 214, 185),
		},
		Material = Enum.Material.WoodPlanks,
	},

	PirateMap = {
		Colors = {
			Color3.fromRGB(33, 25, 21),
			Color3.fromRGB(76, 47, 29),
			Color3.fromRGB(151, 106, 58),
			Color3.fromRGB(229, 201, 139),
			Color3.fromRGB(140, 43, 39),
			Color3.fromRGB(35, 66, 78),
		},
		Material = Enum.Material.WoodPlanks,
	},

	--// STONE / MINERAL

	-- Marble
	MarbleNoir = {
		Colors = {
			Color3.fromRGB(12, 14, 18),
			Color3.fromRGB(38, 42, 49),
			Color3.fromRGB(103, 112, 124),
			Color3.fromRGB(221, 226, 226),
			Color3.fromRGB(34, 84, 166),
		},
		Material = Enum.Material.Marble,
	},

	VerdeMarble = {
		Colors = {
			Color3.fromRGB(17, 43, 37),
			Color3.fromRGB(28, 78, 61),
			Color3.fromRGB(47, 125, 86),
			Color3.fromRGB(225, 229, 211),
			Color3.fromRGB(188, 148, 68),
		},
		Material = Enum.Material.Marble,
	},

	RoseMarble = {
		Colors = {
			Color3.fromRGB(43, 30, 35),
			Color3.fromRGB(91, 43, 53),
			Color3.fromRGB(151, 78, 88),
			Color3.fromRGB(205, 145, 147),
			Color3.fromRGB(229, 222, 211),
			Color3.fromRGB(119, 119, 123),
		},
		Material = Enum.Material.Marble,
	},

	ImperialMarble = {
		Colors = {
			Color3.fromRGB(28, 20, 39),
			Color3.fromRGB(70, 42, 94),
			Color3.fromRGB(121, 70, 143),
			Color3.fromRGB(222, 210, 225),
			Color3.fromRGB(217, 177, 74),
		},
		Material = Enum.Material.Marble,
	},

	-- Basalt
	BlackBeach = {
		Colors = {
			Color3.fromRGB(13, 16, 18),
			Color3.fromRGB(32, 38, 40),
			Color3.fromRGB(65, 72, 72),
			Color3.fromRGB(73, 132, 126),
			Color3.fromRGB(180, 92, 62),
		},
		Material = Enum.Material.Basalt,
	},

	ObsidianGold = {
		Colors = {
			Color3.fromRGB(10, 9, 13),
			Color3.fromRGB(27, 21, 34),
			Color3.fromRGB(54, 36, 61),
			Color3.fromRGB(132, 88, 44),
			Color3.fromRGB(220, 173, 65),
		},
		Material = Enum.Material.Basalt,
	},

	-- Slate
	Stormfront = {
		Colors = {
			Color3.fromRGB(27, 31, 39),
			Color3.fromRGB(50, 61, 75),
			Color3.fromRGB(83, 101, 120),
			Color3.fromRGB(152, 165, 175),
			Color3.fromRGB(241, 203, 66),
		},
		Material = Enum.Material.Slate,
	},

	Monsoon = {
		Colors = {
			Color3.fromRGB(21, 39, 44),
			Color3.fromRGB(35, 72, 78),
			Color3.fromRGB(50, 108, 111),
			Color3.fromRGB(86, 133, 115),
			Color3.fromRGB(183, 194, 181),
			Color3.fromRGB(204, 146, 65),
		},
		Material = Enum.Material.Slate,
	},

	Inkstone = {
		Colors = {
			Color3.fromRGB(15, 18, 23),
			Color3.fromRGB(29, 40, 57),
			Color3.fromRGB(62, 75, 91),
			Color3.fromRGB(195, 194, 183),
			Color3.fromRGB(188, 52, 46),
		},
		Material = Enum.Material.Slate,
	},

	-- CrackedLava
	CrateredEmber = {
		Colors = {
			Color3.fromRGB(19, 14, 13),
			Color3.fromRGB(58, 19, 14),
			Color3.fromRGB(116, 26, 12),
			Color3.fromRGB(205, 54, 11),
			Color3.fromRGB(255, 137, 24),
			Color3.fromRGB(255, 210, 79),
		},
		Material = Enum.Material.CrackedLava,
	},

	ArcaneMagma = {
		Colors = {
			Color3.fromRGB(21, 12, 27),
			Color3.fromRGB(55, 21, 72),
			Color3.fromRGB(116, 31, 129),
			Color3.fromRGB(202, 47, 154),
			Color3.fromRGB(248, 91, 78),
			Color3.fromRGB(255, 173, 65),
		},
		Material = Enum.Material.CrackedLava,
	},

	ToxicCore = {
		Colors = {
			Color3.fromRGB(20, 24, 13),
			Color3.fromRGB(46, 60, 17),
			Color3.fromRGB(86, 111, 19),
			Color3.fromRGB(151, 187, 29),
			Color3.fromRGB(220, 244, 53),
		},
		Material = Enum.Material.CrackedLava,
	},

	-- Concrete
	ConcreteMinimal = {
		Colors = {
			Color3.fromRGB(42, 43, 45),
			Color3.fromRGB(82, 84, 85),
			Color3.fromRGB(126, 127, 124),
			Color3.fromRGB(185, 183, 175),
			Color3.fromRGB(231, 226, 213),
		},
		Material = Enum.Material.Concrete,
	},

	BrutalistSignal = {
		Colors = {
			Color3.fromRGB(31, 33, 37),
			Color3.fromRGB(78, 82, 86),
			Color3.fromRGB(140, 144, 143),
			Color3.fromRGB(224, 224, 214),
			Color3.fromRGB(38, 73, 160),
			Color3.fromRGB(226, 186, 39),
		},
		Material = Enum.Material.Concrete,
	},

	GraffitiWall = {
		Colors = {
			Color3.fromRGB(50, 52, 55),
			Color3.fromRGB(101, 103, 104),
			Color3.fromRGB(13, 181, 170),
			Color3.fromRGB(229, 50, 138),
			Color3.fromRGB(242, 185, 44),
			Color3.fromRGB(24, 24, 27),
		},
		Material = Enum.Material.Concrete,
	},

	-- Limestone
	Cathedral = {
		Colors = {
			Color3.fromRGB(63, 64, 62),
			Color3.fromRGB(113, 110, 101),
			Color3.fromRGB(224, 214, 185),
			Color3.fromRGB(244, 235, 207),
			Color3.fromRGB(72, 104, 139),
			Color3.fromRGB(166, 39, 47),
			Color3.fromRGB(196, 151, 58),
		},
		Material = Enum.Material.Limestone,
	},

	FossilBed = {
		Colors = {
			Color3.fromRGB(58, 49, 39),
			Color3.fromRGB(101, 82, 58),
			Color3.fromRGB(148, 117, 76),
			Color3.fromRGB(196, 159, 103),
			Color3.fromRGB(230, 205, 155),
			Color3.fromRGB(93, 83, 68),
		},
		Material = Enum.Material.Limestone,
	},

	IvoryGarden = {
		Colors = {
			Color3.fromRGB(224, 216, 193),
			Color3.fromRGB(185, 190, 151),
			Color3.fromRGB(113, 139, 101),
			Color3.fromRGB(193, 135, 128),
			Color3.fromRGB(139, 145, 146),
		},
		Material = Enum.Material.Limestone,
	},

	-- Granite
	LunarGranite = {
		Colors = {
			Color3.fromRGB(33, 34, 47),
			Color3.fromRGB(64, 63, 82),
			Color3.fromRGB(96, 91, 111),
			Color3.fromRGB(123, 143, 169),
			Color3.fromRGB(185, 195, 202),
			Color3.fromRGB(211, 183, 117),
		},
		Material = Enum.Material.Granite,
	},

	GraniteRose = {
		Colors = {
			Color3.fromRGB(43, 42, 45),
			Color3.fromRGB(95, 82, 86),
			Color3.fromRGB(173, 104, 111),
			Color3.fromRGB(146, 150, 126),
			Color3.fromRGB(217, 196, 170),
		},
		Material = Enum.Material.Granite,
	},

	SpeckledTerrazzo = {
		Colors = {
			Color3.fromRGB(60, 59, 57),
			Color3.fromRGB(112, 107, 98),
			Color3.fromRGB(207, 101, 83),
			Color3.fromRGB(61, 139, 137),
			Color3.fromRGB(212, 164, 58),
			Color3.fromRGB(228, 222, 205),
		},
		Material = Enum.Material.Granite,
	},

	--// URBAN / MASONRY

	-- Pavement
	MetroPlatform = {
		Colors = {
			Color3.fromRGB(42, 45, 47),
			Color3.fromRGB(79, 84, 84),
			Color3.fromRGB(128, 132, 127),
			Color3.fromRGB(219, 216, 199),
			Color3.fromRGB(48, 126, 93),
			Color3.fromRGB(225, 124, 36),
		},
		Material = Enum.Material.Pavement,
	},

	RainyAlley = {
		Colors = {
			Color3.fromRGB(21, 25, 33),
			Color3.fromRGB(39, 49, 65),
			Color3.fromRGB(55, 80, 111),
			Color3.fromRGB(78, 56, 111),
			Color3.fromRGB(197, 47, 141),
			Color3.fromRGB(35, 181, 204),
		},
		Material = Enum.Material.Pavement,
	},

	ChalkCourt = {
		Colors = {
			Color3.fromRGB(74, 78, 77),
			Color3.fromRGB(128, 131, 125),
			Color3.fromRGB(230, 228, 212),
			Color3.fromRGB(82, 154, 193),
			Color3.fromRGB(221, 101, 78),
			Color3.fromRGB(217, 170, 54),
		},
		Material = Enum.Material.Pavement,
	},

	-- Brick
	BrickGarden = {
		Colors = {
			Color3.fromRGB(73, 36, 31),
			Color3.fromRGB(120, 50, 39),
			Color3.fromRGB(171, 71, 49),
			Color3.fromRGB(49, 84, 51),
			Color3.fromRGB(104, 123, 68),
			Color3.fromRGB(225, 204, 168),
		},
		Material = Enum.Material.Brick,
	},

	PaintedBrick = {
		Colors = {
			Color3.fromRGB(28, 50, 68),
			Color3.fromRGB(55, 126, 133),
			Color3.fromRGB(220, 105, 78),
			Color3.fromRGB(238, 199, 91),
			Color3.fromRGB(230, 226, 207),
		},
		Material = Enum.Material.Brick,
	},

	MidnightBrick = {
		Colors = {
			Color3.fromRGB(22, 20, 23),
			Color3.fromRGB(55, 28, 37),
			Color3.fromRGB(99, 34, 54),
			Color3.fromRGB(88, 48, 93),
			Color3.fromRGB(178, 100, 57),
			Color3.fromRGB(126, 126, 131),
		},
		Material = Enum.Material.Brick,
	},

	-- Pebble
	RiverStones = {
		Colors = {
			Color3.fromRGB(43, 52, 57),
			Color3.fromRGB(72, 88, 94),
			Color3.fromRGB(96, 119, 116),
			Color3.fromRGB(111, 126, 92),
			Color3.fromRGB(151, 141, 119),
			Color3.fromRGB(211, 204, 181),
		},
		Material = Enum.Material.Pebble,
	},

	ZenPebble = {
		Colors = {
			Color3.fromRGB(16, 17, 16),
			Color3.fromRGB(236, 232, 218),
			Color3.fromRGB(177, 151, 105),
			Color3.fromRGB(150, 38, 36),
			Color3.fromRGB(70, 104, 62),
		},
		Material = Enum.Material.Pebble,
	},

	CandyPebbles = {
		Colors = {
			Color3.fromRGB(244, 173, 185),
			Color3.fromRGB(251, 211, 142),
			Color3.fromRGB(167, 217, 176),
			Color3.fromRGB(151, 194, 231),
			Color3.fromRGB(196, 173, 224),
			Color3.fromRGB(236, 229, 211),
		},
		Material = Enum.Material.Pebble,
	},

	-- Cobblestone
	OldHarbor = {
		Colors = {
			Color3.fromRGB(49, 53, 56),
			Color3.fromRGB(82, 88, 89),
			Color3.fromRGB(42, 66, 91),
			Color3.fromRGB(61, 111, 105),
			Color3.fromRGB(150, 76, 50),
			Color3.fromRGB(180, 187, 181),
		},
		Material = Enum.Material.Cobblestone,
	},

	MossTemple = {
		Colors = {
			Color3.fromRGB(42, 47, 38),
			Color3.fromRGB(66, 74, 51),
			Color3.fromRGB(93, 107, 59),
			Color3.fromRGB(135, 134, 75),
			Color3.fromRGB(177, 153, 92),
			Color3.fromRGB(209, 199, 162),
		},
		Material = Enum.Material.Cobblestone,
	},

	WinterSquare = {
		Colors = {
			Color3.fromRGB(55, 60, 65),
			Color3.fromRGB(93, 104, 111),
			Color3.fromRGB(158, 184, 198),
			Color3.fromRGB(223, 230, 226),
			Color3.fromRGB(119, 43, 55),
			Color3.fromRGB(43, 75, 57),
		},
		Material = Enum.Material.Cobblestone,
	},

	-- Rock
	CrystalCave = {
		Colors = {
			Color3.fromRGB(23, 24, 35),
			Color3.fromRGB(48, 51, 73),
			Color3.fromRGB(26, 157, 183),
			Color3.fromRGB(91, 94, 203),
			Color3.fromRGB(171, 65, 190),
			Color3.fromRGB(222, 225, 247),
		},
		Material = Enum.Material.Rock,
	},

	CavernMoss = {
		Colors = {
			Color3.fromRGB(26, 28, 26),
			Color3.fromRGB(52, 55, 45),
			Color3.fromRGB(96, 80, 45),
			Color3.fromRGB(169, 116, 48),
			Color3.fromRGB(217, 164, 76),
			Color3.fromRGB(182, 194, 141),
		},
		Material = Enum.Material.Rock,
	},

	DesertGeode = {
		Colors = {
			Color3.fromRGB(55, 41, 35),
			Color3.fromRGB(98, 70, 50),
			Color3.fromRGB(161, 106, 66),
			Color3.fromRGB(53, 151, 154),
			Color3.fromRGB(118, 74, 157),
			Color3.fromRGB(226, 205, 170),
		},
		Material = Enum.Material.Rock,
	},

	-- Sandstone
	RedMesa = {
		Colors = {
			Color3.fromRGB(91, 45, 33),
			Color3.fromRGB(144, 63, 41),
			Color3.fromRGB(194, 88, 52),
			Color3.fromRGB(227, 136, 82),
			Color3.fromRGB(54, 139, 145),
			Color3.fromRGB(238, 211, 170),
		},
		Material = Enum.Material.Sandstone,
	},

	Sunstone = {
		Colors = {
			Color3.fromRGB(92, 57, 23),
			Color3.fromRGB(144, 84, 25),
			Color3.fromRGB(202, 125, 29),
			Color3.fromRGB(236, 173, 47),
			Color3.fromRGB(248, 220, 117),
		},
		Material = Enum.Material.Sandstone,
	},

	CanyonTwilight = {
		Colors = {
			Color3.fromRGB(59, 47, 63),
			Color3.fromRGB(99, 66, 86),
			Color3.fromRGB(156, 92, 100),
			Color3.fromRGB(211, 132, 116),
			Color3.fromRGB(238, 180, 143),
			Color3.fromRGB(45, 50, 80),
		},
		Material = Enum.Material.Sandstone,
	},

	--// METAL / INDUSTRIAL

	-- CorrodedMetal
	RustBloom = {
		Colors = {
			Color3.fromRGB(44, 31, 29),
			Color3.fromRGB(102, 45, 38),
			Color3.fromRGB(172, 66, 52),
			Color3.fromRGB(224, 111, 90),
			Color3.fromRGB(196, 147, 157),
			Color3.fromRGB(229, 204, 166),
		},
		Material = Enum.Material.CorrodedMetal,
	},

	Shipwreck = {
		Colors = {
			Color3.fromRGB(36, 31, 28),
			Color3.fromRGB(68, 50, 38),
			Color3.fromRGB(102, 82, 60),
			Color3.fromRGB(38, 92, 89),
			Color3.fromRGB(62, 132, 142),
			Color3.fromRGB(160, 148, 111),
		},
		Material = Enum.Material.CorrodedMetal,
	},

	JunkyardNeon = {
		Colors = {
			Color3.fromRGB(31, 31, 32),
			Color3.fromRGB(73, 61, 54),
			Color3.fromRGB(133, 77, 48),
			Color3.fromRGB(160, 218, 47),
			Color3.fromRGB(226, 48, 142),
			Color3.fromRGB(48, 127, 199),
		},
		Material = Enum.Material.CorrodedMetal,
	},

	-- DiamondPlate
	IndustrialHazard = {
		Colors = {
			Color3.fromRGB(24, 25, 26),
			Color3.fromRGB(65, 68, 69),
			Color3.fromRGB(119, 124, 124),
			Color3.fromRGB(230, 181, 40),
			Color3.fromRGB(247, 215, 74),
			Color3.fromRGB(232, 229, 211),
		},
		Material = Enum.Material.DiamondPlate,
	},

	MechaWhite = {
		Colors = {
			Color3.fromRGB(29, 31, 35),
			Color3.fromRGB(90, 97, 105),
			Color3.fromRGB(181, 188, 191),
			Color3.fromRGB(238, 239, 232),
			Color3.fromRGB(205, 48, 45),
			Color3.fromRGB(45, 104, 190),
		},
		Material = Enum.Material.DiamondPlate,
	},

	DesertRig = {
		Colors = {
			Color3.fromRGB(31, 33, 30),
			Color3.fromRGB(78, 75, 54),
			Color3.fromRGB(130, 118, 75),
			Color3.fromRGB(212, 190, 137),
			Color3.fromRGB(42, 105, 117),
			Color3.fromRGB(180, 55, 43),
		},
		Material = Enum.Material.DiamondPlate,
	},

	-- Foil
	Mercury = {
		Colors = {
			Color3.fromRGB(27, 32, 39),
			Color3.fromRGB(61, 76, 87),
			Color3.fromRGB(96, 122, 132),
			Color3.fromRGB(137, 166, 164),
			Color3.fromRGB(97, 145, 163),
			Color3.fromRGB(215, 226, 225),
			Color3.fromRGB(160, 149, 188),
		},
		Material = Enum.Material.Foil,
	},

	RoseFoil = {
		Colors = {
			Color3.fromRGB(55, 32, 47),
			Color3.fromRGB(104, 55, 69),
			Color3.fromRGB(164, 91, 91),
			Color3.fromRGB(216, 144, 120),
			Color3.fromRGB(239, 197, 163),
			Color3.fromRGB(222, 219, 213),
		},
		Material = Enum.Material.Foil,
	},

	OilSlick = {
		Colors = {
			Color3.fromRGB(15, 17, 23),
			Color3.fromRGB(25, 55, 65),
			Color3.fromRGB(35, 95, 91),
			Color3.fromRGB(68, 68, 125),
			Color3.fromRGB(119, 55, 132),
			Color3.fromRGB(174, 133, 49),
		},
		Material = Enum.Material.Foil,
	},

	-- Metal
	BrassObservatory = {
		Colors = {
			Color3.fromRGB(21, 28, 45),
			Color3.fromRGB(44, 58, 79),
			Color3.fromRGB(103, 82, 41),
			Color3.fromRGB(169, 126, 47),
			Color3.fromRGB(221, 184, 87),
			Color3.fromRGB(226, 218, 190),
		},
		Material = Enum.Material.Metal,
	},

	CopperPatina = {
		Colors = {
			Color3.fromRGB(53, 31, 25),
			Color3.fromRGB(107, 56, 37),
			Color3.fromRGB(172, 91, 52),
			Color3.fromRGB(36, 105, 98),
			Color3.fromRGB(70, 153, 133),
			Color3.fromRGB(221, 202, 159),
		},
		Material = Enum.Material.Metal,
	},

	GunmetalOrange = {
		Colors = {
			Color3.fromRGB(23, 25, 29),
			Color3.fromRGB(56, 61, 68),
			Color3.fromRGB(100, 107, 113),
			Color3.fromRGB(221, 93, 27),
			Color3.fromRGB(246, 156, 55),
			Color3.fromRGB(226, 226, 218),
		},
		Material = Enum.Material.Metal,
	},

	ChromePop = {
		Colors = {
			Color3.fromRGB(27, 30, 35),
			Color3.fromRGB(92, 103, 112),
			Color3.fromRGB(201, 210, 213),
			Color3.fromRGB(116, 224, 57),
			Color3.fromRGB(84, 63, 201),
			Color3.fromRGB(230, 56, 157),
		},
		Material = Enum.Material.Metal,
	},

	OrbitalLab = {
		Colors = {
			Color3.fromRGB(18, 24, 34),
			Color3.fromRGB(50, 65, 83),
			Color3.fromRGB(98, 118, 139),
			Color3.fromRGB(204, 214, 220),
			Color3.fromRGB(44, 181, 207),
			Color3.fromRGB(116, 91, 190),
		},
		Material = Enum.Material.Metal,
	},

	--// NATURE / TERRAIN

	-- Grass
	AlpineMeadow = {
		Colors = {
			Color3.fromRGB(37, 93, 52),
			Color3.fromRGB(64, 139, 67),
			Color3.fromRGB(115, 178, 84),
			Color3.fromRGB(105, 180, 218),
			Color3.fromRGB(241, 202, 66),
			Color3.fromRGB(219, 223, 212),
		},
		Material = Enum.Material.Grass,
	},

	MeadowPicnic = {
		Colors = {
			Color3.fromRGB(38, 84, 50),
			Color3.fromRGB(183, 43, 48),
			Color3.fromRGB(232, 220, 190),
			Color3.fromRGB(37, 59, 89),
			Color3.fromRGB(225, 172, 42),
		},
		Material = Enum.Material.Grass,
	},

	BiolumGrove = {
		Colors = {
			Color3.fromRGB(13, 39, 36),
			Color3.fromRGB(18, 76, 60),
			Color3.fromRGB(25, 119, 83),
			Color3.fromRGB(33, 178, 145),
			Color3.fromRGB(67, 194, 219),
			Color3.fromRGB(126, 72, 173),
		},
		Material = Enum.Material.Grass,
	},

	-- LeafyGrass
	RainforestFruit = {
		Colors = {
			Color3.fromRGB(18, 65, 43),
			Color3.fromRGB(30, 109, 62),
			Color3.fromRGB(62, 155, 80),
			Color3.fromRGB(225, 54, 116),
			Color3.fromRGB(244, 148, 48),
			Color3.fromRGB(241, 201, 57),
		},
		Material = Enum.Material.LeafyGrass,
	},

	EnchantedFoliage = {
		Colors = {
			Color3.fromRGB(17, 44, 35),
			Color3.fromRGB(32, 77, 52),
			Color3.fromRGB(70, 119, 75),
			Color3.fromRGB(93, 67, 139),
			Color3.fromRGB(174, 176, 196),
			Color3.fromRGB(214, 191, 111),
		},
		Material = Enum.Material.LeafyGrass,
	},

	AutumnCanopy = {
		Colors = {
			Color3.fromRGB(68, 69, 34),
			Color3.fromRGB(111, 101, 42),
			Color3.fromRGB(169, 127, 43),
			Color3.fromRGB(208, 92, 38),
			Color3.fromRGB(133, 45, 43),
			Color3.fromRGB(212, 178, 112),
		},
		Material = Enum.Material.LeafyGrass,
	},

	-- Sand
	DesertMirage = {
		Colors = {
			Color3.fromRGB(148, 104, 58),
			Color3.fromRGB(200, 151, 83),
			Color3.fromRGB(233, 199, 137),
			Color3.fromRGB(52, 153, 157),
			Color3.fromRGB(126, 81, 155),
			Color3.fromRGB(226, 113, 91),
		},
		Material = Enum.Material.Sand,
	},

	MoonSand = {
		Colors = {
			Color3.fromRGB(45, 43, 58),
			Color3.fromRGB(76, 69, 91),
			Color3.fromRGB(112, 98, 133),
			Color3.fromRGB(132, 151, 190),
			Color3.fromRGB(179, 188, 211),
			Color3.fromRGB(213, 208, 219),
		},
		Material = Enum.Material.Sand,
	},

	CoralDunes = {
		Colors = {
			Color3.fromRGB(112, 68, 50),
			Color3.fromRGB(179, 103, 72),
			Color3.fromRGB(230, 148, 107),
			Color3.fromRGB(245, 193, 145),
			Color3.fromRGB(44, 139, 151),
			Color3.fromRGB(235, 228, 205),
		},
		Material = Enum.Material.Sand,
	},

	-- Fabric
	RoyalVelvet = {
		Colors = {
			Color3.fromRGB(19, 14, 20),
			Color3.fromRGB(55, 17, 35),
			Color3.fromRGB(104, 25, 49),
			Color3.fromRGB(161, 50, 78),
			Color3.fromRGB(206, 164, 66),
			Color3.fromRGB(232, 214, 181),
		},
		Material = Enum.Material.Fabric,
	},

	Tartan = {
		Colors = {
			Color3.fromRGB(27, 54, 42),
			Color3.fromRGB(52, 82, 55),
			Color3.fromRGB(115, 35, 41),
			Color3.fromRGB(31, 46, 70),
			Color3.fromRGB(188, 151, 78),
			Color3.fromRGB(219, 205, 170),
		},
		Material = Enum.Material.Fabric,
	},

	SunflowerDenim = {
		Colors = {
			Color3.fromRGB(29, 54, 83),
			Color3.fromRGB(49, 87, 126),
			Color3.fromRGB(83, 133, 170),
			Color3.fromRGB(221, 174, 37),
			Color3.fromRGB(243, 213, 92),
			Color3.fromRGB(232, 222, 195),
		},
		Material = Enum.Material.Fabric,
	},

	KimonoNight = {
		Colors = {
			Color3.fromRGB(21, 29, 63),
			Color3.fromRGB(40, 55, 102),
			Color3.fromRGB(228, 218, 192),
			Color3.fromRGB(218, 133, 158),
			Color3.fromRGB(50, 124, 119),
			Color3.fromRGB(191, 150, 57),
		},
		Material = Enum.Material.Fabric,
	},

	-- Snow
	PolarNight = {
		Colors = {
			Color3.fromRGB(16, 25, 49),
			Color3.fromRGB(35, 54, 87),
			Color3.fromRGB(219, 239, 242),
			Color3.fromRGB(83, 199, 152),
			Color3.fromRGB(121, 92, 191),
			Color3.fromRGB(166, 205, 226),
		},
		Material = Enum.Material.Snow,
	},

	Snowberry = {
		Colors = {
			Color3.fromRGB(236, 247, 248),
			Color3.fromRGB(191, 220, 231),
			Color3.fromRGB(129, 166, 185),
			Color3.fromRGB(178, 38, 54),
			Color3.fromRGB(43, 91, 61),
			Color3.fromRGB(235, 167, 178),
		},
		Material = Enum.Material.Snow,
	},

	AlpineSunrise = {
		Colors = {
			Color3.fromRGB(241, 248, 248),
			Color3.fromRGB(190, 217, 231),
			Color3.fromRGB(146, 157, 199),
			Color3.fromRGB(226, 151, 148),
			Color3.fromRGB(242, 189, 120),
			Color3.fromRGB(246, 221, 166),
		},
		Material = Enum.Material.Snow,
	},

	-- Mud
	MuddyBoots = {
		Colors = {
			Color3.fromRGB(48, 39, 31),
			Color3.fromRGB(82, 61, 43),
			Color3.fromRGB(123, 85, 52),
			Color3.fromRGB(99, 101, 55),
			Color3.fromRGB(185, 102, 49),
			Color3.fromRGB(207, 164, 105),
		},
		Material = Enum.Material.Mud,
	},

	ClaySwamp = {
		Colors = {
			Color3.fromRGB(54, 54, 43),
			Color3.fromRGB(85, 83, 59),
			Color3.fromRGB(112, 107, 77),
			Color3.fromRGB(114, 88, 91),
			Color3.fromRGB(153, 139, 112),
			Color3.fromRGB(202, 192, 158),
		},
		Material = Enum.Material.Mud,
	},

	-- Ground
	Petrichor = {
		Colors = {
			Color3.fromRGB(45, 40, 34),
			Color3.fromRGB(77, 67, 52),
			Color3.fromRGB(83, 99, 68),
			Color3.fromRGB(74, 96, 108),
			Color3.fromRGB(130, 145, 145),
			Color3.fromRGB(208, 199, 177),
		},
		Material = Enum.Material.Ground,
	},

	TundraGround = {
		Colors = {
			Color3.fromRGB(40, 41, 49),
			Color3.fromRGB(70, 67, 80),
			Color3.fromRGB(103, 113, 92),
			Color3.fromRGB(111, 143, 174),
			Color3.fromRGB(177, 197, 213),
			Color3.fromRGB(229, 231, 225),
		},
		Material = Enum.Material.Ground,
	},

	--// WEATHER / COLD / TRANSLUCENT

	-- Asphalt
	CityCrosswalk = {
		Colors = {
			Color3.fromRGB(19, 21, 23),
			Color3.fromRGB(51, 55, 58),
			Color3.fromRGB(92, 96, 96),
			Color3.fromRGB(231, 230, 218),
			Color3.fromRGB(236, 187, 35),
			Color3.fromRGB(191, 45, 45),
		},
		Material = Enum.Material.Asphalt,
	},

	SunsetBoulevard = {
		Colors = {
			Color3.fromRGB(25, 25, 32),
			Color3.fromRGB(54, 45, 68),
			Color3.fromRGB(107, 49, 101),
			Color3.fromRGB(211, 61, 125),
			Color3.fromRGB(238, 112, 54),
			Color3.fromRGB(244, 190, 49),
		},
		Material = Enum.Material.Asphalt,
	},

	-- Salt
	SaltFlats = {
		Colors = {
			Color3.fromRGB(118, 126, 133),
			Color3.fromRGB(169, 179, 183),
			Color3.fromRGB(205, 216, 218),
			Color3.fromRGB(239, 241, 235),
			Color3.fromRGB(215, 179, 181),
			Color3.fromRGB(62, 66, 73),
		},
		Material = Enum.Material.Salt,
	},

	HimalayanSalt = {
		Colors = {
			Color3.fromRGB(125, 67, 71),
			Color3.fromRGB(177, 96, 94),
			Color3.fromRGB(218, 132, 118),
			Color3.fromRGB(241, 177, 149),
			Color3.fromRGB(251, 218, 191),
		},
		Material = Enum.Material.Salt,
	},

	-- Ice
	Frostfire = {
		Colors = {
			Color3.fromRGB(22, 67, 94),
			Color3.fromRGB(51, 123, 151),
			Color3.fromRGB(104, 190, 208),
			Color3.fromRGB(205, 237, 240),
			Color3.fromRGB(239, 120, 48),
			Color3.fromRGB(205, 48, 36),
		},
		Material = Enum.Material.Ice,
	},

	BlackIce = {
		Colors = {
			Color3.fromRGB(5, 10, 18),
			Color3.fromRGB(15, 31, 56),
			Color3.fromRGB(22, 65, 110),
			Color3.fromRGB(21, 134, 177),
			Color3.fromRGB(93, 221, 239),
			Color3.fromRGB(234, 252, 255),
		},
		Material = Enum.Material.Ice,
	},

	-- Glacier
	GlacierVein = {
		Colors = {
			Color3.fromRGB(48, 83, 102),
			Color3.fromRGB(80, 129, 151),
			Color3.fromRGB(128, 180, 198),
			Color3.fromRGB(187, 220, 228),
			Color3.fromRGB(231, 244, 245),
			Color3.fromRGB(31, 63, 75),
		},
		Material = Enum.Material.Glacier,
	},

	AncientIce = {
		Colors = {
			Color3.fromRGB(45, 54, 55),
			Color3.fromRGB(80, 89, 84),
			Color3.fromRGB(119, 117, 92),
			Color3.fromRGB(161, 140, 92),
			Color3.fromRGB(193, 211, 204),
			Color3.fromRGB(232, 237, 225),
		},
		Material = Enum.Material.Glacier,
	},

	-- Glass
	SeaGlass = {
		Colors = {
			Color3.fromRGB(38, 103, 106),
			Color3.fromRGB(59, 151, 142),
			Color3.fromRGB(111, 199, 176),
			Color3.fromRGB(177, 226, 205),
			Color3.fromRGB(211, 164, 86),
			Color3.fromRGB(233, 238, 219),
		},
		Material = Enum.Material.Glass,
	},

	StainedGlass = {
		Colors = {
			Color3.fromRGB(107, 24, 48),
			Color3.fromRGB(36, 78, 155),
			Color3.fromRGB(26, 131, 92),
			Color3.fromRGB(218, 154, 34),
			Color3.fromRGB(116, 55, 157),
			Color3.fromRGB(28, 28, 36),
		},
		Material = Enum.Material.Glass,
	},

	SunsetGlass = {
		Colors = {
			Color3.fromRGB(62, 40, 87),
			Color3.fromRGB(108, 46, 125),
			Color3.fromRGB(200, 55, 126),
			Color3.fromRGB(240, 105, 82),
			Color3.fromRGB(244, 168, 67),
			Color3.fromRGB(38, 64, 111),
		},
		Material = Enum.Material.Glass,
	},

	SmokedGlass = {
		Colors = {
			Color3.fromRGB(17, 20, 24),
			Color3.fromRGB(42, 48, 55),
			Color3.fromRGB(77, 87, 94),
			Color3.fromRGB(127, 123, 112),
			Color3.fromRGB(171, 128, 78),
			Color3.fromRGB(194, 211, 215),
		},
		Material = Enum.Material.Glass,
	},

	-- ForceField
	HolographicPearl = {
		Colors = {
			Color3.fromRGB(118, 217, 228),
			Color3.fromRGB(152, 235, 213),
			Color3.fromRGB(191, 207, 246),
			Color3.fromRGB(226, 177, 239),
			Color3.fromRGB(247, 221, 233),
			Color3.fromRGB(239, 248, 246),
		},
		Material = Enum.Material.ForceField,
	},

	SpectralError = {
		Colors = {
			Color3.fromRGB(16, 18, 24),
			Color3.fromRGB(32, 228, 148),
			Color3.fromRGB(32, 180, 227),
			Color3.fromRGB(231, 48, 159),
			Color3.fromRGB(151, 64, 226),
			Color3.fromRGB(241, 244, 237),
		},
		Material = Enum.Material.ForceField,
	},

	--// SOFT / PAPER / ARCHITECTURAL

	-- Cardboard
	PaperToy = {
		Colors = {
			Color3.fromRGB(89, 65, 45),
			Color3.fromRGB(146, 104, 67),
			Color3.fromRGB(210, 166, 103),
			Color3.fromRGB(218, 53, 48),
			Color3.fromRGB(40, 115, 185),
			Color3.fromRGB(234, 199, 58),
		},
		Material = Enum.Material.Cardboard,
	},

	Newspaper = {
		Colors = {
			Color3.fromRGB(30, 31, 32),
			Color3.fromRGB(87, 88, 87),
			Color3.fromRGB(154, 153, 147),
			Color3.fromRGB(225, 220, 205),
			Color3.fromRGB(152, 48, 42),
			Color3.fromRGB(183, 150, 96),
		},
		Material = Enum.Material.Cardboard,
	},

	-- Carpet
	DesertRug = {
		Colors = {
			Color3.fromRGB(49, 31, 34),
			Color3.fromRGB(103, 39, 49),
			Color3.fromRGB(32, 51, 76),
			Color3.fromRGB(194, 139, 44),
			Color3.fromRGB(225, 199, 145),
			Color3.fromRGB(91, 70, 47),
		},
		Material = Enum.Material.Carpet,
	},

	ArcadeCarpet = {
		Colors = {
			Color3.fromRGB(26, 23, 55),
			Color3.fromRGB(61, 37, 101),
			Color3.fromRGB(130, 53, 150),
			Color3.fromRGB(227, 48, 147),
			Color3.fromRGB(43, 186, 206),
			Color3.fromRGB(239, 190, 48),
		},
		Material = Enum.Material.Carpet,
	},

	-- CeramicTiles
	MediterraneanTiles = {
		Colors = {
			Color3.fromRGB(24, 65, 128),
			Color3.fromRGB(46, 112, 174),
			Color3.fromRGB(224, 230, 218),
			Color3.fromRGB(203, 85, 57),
			Color3.fromRGB(66, 157, 144),
			Color3.fromRGB(231, 185, 59),
		},
		Material = Enum.Material.CeramicTiles,
	},

	Kintsugi = {
		Colors = {
			Color3.fromRGB(22, 22, 24),
			Color3.fromRGB(63, 60, 58),
			Color3.fromRGB(230, 223, 205),
			Color3.fromRGB(190, 145, 52),
			Color3.fromRGB(123, 39, 49),
		},
		Material = Enum.Material.CeramicTiles,
	},

	-- ClayRoofTiles
	TuscanRoof = {
		Colors = {
			Color3.fromRGB(103, 54, 35),
			Color3.fromRGB(161, 77, 45),
			Color3.fromRGB(211, 111, 61),
			Color3.fromRGB(130, 126, 62),
			Color3.fromRGB(224, 207, 167),
			Color3.fromRGB(100, 155, 185),
		},
		Material = Enum.Material.ClayRoofTiles,
	},

	FestivalRoof = {
		Colors = {
			Color3.fromRGB(111, 43, 39),
			Color3.fromRGB(194, 66, 50),
			Color3.fromRGB(227, 119, 58),
			Color3.fromRGB(38, 149, 148),
			Color3.fromRGB(231, 187, 46),
			Color3.fromRGB(182, 65, 133),
		},
		Material = Enum.Material.ClayRoofTiles,
	},

	-- RoofShingles
	RooftopRain = {
		Colors = {
			Color3.fromRGB(30, 34, 38),
			Color3.fromRGB(54, 63, 71),
			Color3.fromRGB(83, 101, 110),
			Color3.fromRGB(67, 93, 75),
			Color3.fromRGB(136, 159, 167),
			Color3.fromRGB(195, 210, 211),
		},
		Material = Enum.Material.RoofShingles,
	},

	GingerbreadRoof = {
		Colors = {
			Color3.fromRGB(67, 39, 29),
			Color3.fromRGB(118, 63, 38),
			Color3.fromRGB(176, 93, 46),
			Color3.fromRGB(194, 43, 48),
			Color3.fromRGB(43, 99, 58),
			Color3.fromRGB(238, 224, 192),
		},
		Material = Enum.Material.RoofShingles,
	},

	-- Leather
	Leatherbound = {
		Colors = {
			Color3.fromRGB(25, 34, 28),
			Color3.fromRGB(42, 66, 46),
			Color3.fromRGB(91, 27, 38),
			Color3.fromRGB(129, 70, 43),
			Color3.fromRGB(198, 158, 82),
			Color3.fromRGB(230, 210, 169),
		},
		Material = Enum.Material.Leather,
	},

	RacingLeather = {
		Colors = {
			Color3.fromRGB(18, 19, 21),
			Color3.fromRGB(48, 51, 55),
			Color3.fromRGB(104, 107, 108),
			Color3.fromRGB(214, 42, 43),
			Color3.fromRGB(238, 236, 224),
			Color3.fromRGB(191, 128, 69),
		},
		Material = Enum.Material.Leather,
	},

	-- Plaster
	ChalkStucco = {
		Colors = {
			Color3.fromRGB(230, 222, 203),
			Color3.fromRGB(201, 189, 164),
			Color3.fromRGB(188, 102, 75),
			Color3.fromRGB(112, 136, 103),
			Color3.fromRGB(101, 135, 158),
		},
		Material = Enum.Material.Plaster,
	},

	ArtDecoPlaster = {
		Colors = {
			Color3.fromRGB(24, 25, 27),
			Color3.fromRGB(235, 225, 198),
			Color3.fromRGB(36, 102, 87),
			Color3.fromRGB(188, 145, 51),
			Color3.fromRGB(206, 91, 77),
		},
		Material = Enum.Material.Plaster,
	},

	-- Rubber
	RubberDuck = {
		Colors = {
			Color3.fromRGB(25, 30, 35),
			Color3.fromRGB(245, 188, 31),
			Color3.fromRGB(255, 222, 68),
			Color3.fromRGB(235, 111, 34),
			Color3.fromRGB(45, 127, 190),
			Color3.fromRGB(237, 239, 226),
		},
		Material = Enum.Material.Rubber,
	},

	StealthRubber = {
		Colors = {
			Color3.fromRGB(10, 12, 15),
			Color3.fromRGB(29, 33, 38),
			Color3.fromRGB(59, 66, 73),
			Color3.fromRGB(106, 119, 127),
			Color3.fromRGB(173, 224, 51),
			Color3.fromRGB(223, 229, 225),
		},
		Material = Enum.Material.Rubber,
	},
}

local ALPHABET = {
	"A",
	"B",
	"C",
	"D",
	"E",
	"F",
	"G",
	"H",
	"I",
	"J",
	"K",
	"L",
	"M",
	"N",
	"O",
	"P",
	"Q",
	"R",
	"S",
	"T",
	"U",
	"V",
	"W",
	"X",
	"Y",
	"Z",
}

type KeyState = {
	originalCFrame: CFrame,
	originalColor: Color3,
	originalMaterial: Enum.Material,
	createdGui: SurfaceGui?,
	themeConnection: RBXScriptConnection?,
	pressed: boolean,
	currentTween: Tween?,
	basePart: BasePart?,
}

-- Per-base tracker so a base with many keys gets exactly one Theme attribute
-- connection. keyCount is the number of currently-wired keys pointing at this
-- base; the connection is torn down and originalColor restored once it hits
-- zero (the base's last key was untagged/removed).
type BaseState = {
	connection: RBXScriptConnection,
	originalColor: Color3,
	keyCount: number,
}

local player = Players.LocalPlayer
local trackedKeys: { [MeshPart]: KeyState } = {}
local trackedBases: { [BasePart]: BaseState } = {}
local pressedKeys: { [MeshPart]: boolean } = {}
local keysUnderPlayer: { [MeshPart]: boolean } = {}
local normalizingTheme: { [MeshPart]: boolean } = {}
local previousLetter = ""
local excludedCharacter: Model? = nil

local keyOverlapParams = OverlapParams.new()
keyOverlapParams.MaxParts = 0
keyOverlapParams.RespectCanCollide = false

local LightUpKeysController = {}

local function getKeyboardSoundGroup(): SoundGroup
	local existing = SoundService:FindFirstChild(SOUND_GROUP_NAME)
	if existing ~= nil then
		if not existing:IsA("SoundGroup") then
			error(`SoundService.{SOUND_GROUP_NAME} must be a SoundGroup, got {existing.ClassName}`, 0)
		end
		return existing
	end

	local group = Instance.new("SoundGroup")
	group.Name = SOUND_GROUP_NAME
	group.Parent = SoundService
	return group
end

local keyboardSoundGroup = getKeyboardSoundGroup()

local function createLetterGui(key: MeshPart): SurfaceGui?
	if key:FindFirstChild(KEY_GUI_NAME) ~= nil then
		return nil
	end

	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name = KEY_GUI_NAME
	surfaceGui.Face = Enum.NormalId.Top
	surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surfaceGui.PixelsPerStud = 81

	local textLabel = Instance.new("TextLabel")
	textLabel.Name = LETTER_LABEL_NAME
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.GothamBold
	textLabel.TextScaled = true
	textLabel.TextColor3 = Color3.new(0, 0, 0)

	local chosenLetter = ""
	repeat
		chosenLetter = ALPHABET[math.random(1, #ALPHABET)]
	until chosenLetter ~= previousLetter
	previousLetter = chosenLetter
	textLabel.Text = chosenLetter

	local stroke = Instance.new("UIStroke")
	stroke.Name = LETTER_STROKE_NAME
	stroke.StrokeSizingMode = Enum.StrokeSizingMode.ScaledSize
	-- Same 1.5px as before: the label spans the Top face, so its shortest
	-- pixel axis is min(X, Z) studs at the gui's PixelsPerStud.
	stroke.Thickness = 1.5 / (math.min(key.Size.X, key.Size.Z) * surfaceGui.PixelsPerStud)
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = textLabel

	textLabel.Parent = surfaceGui
	surfaceGui.Parent = key

	return surfaceGui
end

local function applyTheme(key: MeshPart)
	local attribute = key:GetAttribute(THEME_ATTRIBUTE)
	local themeName = if typeof(attribute) == "string" and THEMES[attribute] ~= nil then attribute else DEFAULT_THEME

	if attribute ~= themeName then
		if attribute ~= nil then
			log.warn(
				`{key:GetFullName()}.{THEME_ATTRIBUTE} has invalid theme {tostring(attribute)} -- using {DEFAULT_THEME}`
			)
		end

		normalizingTheme[key] = true
		key:SetAttribute(THEME_ATTRIBUTE, themeName)
		normalizingTheme[key] = nil
	end

	local theme = THEMES[themeName]
	if theme == nil then
		log.warn(`default keycap theme "{DEFAULT_THEME}" is not configured -- appearance unchanged`)
		return
	end

	local colors = theme.Colors
	if #colors == 0 then
		log.warn(`keycap theme "{themeName}" has no colors -- appearance unchanged`)
		return
	end

	key.Color = colors[math.random(1, #colors)]
	key.Material = theme.Material
end

-- Same resolution as applyTheme (invalid/missing attribute falls back to
-- DEFAULT_THEME) but read-only: the base's Theme attribute has only one
-- writer, CosmeticsService, so there's no self-triggered signal to guard
-- against and nothing to normalize back onto the instance.
local function applyBaseTheme(basePart: BasePart)
	local attribute = basePart:GetAttribute(THEME_ATTRIBUTE)
	local themeName = if typeof(attribute) == "string" and THEMES[attribute] ~= nil then attribute else DEFAULT_THEME

	local theme = THEMES[themeName]
	if theme == nil then
		log.warn(`default keycap theme "{DEFAULT_THEME}" is not configured -- base appearance unchanged`)
		return
	end

	local colors = theme.Colors
	if #colors == 0 then
		log.warn(`keycap theme "{themeName}" has no colors -- base appearance unchanged`)
		return
	end

	-- THEMES tables are ordered dark-to-light -- index 1 is the theme's
	-- anchor/darkest color, the one used for the base plate tint.
	basePart.Color = colors[1]
end

-- The key's KeyCaps folder isn't always the key's direct parent -- the real
-- Studio-authored tree groups keys under per-pack subfolders, e.g.
-- Base1.KeyCaps.KeyPack.Key, not just Base1.KeyCaps.Key. Walk upward from the
-- key until an ancestor named "KeyCaps" (a Folder) is found, then require
-- that folder's own parent to be the base BasePart. Bounded at nil/workspace
-- so a key tagged somewhere unrelated doesn't walk forever.
local function getBaseFromKey(key: MeshPart): BasePart?
	local ancestor: Instance? = key.Parent
	while ancestor ~= nil and ancestor ~= workspace do
		if ancestor.Name == "KeyCaps" and ancestor:IsA("Folder") then
			local basePart = ancestor.Parent
			if basePart ~= nil and basePart:IsA("BasePart") then
				return basePart
			end
			return nil
		end
		ancestor = ancestor.Parent
	end

	return nil
end

-- Adds one key to `basePart`'s reference count, wiring its Theme connection
-- and applying the current theme the first time any key reaches it.
local function wireBase(basePart: BasePart)
	local state = trackedBases[basePart]
	if state ~= nil then
		state.keyCount += 1
		return
	end

	local newState: BaseState = {
		connection = basePart:GetAttributeChangedSignal(THEME_ATTRIBUTE):Connect(function()
			applyBaseTheme(basePart)
		end),
		originalColor = basePart.Color,
		keyCount = 1,
	}
	trackedBases[basePart] = newState

	applyBaseTheme(basePart)
end

-- Removes one key from `basePart`'s reference count; once the last key is
-- gone, disconnects and restores the base's pre-theme color.
local function unwireBase(basePart: BasePart)
	local state = trackedBases[basePart]
	if state == nil then
		return
	end

	state.keyCount -= 1
	if state.keyCount > 0 then
		return
	end
	trackedBases[basePart] = nil

	state.connection:Disconnect()
	if basePart.Parent ~= nil then
		basePart.Color = state.originalColor
	end
end

-- One transient Sound per press allows rapid or overlapping presses to layer.
-- Ended/Stopped handle the normal path; the timeout also cleans up a SoundId
-- that never loads and therefore never emits either signal.
local function playKeySound(key: MeshPart)
	local sound = Instance.new("Sound")
	sound.Name = SOUND_NAME
	sound.SoundId = SOUND_ID
	sound.Volume = SOUND_VOLUME
	sound.SoundGroup = keyboardSoundGroup
	sound.PlaybackSpeed = math.random(PLAYBACK_SPEED_MIN * 100, PLAYBACK_SPEED_MAX * 100) / 100
	sound.Parent = key

	local destroyed = false
	local function destroySound()
		if destroyed then
			return
		end
		destroyed = true
		sound:Destroy()
	end

	sound.Ended:Once(destroySound)
	sound.Stopped:Once(destroySound)
	task.delay(SOUND_LOAD_TIMEOUT, destroySound)

	sound:Play()
end

local function cancelTween(state: KeyState)
	local tween = state.currentTween
	if tween == nil then
		return
	end

	state.currentTween = nil
	tween:Cancel()
end

local function tweenKey(key: MeshPart, state: KeyState, target: CFrame, info: TweenInfo)
	cancelTween(state)

	local tween = TweenService:Create(key, info, { CFrame = target })
	state.currentTween = tween

	tween.Completed:Once(function()
		if state.currentTween == tween then
			state.currentTween = nil
		end
	end)

	tween:Play()
end

local function pressKey(key: MeshPart, state: KeyState)
	if state.pressed then
		return
	end
	state.pressed = true
	pressedKeys[key] = true

	playKeySound(key)
	tweenKey(key, state, state.originalCFrame * CFrame.new(0, -DROP_DISTANCE, 0), PRESS_INFO)
end

local function releaseKey(key: MeshPart, state: KeyState)
	pressedKeys[key] = nil
	if not state.pressed then
		return
	end
	state.pressed = false

	tweenKey(key, state, state.originalCFrame, RELEASE_INFO)
end

local function isPlayerOnKey(position: Vector3, key: MeshPart): boolean
	local keyPosition = key.Position
	local keySize = key.Size

	return math.abs(position.X - keyPosition.X) <= keySize.X / 2 + HORIZONTAL_MARGIN
		and math.abs(position.Z - keyPosition.Z) <= keySize.Z / 2 + HORIZONTAL_MARGIN
		and position.Y <= keyPosition.Y + HEIGHT_ABOVE_KEY
		and position.Y >= keyPosition.Y - HEIGHT_BELOW_KEY
end

local function wireKey(instance: Instance)
	if not instance:IsA("MeshPart") then
		log.warn(
			`{instance:GetFullName()} is tagged {KEY_TAG} but is a {instance.ClassName} -- only MeshParts are keys`
		)
		return
	end
	if trackedKeys[instance] ~= nil then
		return
	end

	local basePart = getBaseFromKey(instance)

	local state: KeyState = {
		originalCFrame = instance.CFrame,
		originalColor = instance.Color,
		originalMaterial = instance.Material,
		createdGui = nil,
		themeConnection = nil,
		pressed = false,
		currentTween = nil,
		basePart = basePart,
	}
	trackedKeys[instance] = state

	applyTheme(instance)
	state.themeConnection = instance:GetAttributeChangedSignal(THEME_ATTRIBUTE):Connect(function()
		if not normalizingTheme[instance] then
			applyTheme(instance)
		end
	end)
	state.createdGui = createLetterGui(instance)

	if basePart ~= nil then
		wireBase(basePart)
	end
end

local function unwireKey(instance: Instance)
	if not instance:IsA("MeshPart") then
		return
	end

	local state = trackedKeys[instance]
	if state == nil then
		return
	end
	trackedKeys[instance] = nil
	pressedKeys[instance] = nil
	normalizingTheme[instance] = nil

	cancelTween(state)
	if state.themeConnection ~= nil then
		state.themeConnection:Disconnect()
	end
	if instance.Parent ~= nil then
		instance.CFrame = state.originalCFrame
		instance.Color = state.originalColor
		instance.Material = state.originalMaterial
	end

	local createdGui = state.createdGui
	if createdGui ~= nil then
		createdGui:Destroy()
	end

	if state.basePart ~= nil then
		unwireBase(state.basePart)
	end
end

local function updateKeys()
	table.clear(keysUnderPlayer)

	local character = player.Character
	if excludedCharacter ~= character then
		excludedCharacter = character

		local excludedInstances: { Instance } = {}
		if character ~= nil then
			table.insert(excludedInstances, character)
		end
		keyOverlapParams.ExcludeInstances = excludedInstances
	end

	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then
		local queryCFrame = CFrame.new(root.Position + KEY_QUERY_OFFSET)
		local nearbyParts = workspace:GetPartBoundsInBox(queryCFrame, KEY_QUERY_SIZE, keyOverlapParams)

		for _, part in nearbyParts do
			if part:IsA("MeshPart") then
				local state = trackedKeys[part]
				if state ~= nil and isPlayerOnKey(root.Position, part) then
					keysUnderPlayer[part] = true
					pressKey(part, state)
				end
			end
		end
	end

	for key in pressedKeys do
		if not keysUnderPlayer[key] then
			local state = trackedKeys[key]
			if state ~= nil then
				releaseKey(key, state)
			else
				pressedKeys[key] = nil
			end
		end
	end
end

--[[
	The dark-to-light Colors for `id`, or nil if it isn't a configured theme.
	Exposed for CosmeticsController's cosmetics-menu card, which restyles each
	owned theme's card gradient from these same colors (COSMETICS_PLAN.md) --
	Material is a physical-key concern the card has no use for.
]]
function LightUpKeysController.getThemeColors(id: string): { Color3 }?
	local theme = THEMES[id]
	return if theme ~= nil then theme.Colors else nil
end

-- CosmeticsCatalog.KeycapThemes is meant to list every id in THEMES, and
-- nothing else -- warn (don't error) if the two ever diverge, in either
-- direction, so a forgotten catalog entry or a stale one is caught in the
-- output instead of silently shipping.
local function warnCosmeticsCatalogDrift()
	for _, entry in CosmeticsCatalog.KeycapThemes do
		if THEMES[entry.Id] == nil then
			log.warn(`CosmeticsCatalog theme "{entry.Id}" has no entry in THEMES -- it can never render`)
		end
		if Images.ThemeIcons[entry.Id] == nil then
			log.warn(
				`CosmeticsCatalog theme "{entry.Id}" has no Images.ThemeIcons entry -- its card will use the template's default icon`
			)
		end
	end
	for themeName in THEMES do
		if not CosmeticsCatalog.isKeycapTheme(themeName) then
			log.warn(`THEMES theme "{themeName}" is missing from CosmeticsCatalog -- it can never be owned or equipped`)
		end
	end
end

function LightUpKeysController.Init()
	CollectionService:GetInstanceAddedSignal(KEY_TAG):Connect(wireKey)
	CollectionService:GetInstanceRemovedSignal(KEY_TAG):Connect(unwireKey)

	for _, instance in CollectionService:GetTagged(KEY_TAG) do
		wireKey(instance)
	end

	warnCosmeticsCatalogDrift()

	RunService.Heartbeat:Connect(updateKeys)
	log.info(`ready ({#CollectionService:GetTagged(KEY_TAG)} tagged instances)`)
end

return LightUpKeysController
