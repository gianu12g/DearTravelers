--!strict
--[[
	Client-side keyboard interaction for every MeshPart tagged `Key`.

	Each key receives a random letter and a color from the palette named by its
	`Theme` attribute. A missing Theme uses Chocolate; invalid values are left
	unchanged and reported so an authored typo does not silently become another
	theme. Theme is intentionally read only when the key is connected.

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

local Log = require(ReplicatedStorage.Shared.Log)

local log = Log.new("LightUpKeysController")

local KEY_TAG = "Key"
local THEME_ATTRIBUTE = "Theme"
local DEFAULT_THEME = "Chocolate"

local KEY_GUI_NAME = "KeyGui"
local LETTER_LABEL_NAME = "LetterLabel"
local LETTER_STROKE_NAME = "LetterStroke"

local SOUND_NAME = "ClickSound"
local SOUND_ID = "rbxassetid://84953529887338"
local SOUND_VOLUME = 0.75
local SOUND_GROUP_NAME = "Keyboard"
local SOUND_LOAD_TIMEOUT = 3
local PLAYBACK_SPEED_MIN = 1
local PLAYBACK_SPEED_MAX = 1.2

local DROP_DISTANCE = 1.4
local HORIZONTAL_MARGIN = 1
local HEIGHT_ABOVE_KEY = 6
local HEIGHT_BELOW_KEY = 2

local PRESS_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
local RELEASE_INFO = TweenInfo.new(0.18, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

local THEMES: { [string]: { Color3 } } = {
	Ocean = {
		Color3.fromRGB(24, 54, 62),
		Color3.fromRGB(95, 151, 170),
		Color3.fromRGB(45, 95, 110),
		Color3.fromRGB(62, 136, 165),
		Color3.fromRGB(147, 196, 209),
	},

	Candy = {
		Color3.fromRGB(255, 182, 193),
		Color3.fromRGB(255, 105, 180),
		Color3.fromRGB(173, 216, 230),
		Color3.fromRGB(152, 251, 152),
		Color3.fromRGB(221, 160, 221),
		Color3.fromRGB(255, 253, 208),
		Color3.fromRGB(255, 218, 185),
	},

	Chocolate = {
		Color3.fromRGB(62, 39, 35),
		Color3.fromRGB(136, 92, 62),
		Color3.fromRGB(93, 48, 11),
		Color3.fromRGB(77, 39, 0),
		Color3.fromRGB(156, 104, 78),
	},

	Blue = {
		Color3.fromRGB(60, 120, 255),
		Color3.fromRGB(90, 150, 255),
		Color3.fromRGB(120, 180, 255),
		Color3.fromRGB(40, 90, 220),
	},

	Sunset = {
		Color3.fromRGB(242, 196, 71),
		Color3.fromRGB(247, 98, 24),
		Color3.fromRGB(255, 29, 104),
		Color3.fromRGB(177, 0, 101),
		Color3.fromRGB(116, 5, 128),
	},

	Forest = {
		Color3.fromRGB(25, 59, 43),
		Color3.fromRGB(52, 105, 74),
		Color3.fromRGB(87, 145, 91),
		Color3.fromRGB(135, 169, 107),
		Color3.fromRGB(194, 204, 145),
	},

	Jungle = {
		Color3.fromRGB(16, 66, 49),
		Color3.fromRGB(35, 112, 75),
		Color3.fromRGB(73, 160, 105),
		Color3.fromRGB(144, 190, 109),
		Color3.fromRGB(218, 210, 91),
	},

	Autumn = {
		Color3.fromRGB(91, 46, 29),
		Color3.fromRGB(150, 73, 38),
		Color3.fromRGB(202, 103, 49),
		Color3.fromRGB(230, 155, 61),
		Color3.fromRGB(247, 205, 96),
	},

	Winter = {
		Color3.fromRGB(38, 61, 89),
		Color3.fromRGB(73, 104, 140),
		Color3.fromRGB(126, 167, 196),
		Color3.fromRGB(184, 216, 226),
		Color3.fromRGB(231, 244, 246),
	},

	Spring = {
		Color3.fromRGB(255, 186, 214),
		Color3.fromRGB(255, 222, 137),
		Color3.fromRGB(177, 226, 158),
		Color3.fromRGB(151, 214, 231),
		Color3.fromRGB(202, 177, 230),
	},

	Lavender = {
		Color3.fromRGB(67, 52, 94),
		Color3.fromRGB(112, 86, 145),
		Color3.fromRGB(157, 124, 189),
		Color3.fromRGB(196, 168, 219),
		Color3.fromRGB(231, 215, 242),
	},

	Rose = {
		Color3.fromRGB(91, 31, 50),
		Color3.fromRGB(145, 54, 79),
		Color3.fromRGB(194, 79, 105),
		Color3.fromRGB(232, 132, 153),
		Color3.fromRGB(250, 190, 203),
	},

	CherryBlossom = {
		Color3.fromRGB(107, 58, 76),
		Color3.fromRGB(173, 95, 123),
		Color3.fromRGB(224, 143, 166),
		Color3.fromRGB(249, 190, 205),
		Color3.fromRGB(255, 226, 233),
	},

	Mint = {
		Color3.fromRGB(35, 91, 79),
		Color3.fromRGB(67, 143, 122),
		Color3.fromRGB(111, 190, 157),
		Color3.fromRGB(166, 225, 194),
		Color3.fromRGB(220, 248, 230),
	},

	Lemon = {
		Color3.fromRGB(103, 92, 22),
		Color3.fromRGB(166, 146, 32),
		Color3.fromRGB(224, 198, 50),
		Color3.fromRGB(255, 229, 92),
		Color3.fromRGB(255, 247, 173),
	},

	Peach = {
		Color3.fromRGB(139, 70, 56),
		Color3.fromRGB(194, 101, 77),
		Color3.fromRGB(235, 139, 108),
		Color3.fromRGB(255, 183, 148),
		Color3.fromRGB(255, 221, 194),
	},

	Watermelon = {
		Color3.fromRGB(43, 94, 64),
		Color3.fromRGB(74, 145, 91),
		Color3.fromRGB(142, 191, 95),
		Color3.fromRGB(244, 94, 105),
		Color3.fromRGB(255, 155, 151),
	},

	Strawberry = {
		Color3.fromRGB(117, 25, 45),
		Color3.fromRGB(180, 39, 64),
		Color3.fromRGB(232, 70, 91),
		Color3.fromRGB(255, 132, 145),
		Color3.fromRGB(255, 199, 205),
	},

	Blueberry = {
		Color3.fromRGB(38, 36, 88),
		Color3.fromRGB(60, 57, 132),
		Color3.fromRGB(89, 85, 177),
		Color3.fromRGB(130, 126, 211),
		Color3.fromRGB(183, 181, 235),
	},

	Grape = {
		Color3.fromRGB(57, 30, 79),
		Color3.fromRGB(91, 46, 122),
		Color3.fromRGB(134, 66, 165),
		Color3.fromRGB(179, 108, 201),
		Color3.fromRGB(219, 165, 229),
	},

	Vanilla = {
		Color3.fromRGB(126, 108, 72),
		Color3.fromRGB(175, 152, 104),
		Color3.fromRGB(215, 194, 145),
		Color3.fromRGB(241, 225, 181),
		Color3.fromRGB(255, 246, 218),
	},

	CookiesAndCream = {
		Color3.fromRGB(35, 33, 32),
		Color3.fromRGB(73, 69, 66),
		Color3.fromRGB(127, 121, 116),
		Color3.fromRGB(204, 197, 187),
		Color3.fromRGB(244, 239, 226),
	},

	Cyberpunk = {
		Color3.fromRGB(22, 12, 51),
		Color3.fromRGB(79, 20, 158),
		Color3.fromRGB(192, 17, 242),
		Color3.fromRGB(0, 229, 255),
		Color3.fromRGB(255, 46, 151),
	},

	Synthwave = {
		Color3.fromRGB(31, 18, 74),
		Color3.fromRGB(92, 33, 143),
		Color3.fromRGB(201, 45, 184),
		Color3.fromRGB(255, 81, 149),
		Color3.fromRGB(54, 214, 231),
	},

	Arcade = {
		Color3.fromRGB(27, 27, 77),
		Color3.fromRGB(45, 93, 197),
		Color3.fromRGB(0, 210, 255),
		Color3.fromRGB(255, 58, 152),
		Color3.fromRGB(255, 213, 56),
	},

	Matrix = {
		Color3.fromRGB(4, 31, 14),
		Color3.fromRGB(8, 66, 28),
		Color3.fromRGB(14, 111, 46),
		Color3.fromRGB(22, 176, 73),
		Color3.fromRGB(70, 255, 118),
	},

	Fire = {
		Color3.fromRGB(78, 13, 8),
		Color3.fromRGB(145, 25, 9),
		Color3.fromRGB(215, 53, 13),
		Color3.fromRGB(250, 112, 20),
		Color3.fromRGB(255, 196, 46),
	},

	Lava = {
		Color3.fromRGB(35, 20, 20),
		Color3.fromRGB(92, 24, 18),
		Color3.fromRGB(164, 35, 15),
		Color3.fromRGB(231, 67, 14),
		Color3.fromRGB(255, 155, 31),
	},

	Ice = {
		Color3.fromRGB(31, 67, 91),
		Color3.fromRGB(61, 122, 153),
		Color3.fromRGB(107, 177, 203),
		Color3.fromRGB(165, 222, 233),
		Color3.fromRGB(221, 249, 252),
	},

	Storm = {
		Color3.fromRGB(32, 38, 50),
		Color3.fromRGB(57, 67, 83),
		Color3.fromRGB(91, 104, 124),
		Color3.fromRGB(133, 148, 169),
		Color3.fromRGB(188, 201, 215),
	},

	Thunder = {
		Color3.fromRGB(30, 28, 52),
		Color3.fromRGB(61, 57, 94),
		Color3.fromRGB(100, 92, 138),
		Color3.fromRGB(153, 141, 186),
		Color3.fromRGB(255, 224, 84),
	},

	Galaxy = {
		Color3.fromRGB(21, 16, 52),
		Color3.fromRGB(57, 30, 106),
		Color3.fromRGB(104, 48, 151),
		Color3.fromRGB(176, 69, 177),
		Color3.fromRGB(69, 167, 214),
	},

	Aurora = {
		Color3.fromRGB(18, 44, 59),
		Color3.fromRGB(23, 99, 101),
		Color3.fromRGB(39, 170, 137),
		Color3.fromRGB(106, 222, 161),
		Color3.fromRGB(129, 126, 207),
	},

	Moonlight = {
		Color3.fromRGB(30, 37, 59),
		Color3.fromRGB(53, 66, 96),
		Color3.fromRGB(89, 106, 140),
		Color3.fromRGB(146, 161, 190),
		Color3.fromRGB(216, 224, 238),
	},

	Solar = {
		Color3.fromRGB(105, 47, 14),
		Color3.fromRGB(171, 79, 16),
		Color3.fromRGB(229, 126, 22),
		Color3.fromRGB(255, 185, 48),
		Color3.fromRGB(255, 230, 117),
	},

	Desert = {
		Color3.fromRGB(92, 65, 42),
		Color3.fromRGB(143, 100, 60),
		Color3.fromRGB(190, 139, 83),
		Color3.fromRGB(224, 181, 119),
		Color3.fromRGB(244, 220, 169),
	},

	Oasis = {
		Color3.fromRGB(28, 88, 83),
		Color3.fromRGB(46, 138, 123),
		Color3.fromRGB(80, 181, 150),
		Color3.fromRGB(214, 180, 101),
		Color3.fromRGB(244, 220, 154),
	},

	Beach = {
		Color3.fromRGB(36, 111, 130),
		Color3.fromRGB(63, 164, 180),
		Color3.fromRGB(116, 211, 210),
		Color3.fromRGB(239, 205, 136),
		Color3.fromRGB(255, 236, 187),
	},

	CoralReef = {
		Color3.fromRGB(27, 88, 112),
		Color3.fromRGB(45, 155, 170),
		Color3.fromRGB(94, 209, 192),
		Color3.fromRGB(255, 120, 113),
		Color3.fromRGB(255, 184, 145),
	},

	Tropical = {
		Color3.fromRGB(18, 110, 98),
		Color3.fromRGB(49, 178, 137),
		Color3.fromRGB(150, 215, 84),
		Color3.fromRGB(255, 194, 61),
		Color3.fromRGB(246, 89, 91),
	},

	DeepSea = {
		Color3.fromRGB(5, 25, 45),
		Color3.fromRGB(8, 52, 78),
		Color3.fromRGB(12, 88, 115),
		Color3.fromRGB(18, 130, 151),
		Color3.fromRGB(56, 181, 190),
	},

	Pirate = {
		Color3.fromRGB(36, 29, 24),
		Color3.fromRGB(78, 52, 32),
		Color3.fromRGB(129, 84, 42),
		Color3.fromRGB(181, 131, 64),
		Color3.fromRGB(170, 38, 36),
	},

	Royal = {
		Color3.fromRGB(35, 20, 71),
		Color3.fromRGB(66, 38, 117),
		Color3.fromRGB(105, 64, 163),
		Color3.fromRGB(173, 118, 206),
		Color3.fromRGB(232, 191, 75),
	},

	Luxury = {
		Color3.fromRGB(18, 18, 20),
		Color3.fromRGB(48, 45, 43),
		Color3.fromRGB(92, 82, 66),
		Color3.fromRGB(175, 142, 71),
		Color3.fromRGB(231, 200, 121),
	},

	Gold = {
		Color3.fromRGB(95, 66, 17),
		Color3.fromRGB(148, 104, 25),
		Color3.fromRGB(201, 151, 38),
		Color3.fromRGB(238, 194, 73),
		Color3.fromRGB(255, 229, 143),
	},

	Silver = {
		Color3.fromRGB(57, 63, 68),
		Color3.fromRGB(91, 99, 105),
		Color3.fromRGB(133, 143, 149),
		Color3.fromRGB(180, 188, 192),
		Color3.fromRGB(226, 231, 233),
	},

	Obsidian = {
		Color3.fromRGB(13, 13, 17),
		Color3.fromRGB(27, 25, 34),
		Color3.fromRGB(43, 38, 54),
		Color3.fromRGB(66, 55, 79),
		Color3.fromRGB(99, 76, 112),
	},

	Marble = {
		Color3.fromRGB(75, 78, 82),
		Color3.fromRGB(121, 125, 130),
		Color3.fromRGB(169, 173, 177),
		Color3.fromRGB(213, 215, 217),
		Color3.fromRGB(245, 245, 243),
	},

	Monochrome = {
		Color3.fromRGB(24, 24, 24),
		Color3.fromRGB(65, 65, 65),
		Color3.fromRGB(112, 112, 112),
		Color3.fromRGB(174, 174, 174),
		Color3.fromRGB(232, 232, 232),
	},

	BlackAndWhite = {
		Color3.fromRGB(15, 15, 15),
		Color3.fromRGB(55, 55, 55),
		Color3.fromRGB(105, 105, 105),
		Color3.fromRGB(190, 190, 190),
		Color3.fromRGB(245, 245, 245),
	},

	Slate = {
		Color3.fromRGB(37, 43, 50),
		Color3.fromRGB(62, 72, 82),
		Color3.fromRGB(91, 105, 117),
		Color3.fromRGB(132, 147, 158),
		Color3.fromRGB(184, 195, 202),
	},

	CottonCandy = {
		Color3.fromRGB(255, 166, 204),
		Color3.fromRGB(247, 193, 230),
		Color3.fromRGB(188, 190, 255),
		Color3.fromRGB(159, 219, 255),
		Color3.fromRGB(208, 248, 255),
	},

	Bubblegum = {
		Color3.fromRGB(255, 82, 157),
		Color3.fromRGB(255, 128, 190),
		Color3.fromRGB(244, 174, 220),
		Color3.fromRGB(184, 160, 232),
		Color3.fromRGB(128, 203, 237),
	},

	Toybox = {
		Color3.fromRGB(230, 57, 70),
		Color3.fromRGB(255, 183, 3),
		Color3.fromRGB(76, 201, 240),
		Color3.fromRGB(67, 170, 139),
		Color3.fromRGB(131, 56, 236),
	},

	Rainbow = {
		Color3.fromRGB(239, 71, 111),
		Color3.fromRGB(255, 209, 102),
		Color3.fromRGB(6, 214, 160),
		Color3.fromRGB(17, 138, 178),
		Color3.fromRGB(131, 56, 236),
	},

	Retro = {
		Color3.fromRGB(53, 62, 72),
		Color3.fromRGB(216, 91, 67),
		Color3.fromRGB(239, 160, 74),
		Color3.fromRGB(240, 208, 121),
		Color3.fromRGB(74, 156, 147),
	},

	RetroComputer = {
		Color3.fromRGB(34, 39, 35),
		Color3.fromRGB(57, 74, 58),
		Color3.fromRGB(89, 112, 78),
		Color3.fromRGB(141, 157, 101),
		Color3.fromRGB(196, 201, 139),
	},

	Toxic = {
		Color3.fromRGB(22, 35, 15),
		Color3.fromRGB(48, 77, 23),
		Color3.fromRGB(89, 135, 28),
		Color3.fromRGB(154, 205, 50),
		Color3.fromRGB(211, 255, 73),
	},

	Radioactive = {
		Color3.fromRGB(29, 35, 21),
		Color3.fromRGB(61, 76, 30),
		Color3.fromRGB(106, 132, 38),
		Color3.fromRGB(169, 209, 47),
		Color3.fromRGB(225, 255, 68),
	},

	Alien = {
		Color3.fromRGB(25, 21, 43),
		Color3.fromRGB(57, 42, 91),
		Color3.fromRGB(94, 71, 136),
		Color3.fromRGB(75, 191, 125),
		Color3.fromRGB(143, 255, 170),
	},

	Dragon = {
		Color3.fromRGB(45, 25, 24),
		Color3.fromRGB(89, 39, 30),
		Color3.fromRGB(148, 58, 37),
		Color3.fromRGB(207, 96, 45),
		Color3.fromRGB(230, 178, 64),
	},

	Vampire = {
		Color3.fromRGB(18, 15, 22),
		Color3.fromRGB(46, 21, 36),
		Color3.fromRGB(91, 24, 46),
		Color3.fromRGB(150, 31, 54),
		Color3.fromRGB(212, 61, 78),
	},

	Gothic = {
		Color3.fromRGB(18, 17, 21),
		Color3.fromRGB(45, 39, 51),
		Color3.fromRGB(75, 61, 83),
		Color3.fromRGB(108, 78, 108),
		Color3.fromRGB(151, 112, 135),
	},

	Halloween = {
		Color3.fromRGB(30, 24, 35),
		Color3.fromRGB(82, 42, 98),
		Color3.fromRGB(151, 57, 118),
		Color3.fromRGB(239, 103, 34),
		Color3.fromRGB(255, 175, 40),
	},

	Christmas = {
		Color3.fromRGB(27, 79, 56),
		Color3.fromRGB(43, 126, 77),
		Color3.fromRGB(171, 34, 46),
		Color3.fromRGB(222, 64, 67),
		Color3.fromRGB(239, 210, 123),
	},

	Valentine = {
		Color3.fromRGB(105, 27, 54),
		Color3.fromRGB(173, 45, 79),
		Color3.fromRGB(230, 76, 111),
		Color3.fromRGB(255, 139, 162),
		Color3.fromRGB(255, 207, 216),
	},

	Pumpkin = {
		Color3.fromRGB(77, 43, 26),
		Color3.fromRGB(132, 65, 24),
		Color3.fromRGB(195, 93, 25),
		Color3.fromRGB(239, 139, 39),
		Color3.fromRGB(255, 193, 83),
	},

	SakuraNight = {
		Color3.fromRGB(27, 24, 54),
		Color3.fromRGB(55, 44, 91),
		Color3.fromRGB(109, 66, 126),
		Color3.fromRGB(190, 96, 151),
		Color3.fromRGB(245, 162, 191),
	},

	Japan = {
		Color3.fromRGB(37, 35, 38),
		Color3.fromRGB(94, 38, 46),
		Color3.fromRGB(173, 55, 62),
		Color3.fromRGB(235, 112, 115),
		Color3.fromRGB(245, 230, 213),
	},

	Bamboo = {
		Color3.fromRGB(49, 72, 41),
		Color3.fromRGB(85, 112, 61),
		Color3.fromRGB(128, 154, 82),
		Color3.fromRGB(177, 193, 112),
		Color3.fromRGB(218, 220, 157),
	},

	Earth = {
		Color3.fromRGB(65, 49, 37),
		Color3.fromRGB(104, 76, 52),
		Color3.fromRGB(146, 108, 72),
		Color3.fromRGB(176, 145, 94),
		Color3.fromRGB(93, 120, 79),
	},

	Clay = {
		Color3.fromRGB(92, 52, 42),
		Color3.fromRGB(137, 76, 58),
		Color3.fromRGB(181, 105, 78),
		Color3.fromRGB(215, 146, 112),
		Color3.fromRGB(235, 189, 157),
	},

	Industrial = {
		Color3.fromRGB(40, 43, 45),
		Color3.fromRGB(73, 78, 81),
		Color3.fromRGB(111, 117, 119),
		Color3.fromRGB(161, 151, 126),
		Color3.fromRGB(202, 139, 51),
	},

	Construction = {
		Color3.fromRGB(42, 43, 42),
		Color3.fromRGB(79, 81, 79),
		Color3.fromRGB(125, 127, 120),
		Color3.fromRGB(239, 174, 31),
		Color3.fromRGB(255, 210, 70),
	},

	Military = {
		Color3.fromRGB(40, 45, 34),
		Color3.fromRGB(68, 76, 49),
		Color3.fromRGB(102, 110, 69),
		Color3.fromRGB(137, 132, 85),
		Color3.fromRGB(178, 165, 112),
	},

	Steampunk = {
		Color3.fromRGB(52, 40, 31),
		Color3.fromRGB(91, 62, 42),
		Color3.fromRGB(139, 91, 53),
		Color3.fromRGB(188, 134, 72),
		Color3.fromRGB(217, 181, 119),
	},

	Circuit = {
		Color3.fromRGB(18, 28, 31),
		Color3.fromRGB(30, 58, 60),
		Color3.fromRGB(44, 101, 93),
		Color3.fromRGB(54, 170, 141),
		Color3.fromRGB(107, 239, 184),
	},

	Hacker = {
		Color3.fromRGB(10, 18, 13),
		Color3.fromRGB(16, 43, 24),
		Color3.fromRGB(22, 82, 39),
		Color3.fromRGB(31, 146, 60),
		Color3.fromRGB(80, 255, 112),
	},

	Ruby = {
		Color3.fromRGB(70, 15, 27),
		Color3.fromRGB(113, 22, 40),
		Color3.fromRGB(161, 31, 55),
		Color3.fromRGB(210, 52, 76),
		Color3.fromRGB(244, 105, 120),
	},

	Emerald = {
		Color3.fromRGB(15, 64, 49),
		Color3.fromRGB(22, 104, 75),
		Color3.fromRGB(34, 151, 103),
		Color3.fromRGB(60, 199, 137),
		Color3.fromRGB(127, 232, 178),
	},

	Sapphire = {
		Color3.fromRGB(23, 43, 91),
		Color3.fromRGB(33, 67, 142),
		Color3.fromRGB(49, 98, 194),
		Color3.fromRGB(80, 137, 230),
		Color3.fromRGB(143, 184, 246),
	},

	Amethyst = {
		Color3.fromRGB(50, 29, 75),
		Color3.fromRGB(82, 45, 117),
		Color3.fromRGB(120, 67, 159),
		Color3.fromRGB(164, 101, 197),
		Color3.fromRGB(208, 159, 226),
	},

	Pearl = {
		Color3.fromRGB(129, 119, 128),
		Color3.fromRGB(171, 157, 171),
		Color3.fromRGB(211, 195, 207),
		Color3.fromRGB(238, 224, 231),
		Color3.fromRGB(255, 246, 242),
	},

	Red = {
		Color3.fromRGB(105, 20, 25),
		Color3.fromRGB(155, 31, 38),
		Color3.fromRGB(205, 47, 54),
		Color3.fromRGB(239, 83, 88),
		Color3.fromRGB(255, 143, 143),
	},

	Green = {
		Color3.fromRGB(25, 85, 48),
		Color3.fromRGB(39, 128, 67),
		Color3.fromRGB(59, 174, 91),
		Color3.fromRGB(101, 211, 127),
		Color3.fromRGB(170, 235, 183),
	},

	Purple = {
		Color3.fromRGB(61, 31, 102),
		Color3.fromRGB(93, 47, 148),
		Color3.fromRGB(130, 67, 191),
		Color3.fromRGB(173, 104, 222),
		Color3.fromRGB(216, 165, 240),
	},

	Orange = {
		Color3.fromRGB(132, 57, 16),
		Color3.fromRGB(185, 82, 19),
		Color3.fromRGB(229, 116, 25),
		Color3.fromRGB(249, 159, 54),
		Color3.fromRGB(255, 207, 119),
	},

	Yellow = {
		Color3.fromRGB(115, 94, 16),
		Color3.fromRGB(174, 142, 21),
		Color3.fromRGB(222, 184, 33),
		Color3.fromRGB(250, 219, 74),
		Color3.fromRGB(255, 241, 153),
	},

	Pink = {
		Color3.fromRGB(128, 40, 82),
		Color3.fromRGB(184, 59, 113),
		Color3.fromRGB(228, 89, 146),
		Color3.fromRGB(250, 137, 181),
		Color3.fromRGB(255, 198, 221),
	},

	Teal = {
		Color3.fromRGB(20, 76, 79),
		Color3.fromRGB(31, 116, 116),
		Color3.fromRGB(47, 160, 154),
		Color3.fromRGB(83, 201, 188),
		Color3.fromRGB(151, 231, 218),
	},

	Beige = {
		Color3.fromRGB(103, 89, 70),
		Color3.fromRGB(145, 127, 101),
		Color3.fromRGB(185, 166, 135),
		Color3.fromRGB(219, 203, 172),
		Color3.fromRGB(245, 234, 208),
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
	createdGui: SurfaceGui?,
	pressed: boolean,
	currentTween: Tween?,
}

local player = Players.LocalPlayer
local trackedKeys: { [MeshPart]: KeyState } = {}
local previousLetter = ""

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
	stroke.Thickness = 1.5
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Parent = textLabel

	textLabel.Parent = surfaceGui
	surfaceGui.Parent = key

	return surfaceGui
end

local function applyTheme(key: MeshPart)
	local attribute = key:GetAttribute(THEME_ATTRIBUTE)
	local themeName = DEFAULT_THEME

	if attribute ~= nil then
		if typeof(attribute) ~= "string" then
			log.warn(
				`{key:GetFullName()}.{THEME_ATTRIBUTE} should be a string, got {typeof(attribute)} -- color unchanged`
			)
			return
		end
		themeName = attribute
	end

	local palette = THEMES[themeName]
	if palette == nil then
		log.warn(`{key:GetFullName()}.{THEME_ATTRIBUTE} has unknown theme "{themeName}" -- color unchanged`)
		return
	end

	key.Color = palette[math.random(1, #palette)]
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

	playKeySound(key)
	tweenKey(key, state, state.originalCFrame * CFrame.new(0, -DROP_DISTANCE, 0), PRESS_INFO)
end

local function releaseKey(key: MeshPart, state: KeyState)
	if not state.pressed then
		return
	end
	state.pressed = false

	tweenKey(key, state, state.originalCFrame, RELEASE_INFO)
end

local function isPlayerOnKey(key: MeshPart): boolean
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return false
	end

	local position = root.Position
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

	local state: KeyState = {
		originalCFrame = instance.CFrame,
		originalColor = instance.Color,
		createdGui = nil,
		pressed = false,
		currentTween = nil,
	}
	trackedKeys[instance] = state

	applyTheme(instance)
	state.createdGui = createLetterGui(instance)
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

	cancelTween(state)
	if instance.Parent ~= nil then
		instance.CFrame = state.originalCFrame
		instance.Color = state.originalColor
	end

	local createdGui = state.createdGui
	if createdGui ~= nil then
		createdGui:Destroy()
	end
end

local function updateKeys()
	for key, state in trackedKeys do
		if key.Parent == nil then
			unwireKey(key)
		elseif isPlayerOnKey(key) then
			pressKey(key, state)
		else
			releaseKey(key, state)
		end
	end
end

function LightUpKeysController.Init()
	CollectionService:GetInstanceAddedSignal(KEY_TAG):Connect(wireKey)
	CollectionService:GetInstanceRemovedSignal(KEY_TAG):Connect(unwireKey)

	for _, instance in CollectionService:GetTagged(KEY_TAG) do
		wireKey(instance)
	end

	RunService.Heartbeat:Connect(updateKeys)
	log.info(`ready ({#CollectionService:GetTagged(KEY_TAG)} tagged instances)`)
end

return LightUpKeysController
