import * as React from "react";

export const AuthorByline = ({
  name,
  profileUrl,
  avatarUrl,
}: {
  name: string;
  profileUrl: string;
  avatarUrl?: string | undefined;
}) => (
  <a href={profileUrl} target="_blank" className="relative flex items-center gap-2" rel="noreferrer">
    {avatarUrl ? <img className="user-avatar" src={avatarUrl} /> : null}
    {name}
  </a>
);
