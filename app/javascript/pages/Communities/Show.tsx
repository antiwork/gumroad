import React from "react";
import { Link } from "@inertiajs/react";

interface User {
  id: string;
  name: string;
  avatar_url?: string;
  is_seller: boolean;
}

interface ChatMessage {
  id: string;
  community_id: string;
  content: string;
  user: User;
  created_at: string;
  updated_at: string;
}

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

interface Props {
  community: Community;
  messages: ChatMessage[];
}

const CommunitiesShow: React.FC<Props> = ({ community, messages }) => {
  return (
    <div>
      <Link href="/communities">Back to Communities</Link>
      <h1>{community.name}</h1>
      <div>
        <p>by {community.seller.name}</p>
        {community.thumbnail_url && (
          <img src={community.thumbnail_url} alt={community.name} width={100} height={100} />
        )}
      </div>
      <div>
        <h2>Chat</h2>
        {messages.length === 0 ? (
          <p>No messages yet.</p>
        ) : (
          <ul>
            {messages.map((msg) => (
              <li key={msg.id}>
                {msg.user.avatar_url && (
                  <img src={msg.user.avatar_url} alt={msg.user.name} width={24} height={24} />
                )}
                <strong>{msg.user.name}{msg.user.is_seller ? " (Seller)" : ""}:</strong> {msg.content}
                <span style={{ fontSize: "0.8em", color: "#888" }}>
                  {" "}
                  {new Date(msg.created_at).toLocaleString()}
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  );
};

export default CommunitiesShow;
