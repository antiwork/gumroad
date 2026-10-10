import { describe, expect, it } from "vitest";

import { isIncomingCommunityChannelMessage, isIncomingUserChannelMessage } from "$app/data/communities";

describe("community channel messages", () => {
  it("accepts the three chat message events with a message object", () => {
    for (const type of ["create_chat_message", "update_chat_message", "delete_chat_message"]) {
      expect(isIncomingCommunityChannelMessage({ type, message: { id: "1" } })).toBe(true);
    }
  });

  it("rejects other events and chat events without a message", () => {
    expect(isIncomingCommunityChannelMessage({ type: "typing", message: {} })).toBe(false);
    expect(isIncomingCommunityChannelMessage({ type: "create_chat_message" })).toBe(false);
    expect(isIncomingCommunityChannelMessage(null)).toBe(false);
  });

  it("accepts the latest community info event on the user channel", () => {
    expect(isIncomingUserChannelMessage({ type: "latest_community_info", data: { id: "c1" } })).toBe(true);
    expect(isIncomingUserChannelMessage({ type: "latest_community_info" })).toBe(false);
    expect(isIncomingUserChannelMessage({ type: "create_chat_message", data: {} })).toBe(false);
  });
});
