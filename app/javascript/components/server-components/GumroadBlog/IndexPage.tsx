import cx from "classnames";
import * as React from "react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { formatPostDate } from "$app/components/server-components/Profile/PostPage";
import { Tabs, Tab } from "$app/components/ui/Tabs";

import placeholderFeatureImage from "../../../../assets/images/blog/post-placeholder.jpg";

interface TagProps {
  name: string;
  count?: number;
  showCount?: boolean;
  active?: boolean;
  size?: "sm" | "base";
}

const Tag = ({ name, count, showCount = false, active = false, size = "sm" }: TagProps) => {
  const sizeClasses = {
    sm: "text-sm",
    base: "text-base",
  };

  const commonClasses = `inline-block rounded px-2 py-2 leading-none mr-2 mb-2`;
  const activeStateClass = active ? "bg-black text-white" : "bg-white text-black border border-black";

  return (
    <span className={cx(commonClasses, sizeClasses[size], activeStateClass)}>
      {showCount && count ? `${name} (${count})` : name}
    </span>
  );
};

interface Post {
  url: string;
  subject: string;
  published_at: string;
  featured_image_url: string | null;
  message_snippet: string;
  tags: string[];
}

interface IndexPageProps {
  posts: Post[];
}

const useDynamicClamp = (containerRef: React.RefObject<HTMLElement>, textRef: React.RefObject<HTMLElement>) => {
  const [clamp, setClamp] = useState<number | undefined>(undefined);
  const lineHeightRef = useRef<number | undefined>(undefined);

  useEffect(() => {
    if (!lineHeightRef.current && textRef.current) {
      lineHeightRef.current = parseFloat(getComputedStyle(textRef.current).lineHeight);
    }
  }, []);

  useEffect(() => {
    const container = containerRef.current;
    const lineHeight = lineHeightRef.current;
    if (clamp !== undefined || !container || !lineHeight) return;

    const id = requestAnimationFrame(() => {
      const availableHeight = container.getBoundingClientRect().height;
      setClamp(Math.floor(availableHeight / lineHeight));
    });

    return () => cancelAnimationFrame(id);
  }, [clamp]);

  return clamp;
};

const PostCard = ({
  post,
  title_size_class = "text-2xl",
  usePlaceholder = false,
}: {
  post: Post;
  title_size_class?: string;
  usePlaceholder?: boolean;
}) => {
  const snippetContainerRef = useRef<HTMLDivElement>(null);
  const snippetRef = useRef<HTMLParagraphElement>(null);
  const clamp = useDynamicClamp(snippetContainerRef, snippetRef);

  const featureImageUrl = post.featured_image_url || (usePlaceholder ? placeholderFeatureImage : null);
  const showSnippet = !featureImageUrl && post.message_snippet && (clamp === undefined || clamp > 0);

  return (
    <article className="h-full">
      <a
        href={post.url}
        className={cx(
          "override grid h-full overflow-hidden rounded-lg border border-black bg-white text-black no-underline transition-all duration-200 ease-in-out hover:-translate-x-1 hover:-translate-y-1 hover:shadow-[3px_3px_#000]",
          { "grid-rows-[auto_1fr]": !!featureImageUrl },
        )}
      >
        {featureImageUrl ? (
          <figure className="aspect-[1800/1080] overflow-hidden border-b border-black">
            <img src={featureImageUrl} alt={post.subject} className="h-full w-full object-cover" loading="lazy" />
          </figure>
        ) : null}

        <div className="flex h-full flex-grow flex-col space-y-2 p-6">
          <h3 className={cx("flex-none leading-tight", title_size_class)}>{post.subject}</h3>
          {showSnippet ? (
            <div className="relative flex-1" ref={snippetContainerRef}>
              <p
                className="text-md inset-0 flex-1 overflow-hidden text-ellipsis text-dark-gray opacity-90"
                style={{
                  position: clamp === undefined ? "absolute" : "relative",
                  display: "-webkit-box",
                  WebkitBoxOrient: "vertical",
                  WebkitLineClamp: clamp,
                }}
                ref={snippetRef}
              >
                {post.message_snippet}
              </p>
            </div>
          ) : (
            <div className="flex-1" />
          )}
          <p className="text-md flex-none text-dark-gray">{formatPostDate(post.published_at, "en-US")}</p>
          {post.tags.length > 0 && (
            <div className="flex flex-none flex-row flex-wrap">
              {post.tags.map((tag) => (
                <Tag key={tag} name={tag} />
              ))}
            </div>
          )}
        </div>
      </a>
    </article>
  );
};

