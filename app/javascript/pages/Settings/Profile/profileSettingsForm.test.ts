import { describe, expect, it } from "vitest";

import {
  ProfileSettingsForm,
  changedProfileSettings,
  profileThemeColors,
  rebaseProfileSettings,
} from "$app/pages/Settings/Profile/profileSettingsForm";

const settings = (overrides: Partial<ProfileSettingsForm> = {}): ProfileSettingsForm => ({
  name: "Seller",
  bio: "Original bio",
  profile_picture_blob_id: "avatar-1",
  font: "ABC Favorit",
  background_color: "#ffffff",
  highlight_color: "#ff90e8",
  product_page_storefront_enabled: false,
  hide_follow_widget: false,
  ...overrides,
});

describe("profile settings synchronization", () => {
  it("adopts refreshed server values for fields the dirty form did not edit", () => {
    const baseline = settings();
    const current = settings({ bio: "Local bio edit" });
    const incoming = settings({
      name: "Concurrent name",
      font: "Domine",
      background_color: "#000000",
      highlight_color: "#009a49",
    });

    expect(rebaseProfileSettings(current, baseline, incoming)).toEqual({
      ...incoming,
      bio: "Local bio edit",
    });
  });

  it("preserves local edits while rebasing other fields", () => {
    const baseline = settings();
    const current = settings({ background_color: "#123456" });
    const incoming = settings({ background_color: "#000000", highlight_color: "#009a49" });

    expect(rebaseProfileSettings(current, baseline, incoming)).toEqual({
      ...incoming,
      background_color: "#123456",
    });
  });

  it("submits only fields that remain changed after a rebase", () => {
    const baseline = settings();
    const current = settings({ bio: "Local bio edit" });
    const incoming = settings({ background_color: "#000000", highlight_color: "#009a49" });
    const rebased = rebaseProfileSettings(current, baseline, incoming);

    expect(changedProfileSettings(rebased, incoming)).toEqual({ bio: "Local bio edit" });
  });

  it("tracks hide_follow_widget as a changed setting", () => {
    const baseline = settings();
    const current = settings({ hide_follow_widget: true });

    expect(changedProfileSettings(current, baseline)).toEqual({ hide_follow_widget: true });
    expect(rebaseProfileSettings(current, baseline, settings()).hide_follow_widget).toBe(true);
    expect(rebaseProfileSettings(settings(), baseline, settings({ hide_follow_widget: true })).hide_follow_widget).toBe(true);
  });

  it("matches the live primary-button foreground for saturated backgrounds", () => {
    expect(profileThemeColors("#ff0000", "#ff90e8")).toMatchObject({
      "--color": "0 0 0",
      "--contrast-primary": "255 255 255",
    });
  });
});
