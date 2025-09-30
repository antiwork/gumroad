import * as React from "react";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";

import { Button } from "../Button";

type Props = {
  avatar_url: string;
  title: string;
};

export const SubscribePreview = ({ avatar_url, title }: Props) => (
  <div className="w-full h-full grid items-center p-7 gap-8" style={{ gridTemplateColumns: '27.5% 1fr' }}>
    <img className="w-full aspect-square border border-gray-300 flex-shrink-0" style={{ borderRadius: '10rem' }} src={avatar_url} />
    <div className="ml-1.5">
      <span className="logo-full text-sm opacity-20" />
      <h1 className="text-3xl leading-tight overflow-hidden mb-3 mt-3" style={{ display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', fontSize: '2rem' }}>{title}</h1>
      <Button color="accent" className="w-fit">Subscribe</Button>
    </div>
  </div>
);

export default register({ component: SubscribePreview, propParser: createCast() });
