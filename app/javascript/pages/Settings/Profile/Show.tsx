import { TwitterX } from "@boxicons/react";
import { router, usePage } from "@inertiajs/react";
import { isEqual } from "lodash-es";
import * as React from "react";
import typia from "typia";

import { updateProfileSettings as saveProfileSettings, unlinkTwitter } from "$app/data/profile_settings";
import { CreatorProfile } from "$app/parsers/profile";
import { getContrastColor, hexToRgb } from "$app/utils/color";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Preview } from "$app/components/Preview";
import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { Props as ProfileProps } from "$app/components/Profile";
import { EditProfile, ProfileEditorProps, ProfileEditorState } from "$app/components/Profile/EditPage";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";
import { ProfileSectionsForm } from "$app/components/Profile/SectionsForm";
import { LogoInput } from "$app/components/Profile/Settings/LogoInput";
import { showAlert } from "$app/components/server-components/Alert";
import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Textarea } from "$app/components/ui/Textarea";

type ProfileSettingsForm = {
  name: string | null;
  bio: string | null;
  profile_picture_blob_id: string | null;
};

type ProfilePageProps = {
  profile_settings: ProfileSettingsForm;
  editable_profile: ProfileEditorProps;
  profile_version: string | null;
} & ProfileProps;

export default function SettingsPage() {
  const { creator_profile, profile_settings, editable_profile, profile_version } = typia.assert<ProfilePageProps>(
    usePage().props,
  );
  const loggedInUser = useLoggedInUser();
  const currentSeller = useCurrentSeller();
  const [creatorProfile, setCreatorProfile] = React.useState(creator_profile);
  React.useEffect(() => setCreatorProfile(creator_profile), [creator_profile]);
  const updateCreatorProfile = (newProfile: Partial<CreatorProfile>) =>
    setCreatorProfile((prevProfile) => ({ ...prevProfile, ...newProfile }));
  const previewCreatorProfile = React.useMemo(() => ({ ...creatorProfile, can_edit: false }), [creatorProfile]);

  const [editableProfile, setEditableProfile] = React.useState(editable_profile);
  const lastSavedProfile = React.useRef<ProfileEditorState>({
    sections: editable_profile.sections,
    tabs: editable_profile.tabs,
  });
  const [selectedProfilePageIndex, setSelectedProfilePageIndex] = React.useState(0);
  React.useEffect(() => {
    const previousBaseline = lastSavedProfile.current;
    lastSavedProfile.current = { sections: editable_profile.sections, tabs: editable_profile.tabs };
    setEditableProfile((prevProfile) =>
      isEqual(prevProfile.sections, previousBaseline.sections) && isEqual(prevProfile.tabs, previousBaseline.tabs)
        ? editable_profile
        : prevProfile,
    );
  }, [editable_profile]);
  const handleProfileEditorChange = React.useCallback((updates: ProfileEditorState & { selectedTabIndex: number }) => {
    setSelectedProfilePageIndex(updates.selectedTabIndex);
    setEditableProfile((prevProfile) =>
      isEqual(prevProfile.sections, updates.sections) && isEqual(prevProfile.tabs, updates.tabs)
        ? prevProfile
        : { ...prevProfile, ...updates },
    );
  }, []);
  const previewTabIndex = Math.min(selectedProfilePageIndex, Math.max(editableProfile.tabs.length - 1, 0));
  const selectedPreviewSectionIds = React.useMemo(
    () => new Set(editableProfile.tabs[previewTabIndex]?.sections ?? []),
    [editableProfile.tabs, previewTabIndex],
  );
  const previewSectionCount = editableProfile.sections.filter((section) =>
    selectedPreviewSectionIds.has(section.id),
  ).length;

  const [profileSettings, setProfileSettings] = React.useState(profile_settings);
  const lastSavedSettings = React.useRef(profile_settings);
  React.useEffect(() => {
    const previousBaseline = lastSavedSettings.current;
    lastSavedSettings.current = profile_settings;
    setProfileSettings((prevSettings) => (isEqual(prevSettings, previousBaseline) ? profile_settings : prevSettings));
  }, [profile_settings]);
  const updateProfileSettings = (newSettings: Partial<ProfileSettingsForm>) =>
    setProfileSettings((prevSettings) => ({ ...prevSettings, ...newSettings }));

  const uid = React.useId();

  const [isSaving, setIsSaving] = React.useState(false);
  const canUpdate = Boolean(loggedInUser?.policies.settings_profile.update) && !isSaving;
  const isDirty =
    !isEqual(profileSettings, lastSavedSettings.current) ||
    !isEqual(editableProfile.sections, lastSavedProfile.current.sections) ||
    !isEqual(editableProfile.tabs, lastSavedProfile.current.tabs);
  const canSave = canUpdate && isDirty;

  const isDirtyRef = React.useRef(isDirty);
  isDirtyRef.current = isDirty;
  React.useEffect(() => {
    const beforeUnload = (e: BeforeUnloadEvent) => {
      if (isDirtyRef.current) e.preventDefault();
    };
    window.addEventListener("beforeunload", beforeUnload);
    const removeInertiaListener = router.on("before", (event) => {
      if (!isDirtyRef.current || event.detail.visit.method !== "get") return;
      // eslint-disable-next-line no-alert
      if (!window.confirm("You have unsaved changes that will be lost if you leave this page. Leave anyway?"))
        event.preventDefault();
    });
    return () => {
      window.removeEventListener("beforeunload", beforeUnload);
      removeInertiaListener();
    };
  }, []);

  const save = async (): Promise<boolean> => {
    if (isSaving) return false;
    setIsSaving(true);
    const settings = profileSettings;
    const { sections, tabs } = editableProfile;
    // Only submit pages/sections when they actually changed. A save that left them untouched
    // (e.g. editing just the name or bio) must not resend a now-stale list, or the server would
    // prune sections another tab/device added in the meantime. When they did change, profileVersion
    // lets the server reject the save if the layout changed elsewhere since this editor loaded.
    const profileChanged =
      !isEqual(sections, lastSavedProfile.current.sections) || !isEqual(tabs, lastSavedProfile.current.tabs);
    try {
      await saveProfileSettings({
        ...settings,
        ...(profileChanged ? { tabs, sections, profileVersion: profile_version } : {}),
      });
      lastSavedSettings.current = settings;
      lastSavedProfile.current = { sections, tabs };
      isDirtyRef.current = false;
      await new Promise<void>((resolve) => router.reload({ onFinish: () => resolve() }));
      showAlert("Changes saved!", "success");
      return true;
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
      return false;
    } finally {
      setIsSaving(false);
    }
  };

  const profileColors = currentSeller
    ? {
        "--accent": hexToRgb(currentSeller.profileHighlightColor),
        "--contrast-accent": hexToRgb(getContrastColor(currentSeller.profileHighlightColor)),
        "--filled": hexToRgb(currentSeller.profileBackgroundColor),
        "--color": hexToRgb(getContrastColor(currentSeller.profileBackgroundColor)),
      }
    : {};

  const fontUrl =
    currentSeller?.profileFont && currentSeller.profileFont !== "ABC Favorit"
      ? `https://fonts.googleapis.com/css2?family=${currentSeller.profileFont}:wght@400;600&display=swap`
      : null;

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
    <>
      <PageHeader
        className="sticky-top"
        title="Profile"
        actions={
          <Button color="accent" onClick={() => void save()} disabled={!canSave}>
            Update profile
          </Button>
        }
      />
      <WithPreviewSidebar>
        <div>
          <section className="grid gap-8 p-4! md:p-8!">
            <header>
              <h2>About you</h2>
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
                updateCreatorProfile({
                  avatar_url: blob ? Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key }) : "",
                });
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
          <section aria-label="Profile section editor">
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
          previewLink={(props) => {
            const profileUrl = Routes.root_url({ host: creatorProfile.subdomain });
            return (
              <NavigationButton
                {...props}
                size="icon"
                disabled={isSaving}
                href={profileUrl}
                onClick={(evt) => {
                  evt.preventDefault();
                  // Persist pending edits before previewing, but only when there's something to save -
                  // settings (name/bio/avatar) are sent on every save with no freshness check, so an
                  // unconditional save from a stale, locally-clean tab would revert changes made elsewhere.
                  // Open only after a successful save so a failed save doesn't surface a stale preview.
                  const openProfile = () => window.open(profileUrl, "_blank");
                  if (canSave)
                    void save().then((saved) => {
                      if (saved) openProfile();
                    });
                  else openProfile();
                }}
              />
            );
          }}
        >
          <Preview
            scaleFactor={0.4}
            style={{
              border: "var(--border)",
              borderRadius: "var(--border-radius-2)",
              fontFamily: currentSeller?.profileFont === "ABC Favorit" ? undefined : currentSeller?.profileFont,
              ...profileColors,
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
            {fontUrl ? (
              <>
                <link rel="preconnect" href="https://fonts.googleapis.com" crossOrigin="anonymous" />
                <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
                <link rel="stylesheet" href={fontUrl} />
              </>
            ) : null}
            <div inert>
              <ProfileLayout creatorProfile={previewCreatorProfile} hideFollowForm={!previewSectionCount}>
                <EditProfile
                  {...editableProfile}
                  creator_profile={previewCreatorProfile}
                  bio={profileSettings.bio}
                  controls={false}
                  selectedTabIndex={previewTabIndex}
                />
              </ProfileLayout>
            </div>
          </Preview>
        </PreviewSidebar>
      </WithPreviewSidebar>
    </>
  );
}
