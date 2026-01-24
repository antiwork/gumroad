import React from "react";
import { Link } from "@inertiajs/react";

interface Community {
  id: string;
  name: string;
  thumbnail_url?: string;
  seller: {
    id: string;
    name: string;
    avatar_url?: string;
  };
  unread_count: number;
  last_read_community_chat_message_created_at?: string;
}

interface NotificationSettings {
  recap_frequency: "daily" | "weekly" | null;
}

interface Props {
  has_products: boolean;
  communities: Community[];
  notification_settings: Record<string, NotificationSettings>;
}

const CommunitiesIndex: React.FC<Props> = ({ communities }) => {
  return (
    <div>
      <h1>Communities</h1>
      {communities.length === 0 ? (
        <p>No communities found.</p>
      ) : (
        <ul>
          {communities.map((community) => (
            <li key={community.id}>
              <Link href={`/communities/${community.seller.id}/${community.id}`}>
                {community.thumbnail_url && (
                  <img src={community.thumbnail_url} alt={community.name} width={40} height={40} />
                )}
                <span>{community.name}</span>
                <span>by {community.seller.name}</span>
                {community.unread_count > 0 && <span>Unread: {community.unread_count}</span>}
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
};

export default CommunitiesIndex;
