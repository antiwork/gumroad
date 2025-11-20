import React from "react";
import { cast } from "ts-safe-cast";

import { useLazyPaginatedFetch } from "$app/hooks/useLazyFetch";

import type { CommentProps } from "$app/components/Admin/Commentable/Comment";
import AdminCommentableContent from "$app/components/Admin/Commentable/Content";
import AdminCommentableForm from "$app/components/Admin/Commentable/Form";

type AdminCommentableProps = {
  count?: number;
  endpoint: string;
  commentableType: string;
};

const AdminCommentableComments = ({ count, endpoint, commentableType }: AdminCommentableProps) => {
  const [open, setOpen] = React.useState(false);

  const {
    data: comments,
    isLoading,
    setData: setComments,
    hasMore,
    hasLoaded,
    fetchNextPage,
  } = useLazyPaginatedFetch<CommentProps[]>([], {
    url: endpoint,
    responseParser: (data: unknown) => {
      const result = cast<{ comments: CommentProps[] }>(data);
      return result.comments;
    },
    mode: "append",
    fetchUnlessLoaded: open,
  });

  const [commentsCount, setCommentsCount] = React.useState(count ?? 0);

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
  };

  const appendComment = (comment: CommentProps) => {
    setComments([comment, ...comments]);
    setCommentsCount(commentsCount + 1);
  };

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle} className="space-y-2">
        <summary>
          <h3>{commentsCount === 1 ? `${commentsCount} comment` : `${commentsCount} comments`}</h3>
        </summary>
        <AdminCommentableForm endpoint={endpoint} onCommentAdded={appendComment} commentableType={commentableType} />
        <AdminCommentableContent
          count={commentsCount}
          comments={comments}
          hasLoaded={hasLoaded}
          isLoading={isLoading}
          hasMore={hasMore}
          onLoadMore={() => void fetchNextPage()}
        />
      </details>
    </>
  );
};

export default AdminCommentableComments;
