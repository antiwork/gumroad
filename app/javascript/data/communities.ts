import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

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

export function getCommunityChatMessages({
  communityId,
  timestamp,
  fetchType,
}: {
  communityId: string;
  timestamp: string;
  fetchType: "older" | "newer" | "around";
}) {
  const abort = new AbortController();
  const response = request({
    method: "GET",
    accept: "json",
    url: Routes.community_chat_messages_path(communityId, { timestamp, fetch_type: fetchType }),
    abortSignal: abort.signal,
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) =>
      cast<{
        messages: CommunityChatMessage[];
        next_older_timestamp: string | null;
        next_newer_timestamp: string | null;
      }>(json),
    );

  return {
    response,
    cancel: () => abort.abort(),
  };
}

export function markCommunityChatMessagesAsRead({
  communityId,
  messageId,
}: {
  communityId: string;
  messageId: string;
}) {
  const abort = new AbortController();
  const response = request({
    method: "POST",
    accept: "json",
    url: Routes.community_last_read_chat_message_path(communityId, { message_id: messageId }),
    abortSignal: abort.signal,
  })
    .then((res) => {
      if (!res.ok) throw new ResponseError();
      return res.json();
    })
    .then((json) => cast<{ unread_count: number }>(json));

  return {
    response,
    cancel: () => abort.abort(),
  };
}

