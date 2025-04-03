import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "../Button";

type Props = {
  avatar_url: string;
  title: string;
};

export const SubscribePreview = ({ avatar_url, title }: Props) => (
  <div className="subscribe-preview">
    <img className="user-avatar" src={avatar_url} />
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
