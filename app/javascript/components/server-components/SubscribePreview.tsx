import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "../Button";
import { UserAvatar } from "../UserAvatar";

type Props = {
  avatar_url: string;
  title: string;
};

export const SubscribePreview = ({ avatar_url, title }: Props) => (
  <div className="subscribe-preview">
    <UserAvatar src={avatar_url} className="w-full" />
    <section>
      <span className="logo-full" />
      <h1>{title}</h1>
      <div>
        <Button color="accent">Subscribe</Button>
      </div>
    </section>
  </div>
);

export default register({ component: SubscribePreview, propParser: createCast() });
