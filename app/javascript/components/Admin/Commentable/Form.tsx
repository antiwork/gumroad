import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import type { CommentProps } from "$app/components/Admin/Commentable/Comment";
import { showAlert } from "$app/components/server-components/Alert";

type AdminCommentableFormProps = {
  endpoint: string;
  onCommentAdded: (comment: CommentProps) => void;
  commentableType: string;
};

type PageProps = {
  authenticity_token: string;
};

const AdminCommentableForm = ({ endpoint, onCommentAdded, commentableType }: AdminCommentableFormProps) => {
  const { authenticity_token } = usePage<PageProps>().props;
  const form = useForm("AdminAddComment", { comment: { content: "" }, authenticity_token });
  const {
    data: {
      comment: { content },
    },
    setData,
    processing,
  } = form;

  const onContentChange = React.useCallback(
    (event: React.ChangeEvent<HTMLTextAreaElement>) => {
      setData("comment.content", event.target.value);
    },
    [setData],
  );

  const onSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    // eslint-disable-next-line no-alert
    if (confirm("Are you sure you want to post this comment?")) {
      const formData = new FormData();
      formData.append("authenticity_token", authenticity_token);
      formData.append("comment[content]", content);
      const response = await request({
        method: "POST",
        url: endpoint,
        data: formData,
        accept: "json",
      });
      if (response.ok) {
        const { comment } = cast<{ comment: CommentProps }>(await response.json());
        showAlert("Successfully added comment.", "success");
        form.reset();
        onCommentAdded(comment);
      } else {
        showAlert("Failed to add comment.", "error");
      }
    }
  };

  return (
    <form onSubmit={(e) => void onSubmit(e)}>
      <input type="hidden" name="authenticity_token" value={authenticity_token} />
      <fieldset>
        <div className="input-with-button">
          <textarea
            name="comment[content]"
            rows={1}
            placeholder={`Comment on this ${commentableType}`}
            required
            value={content}
            onChange={onContentChange}
          />
          <button type="submit" className="button" disabled={processing}>
            {processing ? "Saving..." : "Add comment"}
          </button>
        </div>
      </fieldset>
    </form>
  );
};

export default AdminCommentableForm;
