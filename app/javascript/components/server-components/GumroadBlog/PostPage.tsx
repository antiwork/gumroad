import { EditorContent } from "@tiptap/react";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { incrementPostViews } from "$app/data/view_event";
import { register } from "$app/utils/serverComponentUtil";

import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useRichTextEditor } from "$app/components/RichTextEditor";
import { formatPostDate } from "$app/components/server-components/Profile/PostPage";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useRunOnce } from "$app/components/useRunOnce";

const PostPage = ({
  external_id,
  subject,
  published_at,
  message,
  call_to_action,
}: {
  external_id: string;
  subject: string;
  published_at: string;
  message: string;
  call_to_action: { url: string; text: string } | null;
}) => {
  const userAgentInfo = useUserAgentInfo();
  const [pageLoaded, setPageLoaded] = React.useState(false);

  React.useEffect(() => setPageLoaded(true), []);
  useRunOnce(() => void incrementPostViews({ postId: external_id }));
  const editor = useRichTextEditor({
    ariaLabel: "Blog post",
    initialValue: pageLoaded ? message : null,
    editable: false,
  });
  const publishedAtFormatted = formatPostDate(published_at, userAgentInfo.locale);

  return (
    <main>
      <header>
        <h1>{subject}</h1>
        <time>{publishedAtFormatted}</time>
      </header>
      <article style={{ display: "grid", gap: "var(--spacer-6)" }}>
        {pageLoaded ? null : <LoadingSpinner width="2em" />}
        <EditorContent className="rich-text" editor={editor} />

        {call_to_action ? (
          <div className="grid">
            <p>
              <a
                className="button accent"
                href={call_to_action.url}
                target="_blank"
                style={{ whiteSpace: "normal" }}
                rel="noopener noreferrer"
              >
                {call_to_action.text}
              </a>
            </p>
          </div>
        ) : null}
      </article>
    </main>
  );
};

export default register({ component: PostPage, propParser: createCast() });
