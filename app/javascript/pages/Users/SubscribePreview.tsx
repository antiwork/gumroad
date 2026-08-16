import { usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { Avatar } from "$app/components/ui/Avatar";

type Props = {
  avatar_url: string;
  title: string;
  bio: string | null;
};

export default function SubscribePreview() {
  const { avatar_url, title, bio } = typia.assert<Props>(usePage().props);

  return (
    <div className="override flex h-full w-full items-center gap-6 p-8">
      <Avatar data-subscribe-preview-avatar className="size-28 w-28! rounded-full" src={avatar_url} />
      <section className="grid min-w-0 gap-2">
        <h1 className="truncate text-3xl">{title}</h1>
        {bio ? <p className="line-clamp-3 text-lg whitespace-pre-line text-muted">{bio}</p> : null}
      </section>
    </div>
  );
}

SubscribePreview.loggedInUserLayout = true;
