import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "../Button";

type Props = {
  avatar_url: string;
  title: string;
};

export const SubscribePreview = ({ avatar_url, title }: Props) => (
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
);

export default register({ component: SubscribePreview, propParser: createCast() });
