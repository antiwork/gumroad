import * as React from "react";
import { cast } from "ts-safe-cast";

import { assert } from "$app/utils/assert";

type TimeZone = { name: string; offset: number };

export type CurrentSeller = {
  id: string;
  email: string | null;
  name: string | null;
  subdomain: string | null;
  avatarUrl: string;
  isBuyer: boolean;
  timeZone: TimeZone;
  has_published_products: boolean;
};

const Context = React.createContext<CurrentSeller | null | undefined>(undefined);

export const parseCurrentSeller = (data: unknown): CurrentSeller | null => {
  const parsed = cast<{
    id: string;
    email: string | null;
    name: string | null;
    subdomain: string | null;
    avatar_url: string;
    is_buyer: boolean;
    time_zone: TimeZone;
    has_published_products: boolean;
  } | null>(data);
  if (parsed == null) return null;
  return {
    id: parsed.id,
    email: parsed.email,
    name: parsed.name,
    subdomain: parsed.subdomain,
    avatarUrl: parsed.avatar_url,
    isBuyer: parsed.is_buyer,
    timeZone: parsed.time_zone,
    has_published_products: parsed.has_published_products,
  };
};

export const useCurrentSeller = (): CurrentSeller | null => {
  const value = React.useContext(Context);
  assert(value !== undefined, "Cannot read current seller, make sure CurrentSellerProvider is used");
  return value;
};

export const CurrentSellerProvider = Context.Provider;
