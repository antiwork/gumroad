import { Link } from "@inertiajs/react";
import React from "react";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";

type AuthorProps = {
  id: number;
  email: string;
  name: string | null;
};

export type CommentProps = {
  id: number;
  author_name: string | null;
  comment_type: string;
  updated_at: string;
  content_formatted: string;
  author: AuthorProps | null;
};

const AdminCommentableComment = ({ comment }: { comment: CommentProps }) => (
  <div role="listitem">
    <div className="content">
      <div>
        <ul className="mb-2 inline">
          <li>
            <strong>{comment.comment_type}</strong>
          </li>
          <li>
            {comment.author ? (
              <Link href={Routes.admin_user_url(comment.author.id)}>{comment.author.name || comment.author.email}</Link>
            ) : (
              comment.author_name
            )}
          </li>
          <li>
            <DateTimeWithRelativeTooltip date={comment.updated_at} />
          </li>
        </ul>
        <div dangerouslySetInnerHTML={{ __html: comment.content_formatted }} />
      </div>
    </div>
  </div>
);

export default AdminCommentableComment;
