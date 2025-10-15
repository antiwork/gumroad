import React from "react";

import Comment, { type CommentProps } from "$app/components/Admin/Commentable/Comment";
import Loading from "$app/components/Admin/Loading";

type AdminCommentableCommentsProps = {
  count: number;
  comments: CommentProps[];
  isLoading: boolean;
};

const AdminCommentableComments = ({ count, comments, isLoading }: AdminCommentableCommentsProps) => {
  if (count === 0 && !isLoading)
    return (
      <div className="info" role="status">
        No comments created.
      </div>
    );

  return (
    <div>
      <h4 className="mb-2 font-bold">
        {comments.length} of {count === 1 ? "1 comment" : `${count} comments`}
      </h4>

      {isLoading ? <Loading /> : null}

      <div className="rows" role="list">
        {comments.map((comment) => (
          <Comment key={comment.id} comment={comment} />
        ))}
      </div>
    </div>
  );
};

export default AdminCommentableComments;
