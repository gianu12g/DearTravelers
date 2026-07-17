/**
 * Minimal React function component, kept intentionally small: it exists to
 * prove the React/ReactRoblox wiring (node_modules/@rbxts -> component -> UI
 * Labs story) works end to end, not to be a real HUD button. Copy its shape
 * for the first real component rather than extending this one.
 */
import React, { useState } from "@rbxts/react";

export interface ExampleButtonProps {
	Label: string;
}

const IDLE_COLOR = Color3.fromRGB(45, 45, 55);
const HOVER_COLOR = Color3.fromRGB(65, 65, 80);

export function ExampleButton(props: ExampleButtonProps) {
	const [hovered, setHovered] = useState(false);

	return (
		<textbutton
			Size={UDim2.fromOffset(160, 44)}
			BackgroundColor3={hovered ? HOVER_COLOR : IDLE_COLOR}
			Text={props.Label}
			TextColor3={Color3.fromRGB(240, 240, 245)}
			Font={Enum.Font.GothamMedium}
			TextSize={18}
			AutoButtonColor={false}
			Event={{
				MouseEnter: () => setHovered(true),
				MouseLeave: () => setHovered(false),
			}}
		>
			<uicorner CornerRadius={new UDim(0, 8)} />
		</textbutton>
	);
}
