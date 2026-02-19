export const hexToRgb = (hex: string) =>
  `${parseInt(hex.slice(1, 3), 16)} ${parseInt(hex.slice(3, 5), 16)} ${parseInt(hex.slice(5), 16)}`;

export const getContrastColor = (background: string) => {
  const r = parseInt(background.substring(1, 3), 16) / 255;
  const g = parseInt(background.substring(3, 5), 16) / 255;
  const b = parseInt(background.substring(5, 7), 16) / 255;

  return (Math.min(r, g, b) + Math.max(r, g, b)) / 2 < 0.55 ? "#FFFFFF" : "#000000";
};
