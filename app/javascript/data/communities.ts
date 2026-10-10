import { hasType, isOneOf, isRecord } from "$app/utils/guards";

export type Seller = {
  id: string;
  name: string;
  avatar_url: string;
};

export type Community = {
  id: string;
  name: string;
  thumbnail_url: string;
  seller: Seller;
  last_read_community_chat_message_created_at: string | null;
  unread_count: number;
};

export type NotificationSettings = {
  recap_frequency: "daily" | "weekly" | null;
};

export type CommunityNotificationSettings = Record<string, NotificationSettings>;

export type CommunityChatMessage = {
  id: string;
  community_id: string;
  content: string;
  created_at: string;
  updated_at: string;
  user: {
    id: string;
    name: string;
    avatar_url: string;
    is_seller: boolean;
  };
};

type IncomingCommunityChannelMessage =
  | { type: "create_chat_message"; message: CommunityChatMessage }
  | { type: "update_chat_message"; message: CommunityChatMessage }
  | { type: "delete_chat_message"; message: CommunityChatMessage };
type IncomingUserChannelMessage = { type: "latest_community_info"; data: Community };

export const isIncomingUserChannelMessage = (msg: unknown): msg is IncomingUserChannelMessage =>
  hasType(msg, "latest_community_info") && isRecord(msg.data);

export const isIncomingCommunityChannelMessage = (msg: unknown): msg is IncomingCommunityChannelMessage =>
  isRecord(msg) &&
  isOneOf(msg.type, ["create_chat_message", "update_chat_message", "delete_chat_message"]) &&
  isRecord(msg.message);
