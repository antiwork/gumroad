export type CreatorProfile = {
  external_id: string;
  avatar_url: string;
  name: string;
  twitter_handle: string | null;
  subdomain: string | null;
};

export type Tab = { name: string; sections: string[] };
export type ProfileSettings = {
  username: string;
  name: string | null;
  bio: string | null;
  font: string;
  background_color: string;
  highlight_color: string;
  profile_picture_blob_id: string | null;
};
