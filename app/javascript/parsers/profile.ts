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
};

export type Tab = { name: string; sections: string[] };
export type ProfileSettings = {
  name: string | null;
  bio: string | null;
  profile_picture_blob_id: string | null;
};
