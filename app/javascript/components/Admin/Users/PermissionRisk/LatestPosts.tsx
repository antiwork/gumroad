import React from "react";
import { cast } from "ts-safe-cast";

import { request } from "$app/utils/request";

import Loading from "$app/components/Admin/Loading";
import type { User } from "$app/components/Admin/Users/User";

type LatestPostsProps = {
  user: User;
};

export type PostProps = {
  id: number;
  name: string;
  created_at: string;
};

const Post = ({ name, created_at }: PostProps) => (
  <div>
    <h5>{name}</h5>
    <time>{created_at}</time>
  </div>
);

const LatestPostsContent = ({ posts, isLoading }: { posts: PostProps[]; isLoading: boolean }) => {
  if (isLoading) return <Loading />;
  if (posts.length > 0)
    return (
      <div className="stack">
        {posts.map(({ id, name, created_at }) => (
          <Post key={id} id={id} name={name} created_at={created_at} />
        ))}
      </div>
    );
  return (
    <div className="info" role="status">
      No posts created.
    </div>
  );
};

const LastestPosts = ({ user }: LatestPostsProps) => {
  const [open, setOpen] = React.useState(false);
  const [isLoading, setIsLoading] = React.useState(false);
  const [posts, setPosts] = React.useState<PostProps[]>([]);

  const fetchPosts = async () => {
    setIsLoading(true);
    const response = await request({
      method: "GET",
      url: Routes.admin_user_latest_posts_path(user.id),
      accept: "json",
    });
    setPosts(cast<PostProps[]>(await response.json()));
    setIsLoading(false);
  };

  const onToggle = (e: React.MouseEvent<HTMLDetailsElement>) => {
    setOpen(e.currentTarget.open);
    if (e.currentTarget.open) {
      void fetchPosts();
    }
  };

  return (
    <>
      <hr />
      <details open={open} onToggle={onToggle}>
        <summary>
          <h3>Last posts</h3>
        </summary>
        <LatestPostsContent posts={posts} isLoading={isLoading} />
      </details>
    </>
  );
};

export default LastestPosts;
