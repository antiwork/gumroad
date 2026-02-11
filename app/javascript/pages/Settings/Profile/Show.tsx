import { Head, router, usePage, useForm } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { unlinkTwitter } from "$app/data/profile_settings";
import { CreatorProfile, ProfileSettings } from "$app/parsers/profile";
import { SettingPage } from "$app/parsers/settings";
import { classNames } from "$app/utils/classNames";
import { getContrastColor, hexToRgb } from "$app/utils/color";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Preview } from "$app/components/Preview";
import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { LogoInput } from "$app/components/Profile/Settings/LogoInput";
import { showAlert } from "$app/components/server-components/Alert";
import { Profile, Props as ProfileProps } from "$app/components/server-components/Profile";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { ColorPicker } from "$app/components/ui/ColorPicker";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Textarea } from "$app/components/ui/Textarea";

type ProfilePageProps = {
  profile_settings: ProfileSettings;
  settings_pages: SettingPage[];
} & ProfileProps;

const FONT_CHOICES = ["ABC Favorit", "Inter", "Domine", "Merriweather", "Roboto Slab", "Roboto Mono"];
const FONT_DESCRIPTIONS: Record<string, string> = {
  Domine: "Modern and bold serif",
  Inter: "Simple and modern sans-serif",
  "ABC Favorit": "Quirky and unique sans-serif",
  Merriweather: "Sturdy and pleasant serif",
  "Roboto Mono": "Technical and monospace",
  "Roboto Slab": "Personable and fun serif",
};

