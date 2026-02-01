import { Head, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";

type Props = {
  avatar_url: string;
  title: string;
  custom_styles: string;
};

export default function SubscribePreview() {
  const { custom_styles, avatar_url, title } = cast<Props>(usePage().props);

  return (
    <>
      <Head>
        <style>{custom_styles}</style>
      </Head>

      <div className="override grid h-full w-full grid-cols-[27.5%_1fr] items-center gap-6 p-6">
        <img className="user-avatar w-full!" src={avatar_url} />
        <section className="override grid gap-3">
          <span className="logo-full text-sm opacity-20" />
          <h1 className="line-clamp-2 text-3xl">{title}</h1>
          <div>
            <Button color="accent">Subscribe</Button>
          </div>
        </section>
      </div>
    </>
  );
}

SubscribePreview.loggedInUserLayout = true;
