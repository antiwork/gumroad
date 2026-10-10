import { describe, expect, it } from "vitest";

import { isReactNativeMessage } from "$app/components/useReactNativeMessage";

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
