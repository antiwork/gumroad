import { getAccessibleAccent, getContrastColor, hexToRgb } from "$app/utils/color";

export type ProfileSettingsForm = {
  name: string | null;
  bio: string | null;
  font: string;
  background_color: string;
  highlight_color: string;
  profile_picture_blob_id: string | null;
  product_page_storefront_enabled: boolean;
  hide_follow_widget: boolean;
};

export const profileThemeColors = (backgroundColor: string, highlightColor: string) => {
  const accentColors = getAccessibleAccent(highlightColor);
  const textColor = getContrastColor(backgroundColor);

  return {
    "--accent": hexToRgb(highlightColor),
    "--accent-with-text": hexToRgb(accentColors.accent),
    "--contrast-accent": hexToRgb(accentColors.text),
    "--filled": hexToRgb(backgroundColor),
    "--color": hexToRgb(textColor),
    "--contrast-primary": hexToRgb(getContrastColor(textColor)),
  };
};

export const changedProfileSettings = (
  current: ProfileSettingsForm,
  baseline: ProfileSettingsForm,
): Partial<ProfileSettingsForm> => {
  const changes: Partial<ProfileSettingsForm> = {};
  if (current.name !== baseline.name) changes.name = current.name;
  if (current.bio !== baseline.bio) changes.bio = current.bio;
  if (current.profile_picture_blob_id !== baseline.profile_picture_blob_id) {
    changes.profile_picture_blob_id = current.profile_picture_blob_id;
  }
  if (current.font !== baseline.font) changes.font = current.font;
  if (current.background_color !== baseline.background_color) changes.background_color = current.background_color;
  if (current.highlight_color !== baseline.highlight_color) changes.highlight_color = current.highlight_color;
  if (current.product_page_storefront_enabled !== baseline.product_page_storefront_enabled) {
    changes.product_page_storefront_enabled = current.product_page_storefront_enabled;
  }
  if (current.hide_follow_widget !== baseline.hide_follow_widget) changes.hide_follow_widget = current.hide_follow_widget;
  return changes;
};

export const rebaseProfileSettings = (
  current: ProfileSettingsForm,
  previousBaseline: ProfileSettingsForm,
  incoming: ProfileSettingsForm,
): ProfileSettingsForm => ({
  name: current.name === previousBaseline.name ? incoming.name : current.name,
  bio: current.bio === previousBaseline.bio ? incoming.bio : current.bio,
  profile_picture_blob_id:
    current.profile_picture_blob_id === previousBaseline.profile_picture_blob_id
      ? incoming.profile_picture_blob_id
      : current.profile_picture_blob_id,
  font: current.font === previousBaseline.font ? incoming.font : current.font,
  background_color:
    current.background_color === previousBaseline.background_color
      ? incoming.background_color
      : current.background_color,
  highlight_color:
    current.highlight_color === previousBaseline.highlight_color ? incoming.highlight_color : current.highlight_color,
  product_page_storefront_enabled:
    current.product_page_storefront_enabled === previousBaseline.product_page_storefront_enabled
      ? incoming.product_page_storefront_enabled
      : current.product_page_storefront_enabled,
  hide_follow_widget:
    current.hide_follow_widget === previousBaseline.hide_follow_widget
      ? incoming.hide_follow_widget
      : current.hide_follow_widget,
});
