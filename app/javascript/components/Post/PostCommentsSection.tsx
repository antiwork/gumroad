import { parseISO } from "date-fns";
import * as React from "react";

import {
  addComment as addCommentRequest,
  deleteComment as deleteCommentRequest,
  fetchPaginatedComments,
  updateComment,
  Comment,
  PaginatedComments,
} from "$app/data/comments";
import { classNames } from "$app/utils/classNames";
import { formatDate } from "$app/utils/date";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useAppDomain } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Modal } from "$app/components/Modal";
import { Popover } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { UserAvatar } from "$app/components/server-components/CommunitiesPage/UserAvatar";

import defaultUserAvatar from "$assets/images/user-avatar.png";

type CommentsMetadata = {
  seller_id: string;
  commentable_id: string;
  purchase_id: null | string;
  max_allowed_depth: number;
};
const Context = React.createContext<CommentsMetadata | null>(null);
export const CommentsMetadataProvider = Context.Provider;
export const useCommentsMetadata = (): CommentsMetadata => {
  const value = React.useContext(Context);
  if (value === null) {
    throw new Error(
      "Cannot read from CommentsMetadata context, make sure CommentsMetadataProvider is used higher up in the tree",
    );
  }

  return value;
};
type CommentWithReplies = Comment & { replies: CommentWithReplies[] };

type Props = { paginated_comments: PaginatedComments };
export const PostCommentsSection = ({ paginated_comments }: Props) => {
  const { commentable_id, purchase_id } = useCommentsMetadata();
  const loggedInUser = useLoggedInUser();

  const [loadingMore, setLoadingMore] = React.useState(false);
  const [data, setData] = React.useState<PaginatedComments>(paginated_comments);
  const loadMoreComments = async () => {
    if (loadingMore) return;
    setLoadingMore(true);
    try {
      const loaded = await fetchPaginatedComments({
        commentable_id,
        purchase_id,
        page: data.pagination.next,
      });
      setData({ ...data, pagination: loaded.pagination, comments: [...data.comments, ...loaded.comments] });
    } catch (e) {
      assertResponseError(e);
      showAlert("An error occurred while loading more comments", "error");
    }
    setLoadingMore(false);
  };

  const [commentToDelete, setCommentToDelete] = React.useState<{ comment: Comment; deleting: boolean } | null>(null);
  const deleteComment = async () => {
    if (!commentToDelete) return;
    try {
      await deleteCommentRequest({
        commentable_id,
        purchase_id,
        id: commentToDelete.comment.id,
      });
      showAlert("Successfully deleted the comment", "success");
      setCommentToDelete(null);
      setData((data) => ({
        ...data,
        comments: data.comments.filter((comment) => comment.id !== commentToDelete.comment.id),
        count: data.count - 1,
      }));
    } catch (e) {
      assertResponseError(e);
      showAlert("An error occurred while deleting the comment", "error");
    }
  };

  const [draft, setDraft] = React.useState<string | null>(null);
  const [posting, setPosting] = React.useState(false);
  const upsertComment = (comment: Comment) => {
    const existing = data.comments.find(({ id }) => id === comment.id);
    if (existing)
      setData((data) => ({
        ...data,
        comments: data.comments.map((c) => (c.id === comment.id ? comment : c)),
      }));
    else setData((data) => ({ ...data, comments: [...data.comments, comment], count: data.count + 1 }));
  };
  const addComment = async () => {
    if (!draft) return;
    setPosting(true);

    try {
      const comment = await addCommentRequest({
        commentable_id,
        purchase_id,
        content: draft,
        parent_id: null,
      });
      showAlert("Successfully posted your comment", "success");
      upsertComment(comment);
      setDraft(null);
    } catch (e) {
      assertResponseError(e);
      showAlert(`An error occurred while posting your comment - ${e.message}`, "error");
    }
    setPosting(false);
  };
  const confirmCommentDeletion = (comment: Comment) => {
    setCommentToDelete({ comment, deleting: false });
  };

  const nestedComments = React.useMemo(() => nestComments(data.comments), [data.comments]);

  return (
    <section className="comments comments-section grid gap-8 border-b border-border p-4 lg:py-12">
      <h2>
        {data.count} {data.count === 1 ? "comment" : "comments"}
      </h2>
      <CommentTextarea value={draft || ""} onChange={(event) => setDraft(event.target.value)} disabled={posting}>
        <Button
          color="primary"
          disabled={!(loggedInUser || purchase_id) || !draft || posting}
          onClick={() => void addComment()}
        >
          {posting ? "Posting..." : "Post"}
        </Button>
      </CommentTextarea>
      {nestedComments.length > 0 ? <hr /> : null}
      <div className="grid gap-6">
        {nestedComments.map((comment) => (
          <CommentContainer
            key={comment.id}
            comment={comment}
            upsertComment={upsertComment}
            confirmCommentDeletion={confirmCommentDeletion}
          />
        ))}
      </div>
      {data.pagination.next !== null ? (
        <div className="mt-6 flex justify-center">
          <Button disabled={loadingMore} onClick={() => void loadMoreComments()}>
            {loadingMore ? "Loading more comments..." : "Load more comments"}
          </Button>
        </div>
      ) : null}

      {commentToDelete ? (
        <Modal
          open
          allowClose={commentToDelete.deleting}
          onClose={() => setCommentToDelete(null)}
          title="Delete comment"
          footer={
            <>
              <Button disabled={commentToDelete.deleting} onClick={() => setCommentToDelete(null)}>
                Cancel
              </Button>
              {commentToDelete.deleting ? (
                <Button color="danger" disabled>
                  Deleting...
                </Button>
              ) : (
                <Button color="danger" onClick={() => void deleteComment()}>
                  Confirm
                </Button>
              )}
            </>
          }
        >
          <h4>Are you sure?</h4>
        </Modal>
      ) : null}
    </section>
  );
};

