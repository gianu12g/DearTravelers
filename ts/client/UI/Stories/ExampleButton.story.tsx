/**
 * UI Labs advanced React story for ExampleButton. Opened from the UI Labs
 * Studio plugin (installed separately from the Creator Store) -- this module
 * only supplies the story table it reads.
 */
import React from "@rbxts/react";
import ReactRoblox from "@rbxts/react-roblox";
import { CreateReactStory, String } from "@rbxts/ui-labs";
import { ExampleButton } from "../Components/ExampleButton";

export = CreateReactStory(
	{
		react: React,
		reactRoblox: ReactRoblox,
		controls: {
			Label: String("Click me"),
		},
	},
	(props) => <ExampleButton Label={props.controls.Label} />,
);
