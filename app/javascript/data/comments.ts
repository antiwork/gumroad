import { cast } from "ts-safe-cast";

import { request, ResponseError } from "$app/utils/request";

export type Comment = {
  id: string;
  author_id: string | null;
  author_name: string;
  purchase_id: string | null;
  author_avatar_url: string;
  content: { original: string; formatted: string };
  depth: number;
  created_at: string;
  created_at_humanized: string;
  is_editable: boolean;
  is_deletable: boolean;
  parent_id: string | null;
};
export type PaginatedComments = {
  comments: Comment[];
  count: number;
  pagination: {
    count: number;
    items: number;
    page: number;
    pages: number;
    prev: number | null;
    next: number | null;
    last: number;
  };
};

type AddCommentArgs = {
  commentable_id: string;
  purchase_id: null | string;
  content: string;
  parent_id: null | string;
};
export const addComment = async ({
  commentable_id,
  purchase_id,
  content,
  parent_id,
}: AddCommentArgs): Promise<Comment> => {
  const response = await request({
    method: "POST",
    accept: "json",
    url: Routes.custom_domain_create_post_comment_path(commentable_id, { purchase_id }),
    data: { comment: { content, parent_id } },
  });
  const json: unknown = await response.json();
  if (!response.ok) throw new ResponseError(cast<{ error: string }>(json).error);
  return cast<{ comment: Comment }>(json).comment;
};

type UpdateCommentArgs = {
  commentable_id: string;
  purchase_id: null | string;
  id: string;
  content: string;
};
export const updateComment = async ({
  commentable_id,
  purchase_id,
  id,
  content,
}: UpdateCommentArgs): Promise<Comment> => {
  const response = await request({
    method: "PUT",
    accept: "json",
    url: Routes.custom_domain_update_post_comment_path(commentable_id, id, {
      purchase_id,
    }),
    data: { comment: { content } },
  });
  const json: unknown = await response.json();
  if (!response.ok) throw new ResponseError(cast<{ error: string }>(json).error);
  return cast<{ comment: Comment }>(json).comment;
};

type DeleteCommentArgs = {
  commentable_id: string;
  purchase_id: null | string;
  id: string;
};
export const deleteComment = async ({ commentable_id, purchase_id, id }: DeleteCommentArgs): Promise<string[]> => {
  const response = await request({
    method: "DELETE",
    accept: "json",
    url: Routes.custom_domain_delete_post_comment_path(commentable_id, id, { purchase_id }),
  });
  const json: unknown = await response.json();
  if (!response.ok) throw new ResponseError(cast<{ error: string }>(json).error);
  return cast<{ deleted_comment_ids: string[] }>(json).deleted_comment_ids;
};

type FetchPaginatedCommentsArgs = {
  commentable_id: string;
  purchase_id: null | string;
  page: null | number;
};
export const fetchPaginatedComments = async ({
  commentable_id,
  purchase_id,
  page,
}: FetchPaginatedCommentsArgs): Promise<PaginatedComments> => {
  const response = await request({
    method: "GET",
    accept: "json",
    url: Routes.custom_domain_post_comments_path(commentable_id, { purchase_id, page }),
  });
  if (!response.ok) throw new ResponseError();
  return cast<PaginatedComments>(await response.json());
};
