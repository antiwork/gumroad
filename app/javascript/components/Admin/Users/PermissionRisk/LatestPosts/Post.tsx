import React from "react";

import type { Post } from "$app/data/workflows";

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

export default Post;
