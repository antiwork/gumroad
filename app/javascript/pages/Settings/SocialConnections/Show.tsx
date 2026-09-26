import { AlertCircle, CheckCircle, DotsHorizontalRounded, Instagram, Tiktok, TwitterX, Youtube } from "@boxicons/react";
import { router, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { unlinkInstagram, unlinkTiktok, unlinkTwitter, unlinkYoutube } from "$app/data/profile_settings";
import { SettingPage } from "$app/parsers/settings";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { BrandName, Button } from "$app/components/Button";
import { Modal } from "$app/components/Modal";
import { Popover, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { FieldsetDescription } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Menu, MenuItem } from "$app/components/ui/Menu";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";

type SocialConnectionsPageProps = {
  settings_pages: SettingPage[];
  social_connect_return?: string | null;
  twitter_connected: boolean;
  twitter_handle: string | null;
  twitter_write_permission_missing: boolean;
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
  // X only: the stored token can read the profile but not post, so the row has to give
  // the seller a reason to reconnect.
  writePermissionMissing?: boolean;
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
    twitter_write_permission_missing,
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

  // Disconnect sits a click away from Reconnect, and it clears twitter_user_id — the identity a
  // seller who signed up with X signs in with — so it is confirmed before it goes.
  const [pendingDisconnect, setPendingDisconnect] = React.useState<Provider | null>(null);

  const confirmDisconnect = () => {
    const provider = pendingDisconnect;
    setPendingDisconnect(null);
    provider?.disconnect();
  };

  const disconnectConsequences = ({ key, name, handle }: Provider) => {
    const account = formatHandle(handle) ?? name;
    const signIn = key === "twitter" ? ` If you sign in with ${name}, connect it again to keep signing in.` : "";
    return `Gumroad will forget ${account} and the access it stored. You can connect ${name} again at any time.${signIn}`;
  };

  const providers: Provider[] = [
    {
      key: "twitter",
      name: "X",
      Icon: TwitterX,
      connected: twitter_connected,
      handle: twitter_connected ? twitter_handle : null,
      legacyHandle: twitter_connected ? null : twitter_handle,
      writePermissionMissing: twitter_connected && twitter_write_permission_missing,
      // x_auth_access_type caps the OAuth grant, so sending "read" here yields a token that
      // cannot post. The sign-in button in SocialAuth.tsx still sends it, and should.
      connectHref: Routes.user_twitter_omniauth_authorize_path({
        social_connect_return,
        state: "link_twitter_account",
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
              Connecting a social account is optional. It gives us extra context when we review your account. We read
              your public profile. On X, we post only the launch posts you write and approve.
            </FieldsetDescription>
          </>
        }
      >
        {/* FormSection puts the header in the other column and sizes the row to the taller of
            the two, so without this the card stretches to the header's height. */}
        <Rows role="list" className="self-start">
          {providers.map((provider) => {
            const {
              key,
              name,
              Icon,
              connected,
              handle,
              legacyHandle,
              writePermissionMissing,
              connectHref,
              disconnect,
            } = provider;
            const displayHandle = formatHandle(handle);
            const displayLegacyHandle = formatHandle(legacyHandle ?? null);
            const accountLabel = displayHandle ? `${displayHandle} from ${name}` : name;
            return (
              <Row key={key} role="listitem" className="grid-cols-[1fr_auto]">
                <RowContent className="items-start gap-3">
                  <Icon pack="brands" className="mt-0.5 size-5 shrink-0" />
                  {/* min-w-0 lets the handle truncate. Without it a long one wraps a character
                      per line once the actions have taken their width. */}
                  <div className="grid min-w-0 gap-1">
                    <div className="font-bold">{name}</div>
                    {connected ? (
                      <FieldsetDescription className="flex items-center gap-1">
                        <span className="truncate">{displayHandle ?? "Connected"}</span>
                        {writePermissionMissing ? (
                          <AlertCircle
                            pack="filled"
                            className="size-4 shrink-0 text-warning"
                            aria-label="Cannot post"
                          />
                        ) : (
                          <CheckCircle pack="filled" className="size-4 shrink-0 text-success" aria-label="Connected" />
                        )}
                      </FieldsetDescription>
                    ) : displayLegacyHandle ? (
                      <FieldsetDescription>
                        {displayLegacyHandle} was added by hand and is not verified.
                      </FieldsetDescription>
                    ) : (
                      <FieldsetDescription>Not connected</FieldsetDescription>
                    )}
                    {writePermissionMissing ? (
                      <FieldsetDescription className="text-warning">
                        This connection can't post launch posts. Reconnect to fix it.
                      </FieldsetDescription>
                    ) : null}
                  </div>
                </RowContent>
                <RowActions>
                  {connected ? (
                    <>
                      {/* A connected account can still hold a read-only token, so reconnecting
                          must not require Disconnect first: that clears twitter_user_id, the login
                          identity for a seller who signed up with X. */}
                      <SocialAuthButton provider={key} href={connectHref} aria-label={`Reconnect ${accountLabel}`}>
                        Reconnect
                      </SocialAuthButton>
                      {/* Phone width has no room for a second full-size button — the handle column
                          collapses a character per line — so the row menu keeps Disconnect there. */}
                      <Button
                        type="button"
                        aria-label={`Disconnect ${accountLabel}`}
                        onClick={() => setPendingDisconnect(provider)}
                        className="hidden sm:inline-flex"
                      >
                        Disconnect
                      </Button>
                      <Popover>
                        <PopoverTrigger
                          aria-label={`Open ${name} connection menu`}
                          className="flex size-11 cursor-pointer items-center justify-center all-unset sm:hidden"
                        >
                          <DotsHorizontalRounded className="size-5" />
                        </PopoverTrigger>
                        <PopoverContent className="border-0 p-0 shadow-none">
                          <Menu>
                            <MenuItem
                              variant="danger"
                              aria-label={`Disconnect ${accountLabel}`}
                              onClick={() => setPendingDisconnect(provider)}
                            >
                              Disconnect
                            </MenuItem>
                          </Menu>
                        </PopoverContent>
                      </Popover>
                    </>
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
      {pendingDisconnect ? (
        <Modal
          open
          onClose={() => setPendingDisconnect(null)}
          title={`Disconnect ${pendingDisconnect.name}?`}
          footer={
            <>
              <Button type="button" onClick={() => setPendingDisconnect(null)}>
                Cancel
              </Button>
              <Button type="button" color="danger" onClick={confirmDisconnect}>
                Disconnect
              </Button>
            </>
          }
        >
          <p>{disconnectConsequences(pendingDisconnect)}</p>
        </Modal>
      ) : null}
    </SettingsLayout>
  );
}
