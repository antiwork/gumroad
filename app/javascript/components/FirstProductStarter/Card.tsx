import * as React from "react";

import { Button } from "$app/components/Button";

import type { ProductOption } from "./types";

import courseIcon from "$assets/images/native_types/course.png";
import digitalIcon from "$assets/images/native_types/digital.png";
import ebookIcon from "$assets/images/native_types/ebook.png";
import membershipIcon from "$assets/images/native_types/membership.png";

const NATIVE_TYPE_ICONS: Record<ProductOption["native_type"], string> = {
  digital: digitalIcon,
  course: courseIcon,
  ebook: ebookIcon,
  membership: membershipIcon,
};

type Props = {
  option: ProductOption;
  onCreate: () => void;
  creating: boolean;
  disabled: boolean;
};

export const OptionCard = ({ option, onCreate, creating, disabled }: Props) => (
  <div className="flex h-full min-h-[20rem] flex-col gap-3 rounded border border-border bg-background p-4 transition hover:shadow">
    <img src={NATIVE_TYPE_ICONS[option.native_type]} alt={option.native_type} className="size-12 self-start" />
    <h3 className="line-clamp-2 font-semibold">{option.name}</h3>
    <p className="text-xl font-semibold">
      ${(option.price_cents / 100).toFixed(0)}
      {option.native_type === "membership" ? <span className="text-base text-muted">/mo</span> : null}
    </p>
    <p className="line-clamp-3 flex-1 text-sm text-muted">{option.rationale_one_line}</p>
    <Button onClick={onCreate} disabled={disabled || creating} color="accent">
      {creating ? "Creating…" : "Make it yours →"}
    </Button>
  </div>
);