export default function SettingsPage() {
  const { creator_profile, profile_settings, settings_pages, ...profileProps } = cast<ProfilePageProps>(
    usePage().props,
  );
  const { rootDomain, scheme } = useDomains();
  const loggedInUser = useLoggedInUser();
  const [creatorProfile, setCreatorProfile] = React.useState(creator_profile);
  React.useEffect(() => setCreatorProfile(creator_profile), [creator_profile]);
  const updateCreatorProfile = (newProfile: Partial<CreatorProfile>) =>
    setCreatorProfile((prevProfile) => ({ ...prevProfile, ...newProfile }));

  const form = useForm(profile_settings);

  const profileSettings = form.data;
  const updateProfileSettings = (newSettings: Partial<ProfileSettings>) =>
    form.setData({ ...form.data, ...newSettings });

  const uid = React.useId();

  const canUpdate = Boolean(loggedInUser?.policies.settings_profile.update) && !form.processing;

  const handleSave = () => {
    form.transform((data) => {
      const { background_color, highlight_color, font, profile_picture_blob_id, ...user } = data;
      return {
        profile_picture_blob_id,
        user,
        seller_profile: { background_color, highlight_color, font },
      };
    });
    form.put(Routes.settings_profile_path(), {
      preserveScroll: true,
    });
  };

  const handleUnlinkTwitter = asyncVoid(async () => {
    try {
      await unlinkTwitter();
      router.reload();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  });

  const subdomain = `${profileSettings.username}.${rootDomain}`;

  return (
    <SettingsLayout currentPage="profile" pages={settings_pages} onSave={handleSave} canUpdate={canUpdate}>
      <Head>
        <link rel="preconnect" href="https://fonts.googleapis.com" crossOrigin="anonymous" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        {FONT_CHOICES.filter((font) => font !== "ABC Favorit").map((font) => (
          <link
            rel="stylesheet"
            href={`https://fonts.googleapis.com/css2?family=${font}:wght@400;600&display=swap`}
            key={font}
          />
        ))}
      </Head>
      <WithPreviewSidebar>
        <form>
          <section className="grid gap-8 p-4! md:p-8!">
            <header>
              <h2>Profile</h2>
            </header>
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-username`}>Username</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-username`}
                type="text"
                disabled={!loggedInUser?.policies.settings_profile.update_username}
                value={profileSettings.username}
                onChange={(evt) =>
                  updateProfileSettings({ username: evt.target.value.replace(/[^a-z0-9]/giu, "").toLowerCase() })
                }
              />
              <FieldsetDescription>
                View your profile at: <a href={`${scheme}://${subdomain}`}>{subdomain}</a>
              </FieldsetDescription>
            </Fieldset>
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-name`}>Name</Label>
              </FieldsetTitle>
              <Input
                id={`${uid}-name`}
                type="text"
                value={profileSettings.name ?? ""}
                disabled={!canUpdate}
                onChange={(evt) => {
                  updateCreatorProfile({ name: evt.target.value });
                  updateProfileSettings({ name: evt.target.value });
                }}
              />
            </Fieldset>
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-bio`}>Bio</Label>
              </FieldsetTitle>
              <Textarea
                id={`${uid}-bio`}
                value={profileSettings.bio ?? ""}
                onChange={(e) => updateProfileSettings({ bio: e.target.value })}
              />
            </Fieldset>
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
              <Fieldset>
                <FieldsetTitle>Social links</FieldsetTitle>
                {creatorProfile.twitter_handle ? (
                  <Button type="button" color="twitter" onClick={handleUnlinkTwitter}>
                    <span className="brand-icon brand-icon-twitter" />
                    Disconnect {creatorProfile.twitter_handle} from X
                  </Button>
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
              </Fieldset>
            ) : null}
          </section>
          <section className="grid gap-8 border-t border-border p-4 md:p-8">
            <header className="grid content-start gap-3">
              <h2>Design</h2>
            </header>
            <Fieldset>
              <FieldsetTitle>Font</FieldsetTitle>
              <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 md:grid-cols-3" role="radiogroup">
                {FONT_CHOICES.map((font) => {
                  const isSelected = font === profileSettings.font;
                  return (
                    <Button
                      role="radio"
                      key={font}
                      aria-checked={isSelected}
                      onClick={() => updateProfileSettings({ font })}
                      style={{ fontFamily: font === "ABC Favorit" ? undefined : font }}
                      disabled={!canUpdate}
                      className={classNames(
                        "items-start! justify-start! gap-3! text-left transition-transform!",
                        "hover:translate-x-0! hover:translate-y-0!",
                        isSelected && "-translate-x-1! -translate-y-1! bg-background! shadow!",
                      )}
                    >
                      <Icon name="file-earmark-font" className="shrink-0" />
                      <div>
                        <h4 className="font-bold">{font}</h4>
                        {FONT_DESCRIPTIONS[font]}
                      </div>
                    </Button>
                  );
                })}
              </div>
            </Fieldset>
            <div className="flex gap-4">
              <Fieldset>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-backgroundColor`}>Background color</Label>
                </FieldsetTitle>
                <ColorPicker
                  id={`${uid}-backgroundColor`}
                  value={profileSettings.background_color}
                  onChange={(evt) => updateProfileSettings({ background_color: evt.target.value })}
                  disabled={!canUpdate}
                />
              </Fieldset>
              <Fieldset>
                <FieldsetTitle>
                  <Label htmlFor={`${uid}-highlightColor`}>Highlight color</Label>
                </FieldsetTitle>
                <ColorPicker
                  id={`${uid}-highlightColor`}
                  value={profileSettings.highlight_color}
                  onChange={(evt) => updateProfileSettings({ highlight_color: evt.target.value })}
                  disabled={!canUpdate}
                />
              </Fieldset>
            </div>
          </section>
        </form>
        <PreviewSidebar
          previewLink={(props) => (
            <Button asChild>
              <a {...props} href={Routes.root_url({ host: creatorProfile.subdomain })} target="_blank" rel="noreferrer">
                View profile
              </a>
            </Button>
          )}
        >
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
              "--color-body": "var(--body-bg)",
              "--color-background": "rgb(var(--filled))",
              "--color-foreground": "rgb(var(--color))",
              "--color-border": "rgb(var(--color) / var(--border-alpha))",
              "--color-accent": "rgb(var(--accent))",
              "--color-accent-foreground": "rgb(var(--contrast-accent))",
              "--color-primary": "rgb(var(--primary))",
              "--color-primary-foreground": "rgb(var(--contrast-primary))",
              "--color-active-bg": "rgb(var(--color) / var(--gray-1))",
              "--color-muted": "rgb(var(--color) / var(--gray-3))",
              backgroundColor: "rgb(var(--filled))",
              color: "rgb(var(--color))",
            }}
          >
            <Profile
              creator_profile={creatorProfile}
              {...(() => ({ profile_settings, settings_pages, ...profileProps }))()}
              bio={profileSettings.bio}
            />
          </Preview>
        </PreviewSidebar>
      </WithPreviewSidebar>
    </SettingsLayout>
  );
}