const CompactPostItem = ({ post }: { post: Post }) => (
  <li className="border-gray-300 py-4 first:pt-0">
    <a href={post.url} className="hover:text-pink-600 group flex items-end justify-between text-black no-underline">
      <div className="override grid grid-cols-1 gap-1">
        <h4 className="mb-0.5 text-2xl font-normal">{post.subject}</h4>
        <p className="text-gray-500 pb-0.5 text-base">{formatPostDate(post.published_at, "en-US")}</p>
      </div>
      <div className="border-gray-400 ml-3 mr-1 flex h-10 w-10 flex-shrink-0 items-center justify-center self-end rounded-md border p-2 transition-all duration-200 ease-in-out group-hover:-translate-x-px group-hover:-translate-y-px group-hover:shadow-[2px_2px_0_0_#000]">
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <path d="M5 12h14M12 5l7 7-7 7" />
        </svg>
      </div>
    </a>
  </li>
);

const CompactPostSection = ({ product_updates }: { product_updates: Post[] }) => (
  <div className="mb-8 hidden w-full lg:mb-0 lg:block lg:w-[calc(33%-0.9375rem)]">
    <div className="flex h-full flex-col">
      {product_updates.length > 0 ? (
        <ul className="flex-grow divide-y overflow-y-auto">
          {product_updates.map((post) => (
            <CompactPostItem key={post.url} post={post} />
          ))}
        </ul>
      ) : (
        <p className="text-gray-500">No product updates.</p>
      )}
    </div>
  </div>
);

const PostsGrid = ({ posts }: { posts: Post[] }) => (
  <section className="mt-8">
    {posts.length > 0 ? (
      <div className="override grid grid-cols-1 gap-8 md:grid-cols-2 lg:grid-cols-3 lg:gap-8">
        {posts.map((post) => (
          <PostCard key={post.url} post={post} />
        ))}
      </div>
    ) : (
      <p className="text-gray-600 col-span-full py-10 text-center">No posts found.</p>
    )}
  </section>
);

const TagSelector = ({
  postsByTags,
  allPostsCount,
  activeTab,
  setActiveTab,
}: {
  postsByTags: Record<string, Post[]>;
  allPostsCount: number;
  activeTab: string | null;
  setActiveTab: (tag: string | null) => void;
}) => {
  const tags = Object.keys(postsByTags);

  if (tags.length === 0) {
    return null;
  }

  const isAllPostsActive = activeTab === null;

  const selectTag = useCallback((tag: string) => {
    setActiveTab(tag);
  }, []);
  const selectAll = useCallback(() => {
    setActiveTab(null);
  }, []);

  return (
    <div className="mb-12">
      <Tabs>
        <Tab isSelected={isAllPostsActive} onClick={selectAll}>
          All Posts {isAllPostsActive ? <span className="ml-1.5 text-base opacity-85">({allPostsCount})</span> : null}
        </Tab>
        {tags.map((tag) => {
          const isActive = activeTab === tag;
          const count = postsByTags[tag]?.length || 0;

          return (
            <Tab key={tag} isSelected={isActive} onClick={() => selectTag(tag)}>
              {tag} {isActive ? <span className="ml-1.5 text-base opacity-85">({count})</span> : null}
            </Tab>
          );
        })}
      </Tabs>
    </div>
  );
};

const IndexPage = ({ posts = [] }: IndexPageProps) => {
  const [activeTab, setActiveTab] = useState<string | null>(null);

  const featured_post = posts[0];
  const product_updates = posts.slice(1, 4);

  const postsByTags = useMemo(() => {
    const map: Record<string, Post[]> = {};
    posts.forEach((post) => {
      post.tags.forEach((tag) => {
        if (!map[tag]) {
          map[tag] = [];
        }
        map[tag].push(post);
      });
    });
    return map;
  }, [posts]);

  const postsForGrid = useMemo(() => (activeTab ? postsByTags[activeTab] : posts.slice(1)), [activeTab, postsByTags]);

  return (
    <div className="scoped-tailwind-preflight">
      <div className="container mx-auto px-8 py-24 sm:px-6 lg:px-8">
        <header className="mb-8">
          <h1 className="text-6xl text-black">Blog</h1>
        </header>
        <TagSelector
          postsByTags={postsByTags}
          allPostsCount={posts.length}
          activeTab={activeTab}
          setActiveTab={setActiveTab}
        />

        {activeTab ? null : (
          <div className="mb-8 flex flex-row items-start lg:gap-[1.875rem]">
            <section className="mb-0 w-full lg:mb-0 lg:w-[calc(67%-0.9375rem)]">
              {featured_post ? (
                <PostCard post={featured_post} title_size_class="text-2xl md:text-4xl" usePlaceholder />
              ) : (
                <p className="text-gray-600 border-gray-300 flex min-h-[300px] items-center justify-center rounded border-2 border-dashed p-8 text-center">
                  No featured post available.
                </p>
              )}
            </section>
            <CompactPostSection product_updates={product_updates} />
          </div>
        )}

        {postsForGrid ? <PostsGrid posts={postsForGrid} /> : null}
      </div>
    </div>
  );
};

export default register({ component: IndexPage, propParser: createCast() });
