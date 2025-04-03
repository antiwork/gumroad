import { formatDistanceToNow, parseISO } from "date-fns";
import * as React from "react";

import { Icon } from "$app/components/Icons";
import { useUserAgentInfo } from "$app/components/UserAgent";

import { TrackClick } from "./Interactions";

export type Post = { id: string; name: string; view_url: string; action_at: string };

export const DownloadPagePostList = ({ posts }: { posts: Post[] }) => {
  const userAgentInfo = useUserAgentInfo();
  return (
    <div className="rows" role="list" aria-label="Posts">
      {posts.map((post) => {
        const actionAt = parseISO(post.action_at);
        return (
          <div key={post.id} role="listitem">
            <div className="content">
              <Icon name="file-earmark-medical-fill" className="type-icon" />
              <div>
                <div>
                  <h4>{post.name}</h4>
                  <ul className="inline">
                    <li>
                      {actionAt.toLocaleDateString(userAgentInfo.locale, {
                        month: "long",
                        day: "numeric",
                        year: "numeric",
                      })}
                    </li>
                    <li>{formatDistanceToNow(actionAt)} ago</li>
                  </ul>
                </div>
              </div>
            </div>
            <div className="actions">
              <TrackClick eventName="post_click" resourceId={post.id}>
                <a href={post.view_url} className="button">
                  View
                </a>
              </TrackClick>
            </div>
          </div>
        );
      })}
    </div>
  );
};
