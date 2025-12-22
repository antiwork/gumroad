import React from "react";

import Comment, { type CommentProps } from "$app/components/Admin/Commentable/Comment";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Alert } from "$app/components/ui/Alert";
import { Rows } from "$app/components/ui/Rows";
import { useIsIntersecting } from "$app/components/useIsIntersecting";

type AdminCommentableContentProps = {
  count: number;
  comments: CommentProps[];
  hasLoaded: boolean;
  isLoading: boolean;
  hasMore: boolean;
  onLoadMore: () => void;
};

const AdminCommentableContent = ({
  count,
  comments,
  hasLoaded,
  isLoading,
  hasMore,
  onLoadMore,
}: AdminCommentableContentProps) => {
  if (count === 0 && !isLoading)
    return (
      <Alert role="status" variant="info">
        No comments created.
      </Alert>
    );

  const handleIntersection = React.useCallback(
    (isIntersecting: boolean) => {
      if (!isIntersecting || !hasMore || isLoading) return;
      onLoadMore();
    },
    [hasMore, isLoading, onLoadMore],
  );

  const elementRef = useIsIntersecting<HTMLDivElement>(handleIntersection);

  return (
    <div>
      {isLoading && !hasLoaded ? <LoadingSpinner /> : null}

      <Rows role="list">
        {comments.map((comment) => (
          <Comment key={comment.id} comment={comment} />
        ))}
      </Rows>

      {hasMore ? <div ref={elementRef}>{isLoading ? <LoadingSpinner /> : null}</div> : null}
    </div>
  );
};

export default AdminCommentableContent;
