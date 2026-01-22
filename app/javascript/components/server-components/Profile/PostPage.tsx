import { EditorContent } from "@tiptap/react";
import { parseISO } from "date-fns";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { PaginatedComments } from "$app/data/comments";
import { incrementPostViews } from "$app/data/view_event";
import { CreatorProfile } from "$app/parsers/profile";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { CommentsMetadataProvider, PostCommentsSection } from "$app/components/Post/PostCommentsSection";
import { Layout } from "$app/components/Profile/Layout";
import { useRichTextEditor } from "$app/components/RichTextEditor";
import { useUserAgentInfo } from "$app/components/UserAgent";
import { useRunOnce } from "$app/components/useRunOnce";

const dateFormatOptions: Intl.DateTimeFormatOptions = { month: "long", day: "numeric", year: "numeric" };
export const formatPostDate = (date: string | null, locale: string): string =>
  (date ? parseISO(date) : new Date()).toLocaleDateString(locale, dateFormatOptions);

type Props = {
  subject: string;
  slug: string;
  external_id: string;
  purchase_id: string | null;
  published_at: string | null;
  message: string;
  call_to_action: { url: string; text: string } | null;
  download_url: string | null;
  has_posts_on_profile: boolean;
  recent_posts: {
    name: string;
    slug: string;
    published_at: string | null;
    truncated_description: string;
    purchase_id: string | null;
  }[];
  paginated_comments: PaginatedComments | null;
  comments_max_allowed_depth: number;
  creator_profile: CreatorProfile;
};

const PostPage = ({
  subject,
  external_id,
  purchase_id,
  published_at,
  message,
  call_to_action,
  download_url,
  has_posts_on_profile,
  recent_posts,
  paginated_comments,
  comments_max_allowed_depth,
  creator_profile,
}: Props) => {
  const userAgentInfo = useUserAgentInfo();
  const [pageLoaded, setPageLoaded] = React.useState(false);
  React.useEffect(() => setPageLoaded(true), []);
  useRunOnce(() => void incrementPostViews({ postId: external_id }));
  const editor = useRichTextEditor({
    ariaLabel: "Email message",
    initialValue: pageLoaded ? message : null,
    editable: false,
  });
  const publishedAtFormatted = formatPostDate(published_at, userAgentInfo.locale);

  return (
    <Layout creatorProfile={creator_profile}>
      <header className="border-b border-border">
        <div className="mx-auto grid max-w-6xl gap-2 px-4 py-8 lg:px-0">
          <h1 className="text-4xl">{subject}</h1>
          <time>{publishedAtFormatted}</time>
        </div>
      </header>
      <article className="border-b border-border">
        <div className="mx-auto grid max-w-6xl gap-8 p-4 pt-8 text-lg lg:px-0 lg:pt-12 lg:pb-8">
          {pageLoaded ? null : <LoadingSpinner className="size-8" />}
          <EditorContent className="rich-text" editor={editor} />
        </div>

        {call_to_action || download_url ? (
          <div className="mx-auto mb-4 grid max-w-6xl px-4 lg:px-0">
            {call_to_action ? (
              <p>
                <Button asChild color="accent">
                  <a
                    href={call_to_action.url}
                    target="_blank"
                    style={{ whiteSpace: "normal" }}
                    rel="noopener noreferrer"
                  >
                    {call_to_action.text}
                  </a>
                </Button>
              </p>
            ) : null}
            {download_url ? (
              <p>
                <Button asChild color="accent">
                  <a href={download_url}>View content</a>
                </Button>
              </p>
            ) : null}
          </div>
        ) : null}
      </article>
      {paginated_comments ? (
        <CommentsMetadataProvider
          value={{
            seller_id: creator_profile.external_id,
            commentable_id: external_id,
            purchase_id,
            max_allowed_depth: comments_max_allowed_depth,
          }}
        >
          <PostCommentsSection paginated_comments={paginated_comments} />
        </CommentsMetadataProvider>
      ) : null}
      {recent_posts.length > 0 ? (
        <>
          {recent_posts.map((post) => (
            <a
              key={post.slug}
              href={Routes.custom_domain_view_post_path(post.slug, { purchase_id })}
              className="flex justify-between border-b border-border px-4 py-8 no-underline lg:py-12"
            >
              <div>
                <h2>{post.name}</h2>
                <time>{formatPostDate(post.published_at, userAgentInfo.locale)}</time>
              </div>
              <Icon name="arrow-diagonal-up-right" className="text-lg" />
            </a>
          ))}
          {has_posts_on_profile ? (
            <a
              href={Routes.root_path()}
              className="flex justify-between border-b border-border px-4 py-8 no-underline lg:py-12"
            >
              <h2>See all posts from {creator_profile.name}</h2>
              <Icon name="arrow-diagonal-up-right" className="text-lg" />
            </a>
          ) : null}
        </>
      ) : null}
    </Layout>
  );
};

export default register({ component: PostPage, propParser: createCast() });
