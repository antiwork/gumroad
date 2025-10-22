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
    fetchData: fetchComments,
    hasMore,
    pagination,
    setHasMore,
    hasLoaded,
    setHasLoaded,
  } = useLazyPaginatedFetch<CommentProps[]>([], {
    url: endpoint,
    responseParser: (data: unknown) => {
      const result = cast<{ comments: CommentProps[] }>(data);
      return result.comments;
    },
    mode: "append",
  });

  const [commentsCount, setCommentsCount] = React.useState(count ?? 0);

  const resetComments = () => {
    setComments([]);
    setCommentsCount(pagination.count);
    setHasLoaded(false);
    setHasMore(true);
  };

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      void fetchComments();
    } else {
      resetComments();
    }
  };

  const appendComment = (comment: CommentProps) => {
    setComments([comment, ...comments]);
    setCommentsCount(commentsCount + 1);
  };

  const fetchNextPage = () => {
    if (pagination.next) {
      void fetchComments({ page: pagination.next });
    }
  };

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle} className="space-y-2">
        <summary>{commentsCount === 1 ? `${commentsCount} comment` : `${commentsCount} comments`}</summary>
        <AdminCommentableForm endpoint={endpoint} onCommentAdded={appendComment} commentableType={commentableType} />
        <AdminCommentableContent
          count={commentsCount}
          comments={comments}
          hasLoaded={hasLoaded}
          isLoading={isLoading}
          hasMore={hasMore}
          onLoadMore={fetchNextPage}
        />
      </details>
    </>
  );
};

export default AdminCommentableComments;
