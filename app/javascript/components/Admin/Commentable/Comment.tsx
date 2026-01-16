import { Link } from "@inertiajs/react";
import React from "react";
import ReactMarkdown from "react-markdown";

import DateTimeWithRelativeTooltip from "$app/components/Admin/DateTimeWithRelativeTooltip";
import { Row, RowContent } from "$app/components/ui/Rows";

type AuthorProps = {
  external_id: string;
  email: string;
  name: string | null;
};

export type CommentProps = {
  id: number;
  author_name: string | null;
  comment_type: string;
  updated_at: string;
  content: string;
  author: AuthorProps | null;
};

const AdminCommentableComment = ({ comment }: { comment: CommentProps }) => (
  <Row role="listitem">
    <RowContent>
      <div>
        <ul className="mb-2 inline">
          <li>
            <strong>{comment.comment_type}</strong>
          </li>
          <li>
            {comment.author ? (
              <Link href={Routes.admin_user_url(comment.author.external_id)}>
                {comment.author.name || comment.author.email}
              </Link>
            ) : (
              comment.author_name
            )}
          </li>
          <li>
            <DateTimeWithRelativeTooltip date={comment.updated_at} />
          </li>
        </ul>
        <ReactMarkdown>{comment.content}</ReactMarkdown>
      </div>
    </RowContent>
  </Row>
);

export default AdminCommentableComment;
