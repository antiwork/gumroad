import { Instagram, TwitterX, Youtube } from "@boxicons/react";
import { Link, router, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { unlinkInstagram, unlinkTwitter, unlinkYoutube } from "$app/data/profile_settings";
import { SettingPage } from "$app/parsers/settings";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { Fieldset, FieldsetDescription } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";

type SocialConnectionsPageProps = {
  settings_pages: SettingPage[];
  social_connect_return?: string | null;
  twitter_connected: boolean;
  twitter_handle: string | null;
  youtube_connect_enabled: boolean;
  youtube_connected: boolean;
  youtube_handle: string | null;
  instagram_connect_enabled: boolean;
  instagram_connected: boolean;
  instagram_handle: string | null;
};

const disconnectLabel = (handle: string | null, provider: string) => {
  const name = handle?.replace(/^@/u, "");
  return name ? `Disconnect @${name} from ${provider}` : `Disconnect ${provider}`;
};

export default function SocialConnectionsPage() {
  const {
    settings_pages,
    social_connect_return,
    twitter_connected,
    twitter_handle,
    youtube_connect_enabled,
    youtube_connected,
    youtube_handle,
    instagram_connect_enabled,
    instagram_connected,
    instagram_handle,
  } = typia.assert<SocialConnectionsPageProps>(usePage().props);

  const handleUnlinkTwitter = asyncVoid(async () => {
    try {
      await unlinkTwitter();
      router.reload();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  const handleUnlinkYoutube = asyncVoid(async () => {
    try {
      await unlinkYoutube();
      router.reload();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  const handleUnlinkInstagram = asyncVoid(async () => {
    try {
      await unlinkInstagram();
      router.reload();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  return (
    <SettingsLayout currentPage="social_connections" pages={settings_pages}>
      <FormSection
        header={
          <>
            <h2>Social connections</h2>
            <FieldsetDescription>
              Connecting is optional and helps verify your account. It never posts for you.
            </FieldsetDescription>
          </>
        }
      >
        {social_connect_return ? <p>After connecting, you’ll return to Getting started.</p> : null}
        <Fieldset>
          {twitter_connected ? (
            <Button type="button" color="twitter" onClick={handleUnlinkTwitter}>
              <TwitterX pack="brands" className="size-5" />
              {disconnectLabel(twitter_handle, "X")}
            </Button>
          ) : (
            <SocialAuthButton
              provider="twitter"
              href={Routes.user_twitter_omniauth_authorize_path({
                social_connect_return,
                state: "link_twitter_account",
                x_auth_access_type: "read",
              })}
            >
              <TwitterX pack="brands" className="size-5" />
              Connect to X
            </SocialAuthButton>
          )}
        </Fieldset>
        {youtube_connected ? (
          <Fieldset>
            <Button type="button" color="youtube" onClick={handleUnlinkYoutube}>
              <Youtube pack="brands" className="size-5" />
              {disconnectLabel(youtube_handle, "YouTube")}
            </Button>
          </Fieldset>
        ) : youtube_connect_enabled ? (
          <Fieldset>
            <SocialAuthButton
              provider="youtube"
              href={Routes.user_youtube_omniauth_authorize_path({ social_connect_return })}
            >
              <Youtube pack="brands" className="size-5" />
              Connect to YouTube
            </SocialAuthButton>
          </Fieldset>
        ) : null}
        {instagram_connected ? (
          <Fieldset>
            <Button type="button" color="instagram" onClick={handleUnlinkInstagram}>
              <Instagram pack="brands" className="size-5" />
              {disconnectLabel(instagram_handle, "Instagram")}
            </Button>
          </Fieldset>
        ) : instagram_connect_enabled ? (
          <Fieldset>
            <SocialAuthButton
              provider="instagram"
              href={Routes.user_instagram_omniauth_authorize_path({ social_connect_return })}
            >
              <Instagram pack="brands" className="size-5" />
              Connect to Instagram
            </SocialAuthButton>
          </Fieldset>
        ) : null}
        {social_connect_return ? (
          <Link href={Routes.dashboard_path()} className="underline">
            Continue without connecting
          </Link>
        ) : null}
      </FormSection>
    </SettingsLayout>
  );
}
