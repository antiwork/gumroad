type TeamMembership = {
  id: string;
  seller_name: string;
  seller_avatar_url: string | null;
  has_some_read_only_access: boolean;
  is_selected: boolean;
};

export type LoggedInUser = {
  id: number;
  email: string;
  name: string;
  avatar_url: string;
  confirmed: boolean;
  team_memberships: TeamMembership[];
  policies: Record<string, Record<string, boolean>>;
  is_gumroad_admin: boolean;
  is_impersonating: boolean;
};

export type Seller = {
  id: number;
  email: string;
  name: string;
  avatar_url: string;
  has_published_products: boolean;
  subdomain: string;
  is_buyer: boolean;
  time_zone: {
    name: string;
    offset: number;
  };
};

export type ImpersonatedUser = {
  name: string;
  avatar_url: string;
};

export type CurrentUser = {
  name: string;
  avatar_url: string;
  impersonated_user: ImpersonatedUser | null;
};
