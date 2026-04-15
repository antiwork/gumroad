// Keep in sync with _definitions.scss

export const visualStates = ["success", "danger", "warning", "info"] as const;
export type VisualState = (typeof visualStates)[number];

export const mainColors = ["primary", "black", "accent", "filled"] as const;
export type MainColor = (typeof mainColors)[number];

export const buttonColors = ["default", ...visualStates, ...mainColors] as const;
export type ButtonColor = (typeof buttonColors)[number];
