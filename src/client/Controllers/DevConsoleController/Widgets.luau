--!strict
--[[
	Stateless widget factories shared by every tab page. Nothing here holds
	state of its own -- callers own whatever instances these hand back.
]]

local Style = require(script.Parent.Style)

local Widgets = {}

----------------------------------------------------------------------
-- Widgets
----------------------------------------------------------------------

-- Decorative corner rounding is a fixed pixel radius, like every other
-- dimension in this file.
function Widgets.withCorner(instance: GuiObject, radius: number): GuiObject
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = instance
	return instance
end

function Widgets.newLabel(text: string, size: UDim2, textSize: number, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = size
	label.Font = Enum.Font.Gotham
	label.TextSize = textSize
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = text
	return label
end

function Widgets.newButton(text: string, size: UDim2): TextButton
	local button = Instance.new("TextButton")
	button.AutoButtonColor = true
	button.Size = size
	button.BackgroundColor3 = Style.FIELD_COLOR
	button.Font = Enum.Font.Gotham
	button.TextSize = Style.BODY_TEXT_SIZE
	button.TextColor3 = Style.TEXT_COLOR
	button.TextTruncate = Enum.TextTruncate.AtEnd
	button.Text = text
	Widgets.withCorner(button, 5)
	return button
end

function Widgets.newTextBox(placeholder: string, size: UDim2): TextBox
	local box = Instance.new("TextBox")
	box.Size = size
	box.BackgroundColor3 = Style.FIELD_COLOR
	box.Font = Enum.Font.Gotham
	box.TextSize = Style.BODY_TEXT_SIZE
	box.TextColor3 = Style.TEXT_COLOR
	box.PlaceholderText = placeholder
	box.ClearTextOnFocus = false
	box.Text = ""
	Widgets.withCorner(box, 5)
	return box
end

function Widgets.newScrollList(parent: Instance, name: string, position: UDim2, size: UDim2): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = name
	scroll.Position = position
	scroll.Size = size
	scroll.BackgroundColor3 = Style.CHROME_COLOR
	scroll.BackgroundTransparency = 0.35
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = Style.SCROLLBAR_THICKNESS
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = parent
	Widgets.withCorner(scroll, 5)

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.PaddingLeft = UDim.new(0, 4)
	padding.Parent = scroll

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Style.GAP - 2)
	layout.Parent = scroll

	return scroll
end

function Widgets.addSectionHeader(page: ScrollingFrame, order: number, text: string)
	local label = Widgets.newLabel(
		text,
		UDim2.new(1, -Style.SCROLL_ROW_INSET, 0, Style.SECTION_HEADER_HEIGHT),
		Style.SMALL_TEXT_SIZE,
		Style.MUTED_TEXT_COLOR
	)
	label.Name = `Header{order}`
	label.LayoutOrder = order
	label.Font = Enum.Font.GothamBold
	label.TextYAlignment = Enum.TextYAlignment.Bottom
	label.Parent = page
end

--[[
	One row of equally sized buttons. Each cell gives back its share of the
	inter-cell gaps, so N cells plus N-1 gaps add up to exactly the row width at
	any window size -- no hand-tuned offsets that only work at one width.
]]
function Widgets.addButtonRow(page: ScrollingFrame, order: number, specs: { Style.ButtonSpec }): { TextButton }
	local row = Instance.new("Frame")
	row.Name = `Row{order}`
	row.LayoutOrder = order
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, -Style.SCROLL_ROW_INSET, 0, Style.ROW_HEIGHT)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Style.GAP)
	layout.Parent = row

	local count = #specs
	local created: { TextButton } = {}

	for index, spec in specs do
		local button = Widgets.newButton(spec.text, UDim2.new(1 / count, -Style.GAP * (count - 1) / count, 1, 0))
		button.LayoutOrder = index
		if spec.color ~= nil then
			button.BackgroundColor3 = spec.color
		end
		button.Parent = row
		button.Activated:Connect(spec.onClick)
		table.insert(created, button)
	end

	row.Parent = page
	return created
end

-- Returns the row's Value label so the caller can index it under whatever key
-- it likes (the Info tab keys these by field name).
function Widgets.addInfoRow(page: ScrollingFrame, order: number, name: string): TextLabel
	local row = Instance.new("Frame")
	row.Name = name
	row.LayoutOrder = order
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, -Style.SCROLL_ROW_INSET, 0, Style.ROW_HEIGHT - 6)
	row.Parent = page

	local key = Widgets.newLabel(name, UDim2.fromScale(0.44, 1), Style.SMALL_TEXT_SIZE, Style.MUTED_TEXT_COLOR)
	key.Name = "Key"
	key.Parent = row

	local value = Widgets.newLabel("--", UDim2.fromScale(0.56, 1), Style.SMALL_TEXT_SIZE, Style.TEXT_COLOR)
	value.Name = "Value"
	value.Position = UDim2.fromScale(0.44, 0)
	value.Font = Enum.Font.RobotoMono
	value.Parent = row

	return value
end

-- Creates one tab's page frame and hands it to `register` so the caller (the
-- tab strip owner) can key it by name for selectTab's Visible toggling.
function Widgets.newPage(parent: Frame, name: string, register: (string, Frame) -> ()): Frame
	local page = Instance.new("Frame")
	page.Name = `{name}Page`
	page.BackgroundTransparency = 1
	page.Size = UDim2.fromScale(1, 1)
	page.Visible = false
	page.Parent = parent
	register(name, page)
	return page
end

return Widgets
