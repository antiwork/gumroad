// Shared props from inertia_share in BaseController
export type SharedProps = {
  helper_widget_host?: string | null;
  helper_session?: {
    email?: string | null;
    emailHash?: string | null;
    timestamp?: number | null;
  } | null;
  recaptcha_site_key?: string | null;
  is_logged_in: boolean;
  new_ticket_url: string;
};

export type CategorySummary = {
  title: string;
  slug: string;
  url: string;
  is_active: boolean;
};

export type ArticleSummary = {
  title: string;
  url: string;
};

export type Category = {
  title: string;
  slug: string;
  url: string;
  audience: string;
  articles: ArticleSummary[];
};

export type Article = {
  title: string;
  slug: string;
  content: string;
  category: { title: string; slug: string; url: string };
};

export type Meta = {
  title: string;
  description: string;
  canonical_url: string;
};
