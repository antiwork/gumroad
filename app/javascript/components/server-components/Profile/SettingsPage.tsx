import * as React from "react";
import { createCast } from "ts-safe-cast";

import { updateProfileSettings as requestUpdateProfileSettings, unlinkTwitter } from "$app/data/profile_settings";
import { CreatorProfile, ProfileSettings } from "$app/parsers/profile";
import { SettingPage } from "$app/parsers/settings";
import { getContrastColor } from "$app/utils/color";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Preview } from "$app/components/Preview";
import { LogoInput } from "$app/components/Profile/Settings/LogoInput";
import { showAlert } from "$app/components/server-components/Alert";
import { Profile, Props as ProfileProps } from "$app/components/server-components/Profile/index";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { WithTooltip } from "$app/components/WithTooltip";

type Props = {
  profile_settings: ProfileSettings;
  settings_pages: SettingPage[];
} & ProfileProps;

const FONT_DESCRIPTIONS: Record<string, string> = {
  Domine: "Modern and bold serif",
  Inter: "Simple and modern sans-serif",
  "ABC Favorit": "Quirky and unique sans-serif",
  Merriweather: "Sturdy and pleasant serif",
  "Roboto Mono": "Technical and monospace",
  "Roboto Slab": "Personable and fun serif",
};

