--!strict
--[[
	Normalizes a Studio-authored ScrollingFrame into the shape ThemeShop and
	Cosmetics already use, so a new list UI scrolls correctly without each
	controller re-deriving the same fixes.

	The authored frames in this place share three traits that individually
	break AutomaticCanvasSize. All three are undone here:

	  1. A fixed `CanvasSize.Y` scale with children sized as percentages OF that
	     canvas. Circular -- child height depends on canvas height depends on
	     children -- so the canvas collapses instead of growing. Fixed by
	     resolving the template's height to an OFFSET before the fixed canvas is
	     dropped (the same move MonetizationController.freezeHeight makes for the
	     gift list). X is deliberately left as a scale so a wrapping layout still
	     reflows with the frame's width.

	  2. Layout padding expressed in SCALE, same circularity. Floored, never
	     rounded: the authored rows are tuned to just fit, and rounding a
	     sub-pixel gap UP has been measured to drop a whole column.

	  3. A UIAspectRatioConstraint on the ScrollingFrame, which constrains the
	     CANVAS and not merely the frame. Measured on the Index: with it attached
	     the canvas pinned to 324px while content measured 1669px; detached, the
	     canvas immediately became 1669. It is inert for layout in these frames
	     (their Size is already a scale of an outer wrapper), so it is removed.

	ClipsDescendants is deliberately NOT touched. These frames are wrapped in an
	outer HolderParent that does the clipping precisely so the cards' UIStrokes
	are not shaved at the scroll edge.

	Returns the inner content Frame (AutomaticSize.Y) that cards should be
	parented into -- the level ThemeShop/Cosmetics both have and the newer
	authored frames lack.

	A plain module (Loader ignores it, ARCHITECTURE.md Recipe 3).
]]

local ScrollCanvas = {}

--[[
	`template` must still be PARENTED and laid out when this is called --
	AbsoluteSize reads 0 once an object is unparented, and the frozen height is
	inherited by every clone taken afterwards. Call before detaching it.
]]
function ScrollCanvas.normalize(scrollFrame: ScrollingFrame, template: GuiObject?): Frame
	if template ~= nil then
		local height = template.AbsoluteSize.Y
		if height > 0 then
			template.Size = UDim2.new(template.Size.X.Scale, template.Size.X.Offset, 0, height)
		end
	end

	local listLayout = scrollFrame:FindFirstChildOfClass("UIListLayout")
	if listLayout ~= nil and listLayout.Padding.Scale ~= 0 then
		local resolved = scrollFrame.AbsoluteSize.X * listLayout.Padding.Scale + listLayout.Padding.Offset
		if resolved > 0 then
			listLayout.Padding = UDim.new(0, math.floor(resolved))
		end
	end

	local aspectConstraint = scrollFrame:FindFirstChildOfClass("UIAspectRatioConstraint")
	if aspectConstraint ~= nil then
		aspectConstraint:Destroy()
	end

	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.fromScale(0.5, 0)
	holder.Size = UDim2.fromScale(1, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	if listLayout ~= nil then
		listLayout.Parent = holder
	end
	holder.Parent = scrollFrame

	scrollFrame.CanvasSize = UDim2.new()
	scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollFrame.ScrollingDirection = Enum.ScrollingDirection.Y

	return holder
end

return ScrollCanvas
