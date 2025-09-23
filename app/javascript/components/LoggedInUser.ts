import * as React from "react";
import { cast } from "ts-safe-cast";

import { assert } from "$app/utils/assert";

export type TeamMembership = {
  id: string;
  seller_name: string;
  seller_avatar_url: string;
  has_some_read_only_access: boolean;
  is_selected: boolean;
};

type Policies = {
  affiliate_requests_onboarding_form: {
    update: boolean;
  };
  direct_affiliate: {
    create: boolean;
    update: boolean;
  };
  collaborator: {
    create: boolean;
    update: boolean;
  };
  product: {
    create: boolean;
  };
  product_review_response: {
    update: boolean;
  };
  balance: {
    index: boolean;
    export: boolean;
  };
  checkout_offer_code: {
    create: boolean;
  };
  checkout_form: {
    update: boolean;
  };
  upsell: {
    create: boolean;
  };
  settings_payments_user: {
    show: boolean;
  };
  settings_profile: {
    manage_social_connections: boolean;
    update: boolean;
    update_username: boolean;
  };
  settings_third_party_analytics_user: {
    update: boolean;
  };
  installment: {
    create: boolean;
  };
  workflow: {
    create: boolean;
  };
  utm_link: {
    index: boolean;
  };
  community: {
    index: boolean;
  };
};

export type LoggedInUser = {
  id: string;
  email: string | null;
  name: string | null;
  avatarUrl: string;
  confirmed: boolean;
  teamMemberships: TeamMembership[];
  policies: Policies;
  isGumroadAdmin: boolean;
  isImpersonating: boolean;
  /**
   * This is a temporary feature flag to enable lazy loading for offscreen images on discover page
   * It should be removed once lazy loading is fully rolled out.
   */
  lazyLoadOffscreenDiscoverImages: boolean;
};

const Context = React.createContext<LoggedInUser | null | undefined>(undefined);

export const parseLoggedInUser = (data: unknown): LoggedInUser | null => {
  const parsed = cast<{
    id: string;
    email: string | null;
    name: string | null;
    avatar_url: string;
    team_memberships: TeamMembership[];
    policies: Policies;
    confirmed: boolean;
    is_gumroad_admin: boolean;
    is_impersonating: boolean;
    lazy_load_offscreen_discover_images: boolean;
  } | null>(data);
  if (parsed == null) return null;
  return {
    id: parsed.id,
    email: parsed.email,
    name: parsed.name,
    avatarUrl: parsed.avatar_url,
    confirmed: parsed.confirmed,
    teamMemberships: parsed.team_memberships,
    policies: parsed.policies,
    isGumroadAdmin: parsed.is_gumroad_admin,
    isImpersonating: parsed.is_impersonating,
    lazyLoadOffscreenDiscoverImages: parsed.lazy_load_offscreen_discover_images,
  };
};

export const useLoggedInUser = (): LoggedInUser | null => {
  const value = React.useContext(Context);
  assert(value !== undefined, "Cannot read logged-in user, make sure LoggedInUserProvider is used");
  return value;
};

export const LoggedInUserProvider = Context.Provider;