type CommentContainerProps = {
  comment: CommentWithReplies;
  upsertComment: (comment: Comment) => void;
  confirmCommentDeletion: (comment: Comment) => void;
};
const CommentContainer = ({ comment, upsertComment, confirmCommentDeletion }: CommentContainerProps) => {
  const { seller_id, purchase_id, max_allowed_depth, commentable_id } = useCommentsMetadata();
  const loggedInUser = useLoggedInUser();
  const [isPosting, setIsPosting] = React.useState(false);
  const [editDraft, setEditDraft] = React.useState<string | null>(null);
  const update = async () => {
    if (!editDraft) return;
    setIsPosting(true);
    try {
      const updated = await updateComment({
        commentable_id,
        purchase_id,
        id: comment.id,
        content: editDraft,
      });
      showAlert("Successfully updated the comment", "success");
      upsertComment(updated);
    } catch (e) {
      assertResponseError(e);
      showAlert(`An error occurred while updating the comment - ${e.message}`, "error");
    }
    setIsPosting(false);
  };
  const [replyDraft, setReplyDraft] = React.useState<string | null>(null);
  const postReply = async () => {
    if (!replyDraft) return;
    setIsPosting(true);
    try {
      const reply = await addCommentRequest({
        commentable_id,
        purchase_id,
        content: replyDraft,
        parent_id: comment.id,
      });
      showAlert("Successfully posted your comment", "success");
      setReplyDraft(null);
      upsertComment(reply);
    } catch (e) {
      assertResponseError(e);
      showAlert(`An error occurred while posting your comment - ${e.message}`, "error");
    }
    setIsPosting(false);
  };

  return (
    <article className="override grid grid-cols-[max-content_1fr] gap-3">
      <UserAvatar size="large" className="col-start-1 row-span-2 row-start-1" alt="" src={comment.author_avatar_url} />
      <div className="relative col-start-2 grid gap-3 whitespace-pre-wrap">
        {comment.replies.length > 0 || replyDraft != null ? (
          <div className="absolute top-12 -left-9 h-[calc(100%-3rem)] border-l border-border" />
        ) : null}
        <header className="flex flex-wrap items-center gap-3">
          <span className="text-decoration-none font-bold">{comment.author_name}</span>
          <time title={formatDate(parseISO(comment.created_at))}>{comment.created_at_humanized}</time>
          {comment.author_id === seller_id ? <span className="pill small">Creator</span> : null}
          <div className="ml-auto">
            {comment.is_editable || comment.is_deletable ? (
              <Popover aria-label="Open comment action menu" trigger={<Icon name="three-dots" />}>
                {(close) => (
                  <div className="grid gap-3" onClick={close}>
                    {comment.is_editable ? (
                      <Button onClick={() => setEditDraft(comment.content.original)}>Edit</Button>
                    ) : null}
                    {comment.is_deletable ? (
                      <Button color="danger" onClick={() => confirmCommentDeletion(comment)}>
                        Delete
                      </Button>
                    ) : null}
                  </div>
                )}
              </Popover>
            ) : null}
          </div>
        </header>
        {editDraft ? (
          <CommentTextarea
            value={editDraft}
            onChange={(event) => setEditDraft(event.target.value)}
            disabled={isPosting}
            showAvatar={false}
          >
            <Button onClick={() => setEditDraft(null)} disabled={isPosting}>
              Cancel
            </Button>

            <Button color="primary" disabled={isPosting} onClick={() => void update()}>
              {isPosting ? "Updating..." : "Update"}
            </Button>
          </CommentTextarea>
        ) : (
          <p dangerouslySetInnerHTML={{ __html: comment.content.formatted }} />
        )}
        {replyDraft == null && comment.depth < max_allowed_depth ? (
          <footer>
            <button className="link" onClick={() => setReplyDraft("")}>
              Reply
            </button>
          </footer>
        ) : null}
      </div>
      <div className="col-start-2">
        {replyDraft != null ? (
          <div className="relative mt-5 -ml-6 max-w-none">
            <div className="absolute -top-12 right-full -left-3 h-18 w-3 rounded-bl-lg border-b border-l border-border" />
            {comment.replies.length > 0 ? (
              <div className="absolute top-0 -left-3 h-full border-l border-border" />
            ) : null}
            <CommentTextarea
              value={replyDraft}
              onChange={(event) => setReplyDraft(event.target.value)}
              disabled={isPosting}
            >
              <Button onClick={() => setReplyDraft(null)} disabled={isPosting}>
                Cancel
              </Button>

              <Button
                color="primary"
                disabled={!(loggedInUser || purchase_id) || isPosting}
                onClick={() => void postReply()}
              >
                {isPosting ? "Posting..." : "Post"}
              </Button>
            </CommentTextarea>
          </div>
        ) : null}
      </div>
      <div className="col-start-2">
        {comment.replies.map((reply, index) => (
          <div key={reply.id} className="relative mt-5 -ml-6 max-w-none">
            <div className="absolute -top-12 right-full -left-3 h-18 w-3 rounded-bl-lg border-b border-l border-border" />
            {index < comment.replies.length - 1 ? (
              <div className="absolute top-0 -left-3 h-full border-l border-border" />
            ) : null}
            <CommentContainer
              comment={reply}
              key={reply.id}
              upsertComment={upsertComment}
              confirmCommentDeletion={confirmCommentDeletion}
            />
          </div>
        ))}
      </div>
    </article>
  );
};

