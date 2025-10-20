import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

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
  const [isLoading, setIsLoading] = React.useState(false);
  const [comments, setComments] = React.useState<CommentProps[]>([]);
  const [commentsCount, setCommentsCount] = React.useState(count ?? 0);

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

  const onCommentAdded = (comment: CommentProps) => {
    setComments([comment, ...comments]);
    setCommentsCount(commentsCount + 1);
  };

  return (
    <>
      <hr />
      <AdminCommentableForm endpoint={endpoint} onCommentAdded={onCommentAdded} commentableType={commentableType} />
      <details open={open} onToggle={onToggle} className="space-y-2">
        <summary>{commentsCount === 1 ? `${commentsCount} comment` : `${commentsCount} comments`}</summary>
        <AdminCommentableContent count={commentsCount} comments={comments} isLoading={isLoading} />
      </details>
    </>
  );
};

export default AdminCommentableComments;
