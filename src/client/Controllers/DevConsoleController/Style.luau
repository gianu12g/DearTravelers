--!strict
--[[
	Shared, dependency-free constants for the dev console: colors, fixed pixel
	sizes, and the button-spec type every tab's action rows are built from.

	THIS WINDOW IS SIZED IN PIXELS (see DevConsoleController/init.luau for why),
	which is why every dimension below is a plain pixel number rather than a
	Scale value.
]]

local Style = {}

Style.BACKGROUND_COLOR = Color3.fromRGB(24, 24, 28)
Style.CHROME_COLOR = Color3.fromRGB(32, 32, 38)
Style.FIELD_COLOR = Color3.fromRGB(40, 40, 46)
Style.BORDER_COLOR = Color3.fromRGB(62, 62, 72)
Style.ACCENT_COLOR = Color3.fromRGB(88, 140, 196)
Style.TEXT_COLOR = Color3.fromRGB(225, 225, 230)
Style.BRIGHT_TEXT_COLOR = Color3.fromRGB(255, 255, 255)
Style.MUTED_TEXT_COLOR = Color3.fromRGB(170, 170, 178)
Style.OK_COLOR = Color3.fromRGB(90, 210, 130)
Style.ERROR_COLOR = Color3.fromRGB(230, 90, 90)
Style.WARN_COLOR = Color3.fromRGB(226, 170, 74)
Style.DANGER_COLOR = Color3.fromRGB(177, 70, 111)
Style.GRANT_COLOR = Color3.fromRGB(70, 130, 110)

Style.TITLE_BAR_HEIGHT = 30
Style.TAB_STRIP_HEIGHT = 26
Style.STATUS_BAR_HEIGHT = 18
Style.GRIP_SIZE = 16
Style.PADDING = 8
Style.GAP = 6
Style.ROW_HEIGHT = 26
Style.PLAYER_ROW_HEIGHT = 34
Style.SECTION_HEADER_HEIGHT = 18
Style.SCROLLBAR_THICKNESS = 6
-- Rows leave the scrollbar its own gutter instead of sliding underneath it.
Style.SCROLL_ROW_INSET = Style.SCROLLBAR_THICKNESS + 2

Style.TITLE_TEXT_SIZE = 15
Style.BODY_TEXT_SIZE = 13
Style.SMALL_TEXT_SIZE = 12

export type ButtonSpec = {
	text: string,
	color: Color3?,
	onClick: () -> (),
}

return Style