const CommentTextarea = ({
  children,
  showAvatar = true,
  ...props
}: React.ComponentProps<"textarea"> & { showAvatar?: boolean }) => {
  const appDomain = useAppDomain();
  const { purchase_id } = useCommentsMetadata();
  const loggedInUser = useLoggedInUser();
  const ref = React.useRef<HTMLTextAreaElement | null>(null);
  React.useEffect(() => {
    if (!ref.current) return;

    ref.current.style.height = "inherit";
    ref.current.style.height = `${ref.current.scrollHeight}px`;
  }, [props.value]);

  return (
    <div className={classNames("override grid gap-3", showAvatar && "relative grid-cols-[max-content_1fr]")}>
      {showAvatar ? (
        <UserAvatar
          size="large"
          className="col-start-1 row-span-2 row-start-1"
          alt=""
          src={loggedInUser?.avatarUrl ?? defaultUserAvatar}
        />
      ) : null}
      {loggedInUser || purchase_id ? (
        <textarea ref={ref} rows={1} placeholder="Write a comment" {...props} />
      ) : (
        <div>
          <a href={Routes.login_url({ host: appDomain })}>Log in</a> or{" "}
          <a href={Routes.signup_url({ host: appDomain })}>Register</a> to join the conversation
        </div>
      )}
      {loggedInUser != null || purchase_id != null ? <div className="flex justify-end gap-3">{children}</div> : null}
    </div>
  );
};

const nestComments = (comments: readonly Comment[], id: string | null = null): CommentWithReplies[] =>
  comments
    .filter((comment) => comment.parent_id === id)
    .map((comment) => ({ ...comment, replies: nestComments(comments, comment.id) }));