const SettingsPage = ({ creator_profile, profile_settings, settings_pages, ...profileProps }: Props) => {
  const { rootDomain, scheme } = useDomains();
  const loggedInUser = useLoggedInUser();
  const [creatorProfile, setCreatorProfile] = React.useState(creator_profile);
  const updateCreatorProfile = (newProfile: Partial<CreatorProfile>) =>
    setCreatorProfile((prevProfile) => ({ ...prevProfile, ...newProfile }));

  const [profileSettings, setProfileSettings] = React.useState(profile_settings);
  const updateProfileSettings = (newSettings: Partial<ProfileSettings>) =>
    setProfileSettings((prevSettings) => ({ ...prevSettings, ...newSettings }));

  const uid = React.useId();

  const canUpdate = loggedInUser?.policies.settings_profile.update || false;

  const handleSave = asyncVoid(async () => {
    try {
      await requestUpdateProfileSettings(profileSettings);
      showAlert("Changes saved!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  const handleUnlinkTwitter = asyncVoid(async () => {
    try {
      await unlinkTwitter();
      window.location.reload();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  const subdomain = `${profileSettings.username}.${rootDomain}`;

  const hexToRgb = (hex: string) =>
    `${parseInt(hex.slice(1, 3), 16)} ${parseInt(hex.slice(3, 5), 16)} ${parseInt(hex.slice(5), 16)}`;

  return (
    <SettingsLayout currentPage="profile" pages={settings_pages} onSave={handleSave} canUpdate={canUpdate} hasAside>
      <div className="fixed-aside lg:grid lg:grid-cols-[1fr_30vw]">
        <form>
          <section className="!p-4 md:!p-8">
            <header>
              <h2>Profile</h2>
            </header>
            <fieldset>
              <legend>
                <label htmlFor={`${uid}-username`}>Username</label>
              </legend>
              <input
                id={`${uid}-username`}
                type="text"
                disabled={!loggedInUser?.policies.settings_profile.update_username}
                value={profileSettings.username}
                onChange={(evt) =>
                  updateProfileSettings({ username: evt.target.value.replace(/[^a-z0-9]/giu, "").toLowerCase() })
                }
              />
              <small>
                View your profile at: <a href={`${scheme}://${subdomain}`}>{subdomain}</a>
              </small>
            </fieldset>
            <fieldset>
              <legend>
                <label htmlFor={`${uid}-name`}>Name</label>
              </legend>
              <input
                id={`${uid}-name`}
                type="text"
                value={profileSettings.name ?? ""}
                disabled={!canUpdate}
                onChange={(evt) => {
                  updateCreatorProfile({ name: evt.target.value });
                  updateProfileSettings({ name: evt.target.value });
                }}
              />
            </fieldset>
            <fieldset>
              <legend>
                <label htmlFor={`${uid}-bio`}>Bio</label>
              </legend>
              <textarea
                id={`${uid}-bio`}
                value={profileSettings.bio ?? ""}
                onChange={(e) => updateProfileSettings({ bio: e.target.value })}
              />
            </fieldset>
            <LogoInput
              logoUrl={creatorProfile.avatar_url}
              onChange={(blob) => {
                if (blob) {
                  updateCreatorProfile({
                    avatar_url: Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key }),
                  });
                }
                updateProfileSettings({ profile_picture_blob_id: blob?.signedId ?? null });
              }}
              disabled={!canUpdate}
            />
            {loggedInUser?.policies.settings_profile.manage_social_connections ? (
              <fieldset>
                <legend>Social links</legend>
                {creatorProfile.twitter_handle ? (
                  <button type="button" className="button button-twitter" onClick={handleUnlinkTwitter}>
                    Disconnect {creatorProfile.twitter_handle} from X
                  </button>
                ) : (
                  <SocialAuthButton
                    provider="twitter"
                    href={Routes.user_twitter_omniauth_authorize_path({
                      state: "link_twitter_account",
                      x_auth_access_type: "read",
                    })}
                  >
                    Connect to X
                  </SocialAuthButton>
                )}
              </fieldset>
            ) : null}
          </section>
          <section className="!p-4 md:!p-8">
            <header>
              <h2>Design</h2>
            </header>
            <fieldset>
              <legend>Font</legend>
              <div className="radio-buttons !grid-cols-1 sm:!grid-cols-2 md:!grid-cols-3" role="radiogroup">
                {(["ABC Favorit", "Inter", "Domine", "Merriweather", "Roboto Slab", "Roboto Mono"] as const).map(
                  (font) => (
                    <Button
                      role="radio"
                      key={font}
                      aria-checked={font === profileSettings.font}
                      onClick={() => updateProfileSettings({ font })}
                      style={{ fontFamily: font === "ABC Favorit" ? undefined : font }}
                      disabled={!canUpdate}
                    >
                      <Icon name="file-earmark-font" />
                      <div>
                        <h4>{font}</h4>
                        {FONT_DESCRIPTIONS[font]}
                      </div>
                    </Button>
                  ),
                )}
              </div>
            </fieldset>
            <div style={{ display: "flex", gap: "var(--spacer-4)" }}>
              <fieldset>
                <legend>
                  <label htmlFor={`${uid}-backgroundColor`}>Background color</label>
                </legend>
                <div className="color-picker">
                  <input
                    id={`${uid}-backgroundColor`}
                    value={profileSettings.background_color}
                    type="color"
                    onChange={(evt) => updateProfileSettings({ background_color: evt.target.value })}
                    disabled={!canUpdate}
                  />
                </div>
              </fieldset>
              <fieldset>
                <legend>
                  <label htmlFor={`${uid}-highlightColor`}>Highlight color</label>
                </legend>
                <div className="color-picker">
                  <input
                    id={`${uid}-highlightColor`}
                    value={profileSettings.highlight_color}
                    type="color"
                    onChange={(evt) => updateProfileSettings({ highlight_color: evt.target.value })}
                    disabled={!canUpdate}
                  />
                </div>
              </fieldset>
            </div>
          </section>
        </form>
        <aside>
          <header>
            <h2>Preview</h2>
            <WithTooltip tip="Preview" position="bottom">
              <a
                className="button"
                href={Routes.root_url({ host: creatorProfile.subdomain })}
                target="_blank"
                aria-label="Preview"
                rel="noreferrer"
              >
                <Icon name="arrow-diagonal-up-right" />
              </a>
            </WithTooltip>
          </header>
          <Preview
            scaleFactor={0.35}
            style={{
              border: "var(--border)",
              fontFamily: profileSettings.font === "ABC Favorit" ? undefined : profileSettings.font,
              "--accent": hexToRgb(profileSettings.highlight_color),
              "--contrast-accent": hexToRgb(getContrastColor(profileSettings.highlight_color)),
              "--filled": hexToRgb(profileSettings.background_color),
              "--color": hexToRgb(getContrastColor(profileSettings.background_color)),
              "--primary": "var(--color)",
              "--body-bg": "rgb(var(--filled))",
              "--contrast-primary": "var(--filled)",
              "--contrast-filled": "var(--color)",
              backgroundColor: "rgb(var(--filled))",
              color: "rgb(var(--color))",
            }}
          >
            <Profile creator_profile={creatorProfile} {...profileProps} bio={profileSettings.bio} />
          </Preview>
        </aside>
      </div>
    </SettingsLayout>
  );
};

export default register({ component: SettingsPage, propParser: createCast() });
