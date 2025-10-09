import { EditorContent } from "@tiptap/react";
import cx from "classnames";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { incrementPostViews } from "$app/data/view_event";
import { register } from "$app/utils/serverComponentUtil";

import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useRichTextEditor } from "$app/components/RichTextEditor";
import { formatPostDate } from "$app/components/server-components/Profile/PostPage";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useRunOnce } from "$app/components/useRunOnce";

const BackToBlog = ({ className }: { className?: string }) => (
  <div className={cx("scoped-tailwind-preflight", className)}>
    <a href="/blog" className="mt-4 flex items-center font-medium text-pink-600 hover:text-pink-800">
      <Icon name="arrow-left" className="mr-1.5" style={{ width: 18, height: 18 }} />
      Back to Blog
    </a>
  </div>
);

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
    <div className="container mx-auto px-8 py-16 sm:px-6 md:py-24 lg:px-8">
      <div className="mx-auto max-w-3xl">
        <BackToBlog className="mb-6" />
        <header>
          <h1 className="mb-4">{subject}</h1>
          <time className="text-dark-gray">{publishedAtFormatted}</time>
        </header>
        <div className="mx-auto mt-6 grid max-w-3xl justify-items-center gap-6 border-t py-12 text-xl">
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
        </div>
      </div>
    </div>
  );
};

export default register({ component: PostPage, propParser: createCast() });
