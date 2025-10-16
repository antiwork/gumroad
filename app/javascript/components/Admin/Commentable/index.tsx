import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import type { CommentProps } from "$app/components/Admin/Commentable/Comment";
import AdminCommentableContent from "$app/components/Admin/Commentable/Content";
import AdminCommentableForm from "$app/components/Admin/Commentable/Form";

type AdminCommentableProps = {
  endpoint: string;
  commentableType: string;
};

const AdminCommentableComments = ({ endpoint, commentableType }: AdminCommentableProps) => {
  const [open, setOpen] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);
  const [comments, setComments] = React.useState<CommentProps[]>([]);

  const fetchComments = async () => {
    setIsLoading(true);
    const response = await request({
      method: "GET",
      url: endpoint,
      accept: "json",
    });
    const data = cast<{ comments: CommentProps[] }>(await response.json());
    setComments(data.comments);
    setIsLoading(false);
  };

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      void fetchComments();
    } else {
      setComments([]);
    }
  };

  const appendComment = (comment: CommentProps) => setComments([comment, ...comments]);

  return (
    <>
      <hr />
      <AdminCommentableForm endpoint={endpoint} onCommentAdded={appendComment} commentableType={commentableType} />
      <details open={open} onToggle={onToggle} className="space-y-2">
        <summary>Comments</summary>
        <AdminCommentableContent count={comments.length} comments={comments} isLoading={isLoading} />
      </details>
    </>
  );
};

export default AdminCommentableComments;
