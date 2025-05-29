import cx from "classnames";
import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { formatPostDate } from "$app/components/server-components/Profile/PostPage";

interface Post {
  url: string;
  subject: string;
  published_at: string;
  featured_image_url: string | null;
}

interface IndexPageProps {
  posts: Post[];
}

const PostCard = ({ post, title_size_class = "text-2xl" }: { post: Post; title_size_class?: string }) => (
  <article>
    <a
      href={post.url}
      className="override block grid grid-rows-[auto_1fr] overflow-hidden rounded-lg border border-black bg-white text-black no-underline transition-all duration-200 ease-in-out hover:-translate-x-1 hover:-translate-y-1 hover:shadow-[3px_3px_#000]"
    >
      {post.featured_image_url ? (
        <figure className="overflow-hidden border-b border-black">
          <img src={post.featured_image_url} alt={post.subject} className="h-auto w-full" loading="lazy" />
        </figure>
      ) : null}
      <header className="flex flex-grow flex-col p-6">
        <div>
          <h3 className={cx("mb-1 leading-tight", title_size_class)}>{post.subject}</h3>
          <p className="text-md text-gray-600 mb-2">{formatPostDate(post.published_at, "en-US")}</p>
        </div>
      </header>
    </a>
  </article>
);

const CompactPostItem = ({ post }: { post: Post }) => (
  <li className="border-gray-300 py-4">
    <a
      href={post.url}
      className="hover:text-pink-600 group block flex items-end justify-between text-black no-underline"
    >
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

const IndexPage = ({ posts = [] }: IndexPageProps) => {
  const featured_post = posts[0];
  const product_updates = posts.slice(1, 4);
  const postsForGrid = posts.slice(1);

  return (
    <div className="scoped-tailwind-preflight">
      <div className="container mx-auto px-8 py-24 sm:px-6 lg:px-8">
        <header className="mb-8">
          <h1 className="text-6xl text-black">Blog</h1>
        </header>

        <div className="mb-8 flex flex-row items-start lg:gap-[1.875rem]">
          <section className="mb-0 w-full lg:mb-0 lg:w-[calc(67%-0.9375rem)]">
            {featured_post ? (
              <PostCard post={featured_post} title_size_class="text-3xl lg:text-4xl" />
            ) : (
              <p className="text-gray-600 border-gray-300 flex min-h-[300px] items-center justify-center rounded border-2 border-dashed p-8 text-center">
                No featured post available.
              </p>
            )}
          </section>
          <CompactPostSection product_updates={product_updates} />
        </div>

        <PostsGrid posts={postsForGrid} />
      </div>
    </div>
  );
};

export default register({ component: IndexPage, propParser: createCast() });
