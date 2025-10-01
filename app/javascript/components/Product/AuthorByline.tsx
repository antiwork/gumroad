import * as React from "react";

import { UserAvatar } from "$app/components/ui/UserAvatar";

export const AuthorByline = ({
  name,
  profileUrl,
  avatarUrl,
}: {
  name: string;
  profileUrl: string;
  avatarUrl?: string | undefined;
}) => (
  <a href={profileUrl} target="_blank" className="user relative" rel="noreferrer">
    {avatarUrl ? <UserAvatar src={avatarUrl} /> : null}
    {name}
  </a>
);
