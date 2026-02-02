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
