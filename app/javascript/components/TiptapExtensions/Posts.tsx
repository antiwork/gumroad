import { Node as TiptapNode } from "@tiptap/core";
import { NodeViewProps, NodeViewWrapper, ReactNodeViewRenderer } from "@tiptap/react";
import cx from "classnames";
import { formatDistanceToNow, parseISO } from "date-fns";
import * as React from "react";

import { type Post } from "$app/types/workflow";
import { assertDefined } from "$app/utils/assert";

import { Button } from "$app/components/Button";
import { TrackClick } from "$app/components/Download/Interactions";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Drawer } from "$app/components/SortableList";
import { NodeActionsMenu } from "$app/components/TiptapExtensions/NodeActionsMenu";
import { createInsertCommand } from "$app/components/TiptapExtensions/utils";
import { Row, RowActions, RowContent, RowDetails } from "$app/components/ui/Rows";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useRunOnce } from "$app/components/useRunOnce";

declare module "@tiptap/core" {
  interface Commands<ReturnType> {
    posts: {
      insertPosts: (options: Record<string, never>) => ReturnType;
    };
  }
}

export const Posts = TiptapNode.create({
  name: "posts",
  selectable: true,
  draggable: true,
  atom: true,
  group: "block",
  parseHTML: () => [{ tag: "posts" }],
  renderHTML: ({ HTMLAttributes }) => ["posts", HTMLAttributes],
  addNodeView() {
    return ReactNodeViewRenderer(PostsNodeView);
  },
  addCommands() {
    return {
      insertPosts: createInsertCommand("posts"),
    };
  },
});

const PostsNodeView = ({ editor, selected }: NodeViewProps) => {
  const postsData = usePosts();
  const { productPermalink, isLoading, hasMorePosts, fetchMorePosts, total } = postsData;
  const posts = postsData.posts ?? [];
  const userAgentInfo = useUserAgentInfo();
  useRunOnce(() => {
    if (postsData.posts === null && !isLoading) void fetchMorePosts?.(true);
  });
  const uid = React.useId();
  const [expanded, setExpanded] = React.useState(postsData.posts === null || total > 0);

  if (total === 0 && !editor.isEditable) return null;

  return (
    <NodeViewWrapper>
      <Row className={cx("embed", { selected })}>
        {editor.isEditable ? <NodeActionsMenu editor={editor} /> : null}
        <RowContent className="content cursor-pointer all-unset" asChild>
          <button
            onClick={(e) => {
              if (e.target instanceof HTMLAnchorElement) return;
              setExpanded(!expanded);
            }}
            aria-controls={uid}
            aria-expanded={expanded}
            contentEditable={false}
          >
            {total > 0 ? (
              expanded ? (
                <Icon name="outline-cheveron-down" />
              ) : (
                <Icon name="outline-cheveron-right" />
              )
            ) : null}
            <Icon name="file-earmark-medical-fill" className={cx("type-icon", { "text-muted": total === 0 })} />
            <div>
              {isLoading || total > 0 ? (
                <>
                  <h4>Posts</h4>
                  {isLoading ? <LoadingSpinner /> : <span>{`${total} ${total === 1 ? "post" : "posts"}`}</span>}
                </>
              ) : (
                <>
                  <h4 className="text-muted">Posts (emails) sent to customers of this product will appear here</h4>
                  <a href={Routes.new_email_path({ product: productPermalink })}>Create an email</a>
                </>
              )}
            </div>
          </button>
        </RowContent>

        {editor.isEditable ? (
          <RowActions>
            <Button
              outline
              color="primary"
              aria-label="Refresh"
              disabled={isLoading}
              onClick={() => void fetchMorePosts?.(true)}
            >
              <Icon name="outline-refresh" />
            </Button>
          </RowActions>
        ) : null}

        {expanded && total > 0 ? (
          <RowDetails asChild>
            <Drawer id={uid}>
              {posts.map((post) => (
                <RowContent key={post.id}>
                  <Icon name="file-earmark-medical-fill" className="type-icon" />
                  <div>
                    {editor.isEditable ? (
                      <a href={post.url} target="_blank" rel="noreferrer">
                        <strong>{post.name}</strong>
                      </a>
                    ) : (
                      <TrackClick eventName="post_click" resourceId={post.id}>
                        <a href={post.url} target="_blank" rel="noreferrer">
                          <strong>{post.name}</strong>
                        </a>
                      </TrackClick>
                    )}
                    <div>
                      {post.date.type === "date" ? (
                        <ul className="inline">
                          <li>
                            {parseISO(post.date.value).toLocaleDateString(userAgentInfo.locale, {
                              month: "long",
                              day: "numeric",
                              year: "numeric",
                            })}
                          </li>
                          <li>{formatDistanceToNow(parseISO(post.date.value))} ago</li>
                        </ul>
                      ) : post.date.time_duration === 0 ? (
                        "Available immediately after purchase"
                      ) : (
                        `Available ${post.date.time_duration} ${post.date.time_period}${post.date.time_duration === 1 ? "" : "s"} after purchase`
                      )}
                    </div>
                  </div>
                </RowContent>
              ))}
              {hasMorePosts && fetchMorePosts ? (
                <div>
                  <Button small outline color="primary" disabled={isLoading} onClick={() => void fetchMorePosts()}>
                    Load more
                  </Button>
                </div>
              ) : null}
            </Drawer>
          </RowDetails>
        ) : null}
      </Row>
    </NodeViewWrapper>
  );
};

const PostsContext = React.createContext<{
  posts: Post[] | null;
  total: number;
  isLoading?: boolean;
  hasMorePosts?: boolean;
  fetchMorePosts?: (refresh?: boolean) => Promise<void>;
  productPermalink?: string;
} | null>(null);
export const PostsProvider = PostsContext.Provider;
const usePosts = () => assertDefined(React.useContext(PostsContext), "usePosts must be used within a PostsProvider");
