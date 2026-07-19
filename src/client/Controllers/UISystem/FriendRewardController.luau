--!strict
--[[
	Friend-invite reward UI. NOT a port -- the source kit shipped
	FriendRewardService (server/FriendService.luau) with no client half at
	all, so friendClaim (Shared/UISystem/Net.luau) had no sender. Modeled on
	this folder's GroupRewardController.luau, the closest sibling: same
	single-claim-button shape, same "replicated state flips, DataController
	repaints" source of truth.

	State lives at {"UISystem","FriendsReward"} = { JoinedFriends: {number},
	Claimed: boolean } (FriendRewardService.luau); the required count is
	Shared/UISystem/Config/General.luau's InviteRewardRequiredFriends.

	Unlike GroupRewardController (no Init(): groupClaimResult only ever
	arrives in reply to a request THIS client just sent), FriendsReward is
	ordinary profile state that can replicate at any time -- ARCHITECTURE.md's
	"register in Init() or miss it permanently" applies here. So the split is
	the textbook one: Init() registers the DataController.observe listener
	and just remembers the latest value (no yielding, no GUI touched -- Frames
	aren't guaranteed to exist yet); Start() resolves the frame/buttons
	(yields on WaitForChild) and paints whatever Init() already captured.

	GUI defect worth flagging (gui/Main/Frames/Friends.json, dumped from
	Studio): the Friends frame has TWO sibling TextButtons both literally
	named "Redeem" -- the real claim button (MainText "Invite") and an
	unrelated leftover paid-skip button (MainText "Skip (7)") this feature
	has no use for. A bare frame:WaitForChild("Redeem") would silently
	resolve to whichever one happens to be first, which is not something to
	build on for a duplicate name; findClaimButton below disambiguates by
	MainText instead. The GUI itself is Studio-authored (ARCHITECTURE.md:
	"Everything else in Studio... yours"), so this is not fixed here, only
	worked around.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataController = require(script.Parent.Parent.DataController)
local Frames = require(script.Parent.Parent.Parent.UI.UISystem.Frames)
local GeneralConfig = require(ReplicatedStorage.Shared.UISystem.Config.General)
local Log = require(ReplicatedStorage.Shared.Log)
local Net = require(ReplicatedStorage.Shared.UISystem.Net)

local log = Log.new("FriendRewardController")

local FriendRewardController = {}

-- Latest state captured by Init()'s observer. Start() paints from this
-- immediately on resolving the GUI, then the same observer callback keeps
-- painting it on every future change.
local latestJoinedCount = 0
local latestClaimed = false

-- Set by Start() once the GUI exists; nil beforehand, so Init()'s observer
-- callback (which can fire before Start() runs) only updates the captured
-- state above, never touches an instance that might not exist yet.
local paintUi: ((joinedCount: number, claimed: boolean) -> ())? = nil

local function findClaimButton(frame: Frame): GuiButton
	for _, child in frame:GetChildren() do
		if child:IsA("TextButton") and child.Name == "Redeem" then
			local mainText = child:FindFirstChild("MainText")
			if mainText ~= nil and mainText:IsA("TextLabel") and mainText.Text == "Invite" then
				return child
			end
		end
	end
	error('FriendRewardController: Friends frame has no Redeem button with MainText "Invite"', 0)
end

function FriendRewardController.Init()
	DataController.observe({ "UISystem", "FriendsReward" }, function(value: any)
		if type(value) ~= "table" then
			return
		end

		local joined = value.JoinedFriends
		local claimed = value.Claimed
		if type(joined) ~= "table" or type(claimed) ~= "boolean" then
			return
		end

		latestJoinedCount = #joined
		latestClaimed = claimed

		if paintUi ~= nil then
			paintUi(latestJoinedCount, latestClaimed)
		end
	end)
end

function FriendRewardController.Start()
	local frame = Frames.get("FriendInvite")
	local claimButton = findClaimButton(frame)
	local mainText = claimButton:WaitForChild("MainText") :: TextLabel
	local progressHolder = frame:WaitForChild("ProgressHolder")
	local progressLabel = progressHolder:WaitForChild("Loaded") :: TextLabel

	local function updateUi(joinedCount: number, claimed: boolean)
		progressLabel.Text = `{joinedCount}/{GeneralConfig.InviteRewardRequiredFriends}`
		claimButton.Active = not claimed
		mainText.Text = if claimed then "Claimed" else "Invite"
	end

	paintUi = updateUi
	updateUi(latestJoinedCount, latestClaimed)

	claimButton.MouseButton1Click:Connect(function()
		Net.friendClaim.send()
	end)

	log.info("ready")
end

return FriendRewardController
