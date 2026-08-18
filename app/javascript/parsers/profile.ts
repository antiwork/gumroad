export type CreatorProfile = {
  external_id: string;
  avatar_url: string;
  name: string;
  twitter_handle: string | null;
  subdomain: string | null;
  is_verified: boolean;
  can_edit: boolean;
  // Set only when this seller's subscribe form must pass a CAPTCHA — sellers we
  // have reviewed and marked compliant get no challenge. Optional because
  // several previews build a CreatorProfile client-side without one; a missing
  // key and a null key both mean "no challenge".
  follow_recaptcha_site_key?: string | null;
  // Present only while seller_reputation_summary is enabled for the seller;
  // null when they miss the display thresholds (10+ reviews across 2+ products).
  reputation?: SellerReputation | null;
};

export type SellerReputation = { average: number; count: number; products_count: number };

export type Tab = { name: string; sections: string[] };
export type ProfileSettings = {
  name: string | null;
  bio: string | null;
  font: string;
  background_color: string;
  highlight_color: string;
  profile_picture_blob_id: string | null;
  product_page_storefront_enabled: boolean;
};
