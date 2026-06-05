import { TwitterX } from "@boxicons/react";
import { router, useForm, usePage } from "@inertiajs/react";
import { isEqual } from "lodash-es";
import * as React from "react";
import typia from "typia";

import { unlinkTwitter } from "$app/data/profile_settings";
import { CreatorProfile } from "$app/parsers/profile";
import { SettingPage } from "$app/parsers/settings";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Preview } from "$app/components/Preview";
import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { Props as ProfileProps } from "$app/components/Profile";
import { EditProfile, ProfileEditorProps, ProfileEditorState } from "$app/components/Profile/EditPage";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";
import { ProfileSectionsForm } from "$app/components/Profile/SectionsForm";
import { LogoInput } from "$app/components/Profile/Settings/LogoInput";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { Textarea } from "$app/components/ui/Textarea";

type ProfileSettingsForm = {
  name: string | null;
  bio: string | null;
  profile_picture_blob_id: string | null;
};

type ProfilePageProps = {
  profile_settings: ProfileSettingsForm;
  settings_pages: SettingPage[];
  editable_profile: ProfileEditorProps;
} & ProfileProps;

export default function SettingsPage() {
  const { creator_profile, profile_settings, settings_pages, editable_profile } = typia.assert<ProfilePageProps>(
    usePage().props,
  );
  const loggedInUser = useLoggedInUser();
  const [creatorProfile, setCreatorProfile] = React.useState(creator_profile);
  React.useEffect(() => setCreatorProfile(creator_profile), [creator_profile]);
  const updateCreatorProfile = (newProfile: Partial<CreatorProfile>) =>
    setCreatorProfile((prevProfile) => ({ ...prevProfile, ...newProfile }));
  const previewCreatorProfile = React.useMemo(() => ({ ...creatorProfile, can_edit: false }), [creatorProfile]);

  const [editableProfile, setEditableProfile] = React.useState(editable_profile);
  const [selectedProfilePageIndex, setSelectedProfilePageIndex] = React.useState(0);
  React.useEffect(() => setEditableProfile(editable_profile), [editable_profile]);
  const handleProfileEditorChange = React.useCallback((updates: ProfileEditorState & { selectedTabIndex: number }) => {
    setSelectedProfilePageIndex(updates.selectedTabIndex);
    setEditableProfile((prevProfile) =>
      isEqual(prevProfile.sections, updates.sections) && isEqual(prevProfile.tabs, updates.tabs)
        ? prevProfile
        : { ...prevProfile, ...updates },
    );
  }, []);
  const previewTabs = React.useMemo(() => {
    const tab = editableProfile.tabs[selectedProfilePageIndex] ?? editableProfile.tabs[0];
    return tab ? [tab] : [];
  }, [editableProfile.tabs, selectedProfilePageIndex]);
  const selectedPreviewSectionIds = React.useMemo(
    () => new Set(previewTabs.flatMap((tab) => tab.sections)),
    [previewTabs],
  );
  const previewSectionCount = editableProfile.sections.filter((section) =>
    selectedPreviewSectionIds.has(section.id),
  ).length;

  const form = useForm(profile_settings);

  const profileSettings = form.data;
  const updateProfileSettings = (newSettings: Partial<ProfileSettingsForm>) =>
    form.setData({ ...form.data, ...newSettings });

  const uid = React.useId();

  const canUpdate = Boolean(loggedInUser?.policies.settings_profile.update) && !form.processing;

  const handleSave = () => {
    form.transform((data) => {
      const { profile_picture_blob_id, ...user } = data;
      return {
        profile_picture_blob_id,
        user,
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

  return (
    <SettingsLayout currentPage="profile" pages={settings_pages} onSave={handleSave} canUpdate={canUpdate}>
      <WithPreviewSidebar>
        <div>
          <section className="grid gap-8 p-4! md:p-8!">
            <header>
              <h2>Profile</h2>
            </header>
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
                disabled={!canUpdate}
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
                    <TwitterX pack="brands" className="size-5" />
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
                    <TwitterX pack="brands" className="size-5" />
                    Connect to X
                  </SocialAuthButton>
                )}
              </Fieldset>
            ) : null}
          </section>
          <section className="grid gap-8 border-t border-border" aria-label="Profile section editor">
            <header className="px-4 pt-4 md:px-8 md:pt-8">
              <h2>Sections</h2>
            </header>
            <ProfileSectionsForm
              {...editableProfile}
              creator_profile={creatorProfile}
              bio={profileSettings.bio}
              onChange={handleProfileEditorChange}
              disabled={!canUpdate}
            />
          </section>
        </div>
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
            }}
          >
            <ProfileLayout creatorProfile={previewCreatorProfile} hideFollowForm={!previewSectionCount}>
              <EditProfile
                {...editableProfile}
                tabs={previewTabs}
                creator_profile={previewCreatorProfile}
                bio={profileSettings.bio}
                controls={false}
              />
            </ProfileLayout>
          </Preview>
        </PreviewSidebar>
      </WithPreviewSidebar>
    </SettingsLayout>
  );
}
