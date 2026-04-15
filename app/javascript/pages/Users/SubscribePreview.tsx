import { usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { Logo } from "$app/components/Logo";
import { Avatar } from "$app/components/ui/Avatar";

type Props = {
  avatar_url: string;
  title: string;
};

export default function SubscribePreview() {
  const { avatar_url, title } = cast<Props>(usePage().props);

  return (
    <div className="override grid h-full w-full grid-cols-[27.5%_1fr] items-center gap-6 p-6">
      <Avatar className="w-full! rounded-[10rem]" src={avatar_url} />
      <section className="override grid gap-3">
        <Logo className="text-sm opacity-20" />
        <h1 className="line-clamp-2 text-3xl">{title}</h1>
        <div>
          <Button color="accent">Subscribe</Button>
        </div>
      </section>
    </div>
  );
}

SubscribePreview.loggedInUserLayout = true;
