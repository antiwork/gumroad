export type CreatorProfile = {
  external_id: string;
  avatar_url: string;
  name: string;
  twitter_handle: string | null;
  subdomain: string | null;
  is_verified: boolean;
  can_edit: boolean;
};

export type Tab = { name: string; sections: string[] };
export type ProfileSettings = {
  name: string | null;
  bio: string | null;
  profile_picture_blob_id: string | null;
};
