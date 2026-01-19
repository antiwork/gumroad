import { formatDistanceToNow, parseISO } from "date-fns";
import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";
import { useUserAgentInfo } from "$app/components/UserAgent";

import { TrackClick } from "./Interactions";

export type Post = { id: string; name: string; view_url: string; action_at: string };

export const DownloadPagePostList = ({ posts }: { posts: Post[] }) => {
  const userAgentInfo = useUserAgentInfo();
  return (
    <Rows role="list" aria-label="Posts">
      {posts.map((post) => {
        const actionAt = parseISO(post.action_at);
        return (
          <Row key={post.id} role="listitem">
            <RowContent>
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
            </RowContent>
            <RowActions>
              <TrackClick eventName="post_click" resourceId={post.id}>
                <Button asChild>
                  <a href={post.view_url}>View</a>
                </Button>
              </TrackClick>
            </RowActions>
          </Row>
        );
      })}
    </Rows>
  );
};
