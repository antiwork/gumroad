import React from "react";

import Comment, { type CommentProps } from "$app/components/Admin/Commentable/Comment";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
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
      <div className="info" role="status">
        No comments created.
      </div>
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

      <div className="rows" role="list">
        {comments.map((comment) => (
          <Comment key={comment.id} comment={comment} />
        ))}
      </div>

      {hasMore ? <div ref={elementRef}>{isLoading ? <LoadingSpinner /> : null}</div> : null}
    </div>
  );
};

export default AdminCommentableContent;
