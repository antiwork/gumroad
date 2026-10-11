import { describe, expect, it } from "vitest";

import { isMobileAppAudioPlayerInfo, isReactNativeMessage } from "$app/components/useReactNativeMessage";

describe("isReactNativeMessage", () => {
  it("accepts each message the mobile app sends", () => {
    expect(isReactNativeMessage({ type: "mobileAppSettingsSave" })).toBe(true);
    expect(isReactNativeMessage({ type: "mobileAppPageChange", payload: { pageIndex: 3 } })).toBe(true);
    expect(isReactNativeMessage({ type: "mobileAppAudioPlayerInfo", payload: { fileId: "f1", isPlaying: true } })).toBe(
      true,
    );
    expect(
      isReactNativeMessage({
        type: "mobileAppAudioPlayerInfo",
        payload: { fileId: "f1", isPlaying: false, latestMediaLocation: "12" },
      }),
    ).toBe(true);
  });

  it("rejects unknown messages and messages with a wrong payload", () => {
    expect(isReactNativeMessage({ type: "somethingElse" })).toBe(false);
    expect(isReactNativeMessage({ type: "mobileAppPageChange", payload: { pageIndex: "3" } })).toBe(false);
    expect(isReactNativeMessage({ type: "mobileAppPageChange" })).toBe(false);
    expect(isReactNativeMessage({ type: "mobileAppAudioPlayerInfo", payload: { fileId: "f1" } })).toBe(false);
    expect(
      isReactNativeMessage({
        type: "mobileAppAudioPlayerInfo",
        payload: { fileId: "f1", isPlaying: true, latestMediaLocation: 12 },
      }),
    ).toBe(false);
  });
});

describe("isMobileAppAudioPlayerInfo", () => {
  it("accepts the audio player payload the mobile app sends", () => {
    expect(isMobileAppAudioPlayerInfo({ fileId: "f1", isPlaying: true })).toBe(true);
    expect(isMobileAppAudioPlayerInfo({ fileId: "f1", isPlaying: false, latestMediaLocation: "12" })).toBe(true);
  });

  it("rejects a payload with a field of the wrong type", () => {
    expect(isMobileAppAudioPlayerInfo({ fileId: "f1", isPlaying: "true" })).toBe(false);
    expect(isMobileAppAudioPlayerInfo({ fileId: "f1", isPlaying: true, latestMediaLocation: 12 })).toBe(false);
    expect(isMobileAppAudioPlayerInfo({ fileId: 1, isPlaying: true })).toBe(false);
    expect(isMobileAppAudioPlayerInfo(null)).toBe(false);
    expect(isMobileAppAudioPlayerInfo("f1")).toBe(false);
  });
});
