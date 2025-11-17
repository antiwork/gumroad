import { Head, usePage } from "@inertiajs/react";
import React from "react";
import { cast } from "ts-safe-cast";

import ProfileSettingsPage, {
  type ProfileSettingsPagePropsType,
} from "$app/components/server-components/Profile/SettingsPage";

const GOOGLE_FONTS = ["Inter", "Domine", "Merriweather", "Roboto Slab", "Roboto Mono"];

export default function Index() {
  const props = cast<ProfileSettingsPagePropsType>(usePage().props);

  return (
    <>
      <Head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
        {GOOGLE_FONTS.map((font) => (
          <link
            key={font}
            rel="stylesheet"
            href={`https://fonts.googleapis.com/css2?family=${encodeURIComponent(font)}:wght@400;600&display=swap`}
          />
        ))}
      </Head>
      <ProfileSettingsPage {...props} />
    </>
  );
}
