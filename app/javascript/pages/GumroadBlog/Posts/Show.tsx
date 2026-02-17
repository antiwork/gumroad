import { Link, usePage } from "@inertiajs/react";
import { EditorContent } from "@tiptap/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { incrementPostViews } from "$app/data/view_event";
import { formatPostDate } from "$app/utils/date";

import { NavigationButton } from "$app/components/Button";
import { BlogLayout } from "$app/components/GumroadBlog/Layout";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { useRichTextEditor } from "$app/components/RichTextEditor";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useRunOnce } from "$app/components/useRunOnce";

type ShowPageProps = {
  external_id: string;
  subject: string;
  published_at: string;
  message: string;
  call_to_action: { url: string; text: string } | null;
};

const BackToBlog = () => (
  <Link
    href={Routes.gumroad_blog_root_path()}
    className="mt-4 flex items-center font-medium text-pink-600 hover:text-pink-800"
  >
    <Icon name="arrow-left" className="mr-1.5" style={{ width: 18, height: 18 }} />
    Back to Blog
  </Link>
);

function ShowPage() {
  const { external_id, subject, published_at, message, call_to_action } = cast<ShowPageProps>(usePage().props);
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
    <BlogLayout>
      <div className="scoped-tailwind-preflight">
        <div className="container mx-auto px-8 py-16 sm:px-6 md:py-24 lg:px-8">
          <div className="mx-auto max-w-3xl">
            <div className="mb-12 hover:cursor-pointer">
              <BackToBlog />
            </div>
            <header className="mb-8">
              <h1 className="mb-4 text-[2.5rem] leading-[1.2] font-normal">{subject}</h1>
              <time className="text-lg text-dark-gray">{publishedAtFormatted}</time>
            </header>
            <div className="mx-auto mt-8 grid max-w-3xl justify-items-center gap-6 border-t border-black py-12 text-xl">
              {pageLoaded ? null : <LoadingSpinner className="size-8" />}
              <EditorContent className="rich-text" editor={editor} />

              {call_to_action ? (
                <div className="grid">
                  <p>
                    <NavigationButton
                      href={call_to_action.url}
                      target="_blank"
                      style={{ whiteSpace: "normal" }}
                      rel="noopener noreferrer"
                      color="accent"
                    >
                      {call_to_action.text}
                    </NavigationButton>
                  </p>
                </div>
              ) : null}
            </div>
          </div>
        </div>
      </div>
    </BlogLayout>
  );
}

ShowPage.loggedInUserLayout = true;

export default ShowPage;
