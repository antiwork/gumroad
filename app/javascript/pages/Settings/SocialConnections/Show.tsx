import { CheckCircle, Instagram, Tiktok, TwitterX, Youtube } from "@boxicons/react";
import { router, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { unlinkInstagram, unlinkTiktok, unlinkTwitter, unlinkYoutube } from "$app/data/profile_settings";
import { SettingPage } from "$app/parsers/settings";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { BrandName, Button } from "$app/components/Button";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { FieldsetDescription } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";

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
  tiktok_connect_enabled: boolean;
  tiktok_connected: boolean;
  tiktok_handle: string | null;
};

type Provider = {
  key: BrandName;
  name: string;
  Icon: typeof TwitterX;
  connected: boolean;
  handle: string | null;
  // X only: a hand-typed handle that predates OAuth. Still public, so it stays removable.
  legacyHandle?: string | null;
  connectHref: string;
  disconnect: () => void;
};

const formatHandle = (handle: string | null) => {
  const name = handle?.replace(/^@/u, "");
  return name ? `@${name}` : null;
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
    tiktok_connect_enabled,
    tiktok_connected,
    tiktok_handle,
  } = typia.assert<SocialConnectionsPageProps>(usePage().props);

  const disconnect = (unlink: () => Promise<unknown>) =>
    asyncVoid(async () => {
      try {
        await unlink();
        router.reload();
      } catch (e) {
        assertResponseError(e);
        showAlert(e.message, "error");
      }
    });

  const providers: Provider[] = [
    {
      key: "twitter",
      name: "X",
      Icon: TwitterX,
      connected: twitter_connected,
      handle: twitter_connected ? twitter_handle : null,
      legacyHandle: twitter_connected ? null : twitter_handle,
      connectHref: Routes.user_twitter_omniauth_authorize_path({
        social_connect_return,
        state: "link_twitter_account",
        x_auth_access_type: "read",
      }),
      disconnect: disconnect(unlinkTwitter),
    },
    ...(youtube_connect_enabled || youtube_connected
      ? [
          {
            key: "youtube" as const,
            name: "YouTube",
            Icon: Youtube,
            connected: youtube_connected,
            handle: youtube_handle,
            connectHref: Routes.user_youtube_omniauth_authorize_path({ social_connect_return }),
            disconnect: disconnect(unlinkYoutube),
          },
        ]
      : []),
    ...(instagram_connect_enabled || instagram_connected
      ? [
          {
            key: "instagram" as const,
            name: "Instagram",
            Icon: Instagram,
            connected: instagram_connected,
            handle: instagram_handle,
            connectHref: Routes.user_instagram_omniauth_authorize_path({ social_connect_return }),
            disconnect: disconnect(unlinkInstagram),
          },
        ]
      : []),
    ...(tiktok_connect_enabled || tiktok_connected
      ? [
          {
            key: "tiktok" as const,
            name: "TikTok",
            Icon: Tiktok,
            connected: tiktok_connected,
            handle: tiktok_handle,
            connectHref: social_connect_return
              ? `/users/auth/tiktok?social_connect_return=${encodeURIComponent(social_connect_return)}`
              : "/users/auth/tiktok",
            disconnect: disconnect(unlinkTiktok),
          },
        ]
      : []),
  ];

  return (
    <SettingsLayout currentPage="social_connections" pages={settings_pages}>
      <FormSection
        header={
          <>
            <h2>Social connections</h2>
            <FieldsetDescription>
              Connecting a social account is optional. It gives us extra context when we review your account. We only
              read your public profile, and we never post for you.
            </FieldsetDescription>
          </>
        }
      >
        <Rows role="list">
          {providers.map(({ key, name, Icon, connected, handle, legacyHandle, connectHref, disconnect }) => {
            const displayHandle = formatHandle(handle);
            const displayLegacyHandle = formatHandle(legacyHandle ?? null);
            const accountLabel = displayHandle ? `${displayHandle} from ${name}` : name;
            return (
              <Row key={key} role="listitem" className="grid-cols-[1fr_auto]">
                <RowContent className="items-start gap-3">
                  <Icon pack="brands" className="mt-0.5 size-5 shrink-0" />
                  <div className="grid gap-1">
                    <div className="font-bold">{name}</div>
                    {connected ? (
                      <FieldsetDescription className="flex items-center gap-1">
                        {displayHandle ?? "Connected"}
                        <CheckCircle pack="filled" className="size-4 text-success" aria-label="Connected" />
                      </FieldsetDescription>
                    ) : displayLegacyHandle ? (
                      <FieldsetDescription>
                        {displayLegacyHandle} was added by hand and is not verified.
                      </FieldsetDescription>
                    ) : (
                      <FieldsetDescription>Not connected</FieldsetDescription>
                    )}
                  </div>
                </RowContent>
                <RowActions>
                  {connected ? (
                    <Button type="button" aria-label={`Disconnect ${accountLabel}`} onClick={disconnect}>
                      Disconnect
                    </Button>
                  ) : (
                    <>
                      {displayLegacyHandle ? (
                        <Button
                          type="button"
                          aria-label={`Remove ${displayLegacyHandle} from ${name}`}
                          onClick={disconnect}
                        >
                          Remove
                        </Button>
                      ) : null}
                      <SocialAuthButton
                        provider={key}
                        href={connectHref}
                        color="primary"
                        aria-label={`Connect to ${name}`}
                      >
                        Connect
                      </SocialAuthButton>
                    </>
                  )}
                </RowActions>
              </Row>
            );
          })}
        </Rows>
      </FormSection>
    </SettingsLayout>
  );
}
