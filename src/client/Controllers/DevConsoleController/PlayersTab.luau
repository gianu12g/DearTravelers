--!strict
--[[
	The Players tab: the target picker. One list, always live, no floating
	overlay to land behind another element or swallow its own clicks.
]]

local Players = game:GetService("Players")

local Style = require(script.Parent.Style)
local Widgets = require(script.Parent.Widgets)

local player = Players.LocalPlayer

export type Deps = {
	getTarget: () -> Player,
	setTarget: (Player) -> (),
	registerPage: (string, Frame) -> (),
}

local PlayersTab = {}

local deps: Deps? = nil

local playersScroll: ScrollingFrame? = nil
local playersHeaderLabel: TextLabel? = nil

function PlayersTab.setup(newDeps: Deps)
	deps = newDeps
end

--[[
	Rebuilt fresh on every open, every roster change and every target change -- a
	cached roster goes stale the moment anyone joins or leaves while the panel is
	up, which is precisely when a dev console gets used.
]]
function PlayersTab.rebuildPlayerRows()
	local currentDeps = deps :: Deps
	local list = playersScroll
	if list == nil then
		return
	end

	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local roster = Players:GetPlayers()
	local currentTarget = currentDeps.getTarget()

	local header = playersHeaderLabel
	if header ~= nil then
		header.Text = `{#roster} in server -- click a row to target them`
	end

	for index, candidate in roster do
		local isTarget = candidate == currentTarget

		local row = Widgets.newButton("", UDim2.new(1, -Style.SCROLL_ROW_INSET, 0, Style.PLAYER_ROW_HEIGHT))
		row.Name = candidate.Name
		row.LayoutOrder = index
		row.BackgroundColor3 = if isTarget then Style.ACCENT_COLOR else Style.FIELD_COLOR
		row.Parent = list

		-- rbxthumb is resolved by the engine from the id alone, so this needs no
		-- yielding GetUserThumbnailAsync call and no request of our own.
		local avatar = Instance.new("ImageLabel")
		avatar.Name = "Avatar"
		avatar.AnchorPoint = Vector2.new(0, 0.5)
		avatar.Position = UDim2.new(0, 4, 0.5, 0)
		avatar.Size = UDim2.fromOffset(Style.PLAYER_ROW_HEIGHT - 8, Style.PLAYER_ROW_HEIGHT - 8)
		avatar.BackgroundColor3 = Style.CHROME_COLOR
		avatar.BorderSizePixel = 0
		avatar.Image = `rbxthumb://type=AvatarHeadShot&id={candidate.UserId}&w=48&h=48`
		avatar.Parent = row
		Widgets.withCorner(avatar, 4)

		local name = Widgets.newLabel(
			candidate.Name,
			UDim2.new(1, -(Style.PLAYER_ROW_HEIGHT + 90), 0, 15),
			Style.BODY_TEXT_SIZE,
			if isTarget then Style.BRIGHT_TEXT_COLOR else Style.TEXT_COLOR
		)
		name.Name = "PlayerName"
		name.Position = UDim2.fromOffset(Style.PLAYER_ROW_HEIGHT, 3)
		name.Font = Enum.Font.GothamBold
		name.Parent = row

		local detail = `UserId {candidate.UserId}`
		if candidate == player then
			detail = `{detail}  (you)`
		end

		local subtitle = Widgets.newLabel(
			detail,
			UDim2.new(1, -(Style.PLAYER_ROW_HEIGHT + 90), 0, 13),
			Style.SMALL_TEXT_SIZE - 1,
			Style.MUTED_TEXT_COLOR
		)
		subtitle.Name = "PlayerDetail"
		subtitle.Position = UDim2.fromOffset(Style.PLAYER_ROW_HEIGHT, 17)
		subtitle.Parent = row

		if isTarget then
			local badge = Widgets.newLabel(
				"TARGET",
				UDim2.fromOffset(80, Style.PLAYER_ROW_HEIGHT),
				Style.SMALL_TEXT_SIZE - 1,
				Style.BRIGHT_TEXT_COLOR
			)
			badge.Name = "TargetBadge"
			badge.AnchorPoint = Vector2.new(1, 0)
			badge.Position = UDim2.fromScale(1, 0)
			badge.Font = Enum.Font.GothamBold
			badge.TextXAlignment = Enum.TextXAlignment.Right
			badge.Parent = row
		end

		row.Activated:Connect(function()
			currentDeps.setTarget(candidate)
		end)
	end
end

function PlayersTab.build(parent: Frame)
	local currentDeps = deps :: Deps
	local page = Widgets.newPage(parent, "Players", currentDeps.registerPage)

	local header = Widgets.newLabel(
		"--",
		UDim2.new(1, 0, 0, Style.SECTION_HEADER_HEIGHT),
		Style.SMALL_TEXT_SIZE,
		Style.MUTED_TEXT_COLOR
	)
	header.Name = "PlayersHeader"
	header.Font = Enum.Font.GothamBold
	header.Parent = page
	playersHeaderLabel = header

	playersScroll = Widgets.newScrollList(
		page,
		"PlayersList",
		UDim2.fromOffset(0, Style.SECTION_HEADER_HEIGHT + 4),
		UDim2.new(1, 0, 1, -(Style.SECTION_HEADER_HEIGHT + 4))
	)
end

function PlayersTab.cleanup()
	playersScroll = nil
	playersHeaderLabel = nil
end

return PlayersTab
