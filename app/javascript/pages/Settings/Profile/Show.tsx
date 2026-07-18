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
import { ProfileLandingPagePreview } from "$app/components/Profile/LandingPagePreview";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";
import { ProfileSectionsForm } from "$app/components/Profile/SectionsForm";
import { LogoInput } from "$app/components/Profile/Settings/LogoInput";
import { showAlert } from "$app/components/server-components/Alert";
import { postToMobileApp } from "$app/components/Settings/Layout";
import { ShareButtons } from "$app/components/ShareButtons";
import { SocialAuthButton } from "$app/components/SocialAuthButton";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tab, Tabs } from "$app/components/ui/Tabs";
import { Textarea } from "$app/components/ui/Textarea";
import { useReactNativeMessage } from "$app/components/useReactNativeMessage";

type ProfileSettingsTab = "about" | "pages" | "share";

// How long the user's most recent answer to the unsaved-changes prompt stays reusable for a
// retry of the same navigation. Long enough to absorb a burst of repeated attempts (the bug
// this guards against), short enough that a deliberate second click a few seconds later asks again.
const LEAVE_ANSWER_REUSE_WINDOW_MS = 2000;

type ProfileSettingsForm = {
  name: string | null;
  bio: string | null;
  profile_picture_blob_id: string | null;
};

type ProfilePageProps = {
  profile_settings: ProfileSettingsForm;
  editable_profile: ProfileEditorProps;
  profile_version: string | null;
  custom_html_pages_enabled: boolean;
  has_custom_landing_page: boolean;
  username: string;
} & ProfileProps;

export default function SettingsPage() {
  const {
    creator_profile,
    profile_settings,
    editable_profile,
    profile_version,
    custom_html_pages_enabled,
    has_custom_landing_page,
    username,
  } = typia.assert<ProfilePageProps>(usePage().props);
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
  const [tab, setTab] = React.useState<ProfileSettingsTab>("about");
  const profileUrl = creatorProfile.subdomain ? Routes.root_url({ host: creatorProfile.subdomain }) : Routes.root_url();

  const [isSaving, setIsSaving] = React.useState(false);
  const canUpdate = Boolean(loggedInUser?.policies.settings_profile.update) && !isSaving;
  const isDirty =
    !isEqual(profileSettings, lastSavedSettings.current) ||
    !isEqual(editableProfile.sections, lastSavedProfile.current.sections) ||
    !isEqual(editableProfile.tabs, lastSavedProfile.current.tabs);
  const canSave = canUpdate && isDirty;

  const isDirtyRef = React.useRef(isDirty);
  isDirtyRef.current = isDirty;
  // Remembers the user's most recent answer to the unsaved-changes prompt so that a burst of
  // navigation attempts (for example a caller that retries after being blocked, or several visits
  // queued while the dialog was open) reuses that answer instead of opening one dialog per attempt.
  // Without this, sellers saw the same confirm dialog dozens of times in a row. We record which
  // URL the answer was for and only reuse the answer for that same destination: a "leave" grant
  // must not let an unrelated navigation ride on it, and a "stay" refusal must not silently
  // swallow a deliberate click somewhere else — a new destination always prompts again.
  const lastLeaveAnswer = React.useRef<{ time: number; allowed: boolean; href: string } | null>(null);
  React.useEffect(() => {
    const beforeUnload = (e: BeforeUnloadEvent) => {
      if (isDirtyRef.current) e.preventDefault();
    };
    window.addEventListener("beforeunload", beforeUnload);
    const removeInertiaListener = router.on("before", (event) => {
      const visit = event.detail.visit;
      if (!isDirtyRef.current || visit.method !== "get") return;
      // Background requests never discard the editor's local state, so they must not prompt:
      // - prefetch: Inertia warming a link on hover
      // - async: polling-style requests that update props in place (router.reload sets this,
      //   which covers our own post-save reload and the preview refresh)
      // - preserveState visits: the component stays mounted with its state intact
      // Note we intentionally do NOT exempt plain same-path visits: a regular GET to the current
      // path defaults to preserveState: false, so Inertia's React adapter remounts the page with
      // a new key and the pending edits are lost — exactly the loss this prompt protects against.
      if (visit.prefetch || visit.async || visit.preserveState === true) return;
      const previousAnswer = lastLeaveAnswer.current;
      if (
        previousAnswer &&
        Date.now() - previousAnswer.time < LEAVE_ANSWER_REUSE_WINDOW_MS &&
        previousAnswer.href === visit.url.href
      ) {
        // Reuse the answer only for the same destination the user was asked about. A retry of
        // that navigation repeats their choice — "stay" blocks it again silently, "leave" lets it
        // through — while a click to a different destination is a genuinely new navigation and
        // falls through to a fresh prompt.
        if (!previousAnswer.allowed) {
          event.preventDefault();
        }
        return;
      }
      // eslint-disable-next-line no-alert
      const allowed = window.confirm(
        "You have unsaved changes that will be lost if you leave this page. Leave anyway?",
      );
      lastLeaveAnswer.current = { time: Date.now(), allowed, href: visit.url.href };
      if (!allowed) event.preventDefault();
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

  const isMobileAppWebView = Boolean(usePage<{ is_mobile_app_web_view?: boolean }>().props.is_mobile_app_web_view);

  useReactNativeMessage((data) => {
    if (data.type === "mobileAppSettingsSave") void save();
  });

  React.useEffect(() => {
    if (!isMobileAppWebView) return;
    postToMobileApp({ type: "settingsCanUpdate", canUpdate: canSave });
  }, [isMobileAppWebView, canSave]);

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

  const showPagesTab = !has_custom_landing_page;

  const renderTab = (key: ProfileSettingsTab, label: string) => (
    <Tab
      isSelected={tab === key}
      className="cursor-pointer"
      onClick={() => setTab(key)}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          setTab(key);
        }
      }}
      tabIndex={0}
    >
      {label}
    </Tab>
  );

  const tabBar = (
    <Tabs aria-label="Profile settings sections">
      {renderTab("about", "About")}
      {showPagesTab ? renderTab("pages", "Pages") : null}
      {renderTab("share", "Share")}
    </Tabs>
  );

  const previewSidebar = (
    <PreviewSidebar
      previewLink={(props) => (
        <NavigationButton
          // Icon size is only a default: the preview sidebar/sheet overrides it via props
          // (the mobile sheet asks for a full-size button with a text label).
          size="icon"
          {...props}
          disabled={isSaving}
          href={profileUrl}
          onClick={(evt) => {
            evt.preventDefault();
            // Persist pending edits before previewing, but only when there's something to save -
            // settings (name/bio/avatar) are sent on every save with no freshness check, so an
            // unconditional save from a stale, locally-clean tab would revert changes made elsewhere.
            if (canSave) {
              // Open the tab NOW, while we still have the user's click activation, then point it
              // at the profile once the save finishes. Calling window.open after the await instead
              // gets popup-blocked on iOS Safari (the async gap consumes the transient activation),
              // which matters because the mobile preview sheet is this button's main audience.
              // On a failed save, close the reserved tab so we don't surface a stale preview.
              const previewWindow = window.open("about:blank", "_blank");
              void save().then((saved) => {
                if (!saved) previewWindow?.close();
                else if (previewWindow) previewWindow.location.href = profileUrl;
                else window.open(profileUrl, "_blank");
              });
            } else window.open(profileUrl, "_blank");
          }}
        />
      )}
    >
      {custom_html_pages_enabled && has_custom_landing_page ? (
        <ProfileLandingPagePreview username={username} name={profileSettings.name} bio={profileSettings.bio} />
      ) : (
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
      )}
    </PreviewSidebar>
  );

  return (
    <>
      {isMobileAppWebView ? (
        <div className="border-b border-border p-4 md:p-8">{tabBar}</div>
      ) : (
        <PageHeader
          className="sticky-top"
          title="Profile settings"
          actions={
            <Button color="accent" onClick={() => void save()} disabled={!canSave}>
              Update profile
            </Button>
          }
        >
          {tabBar}
        </PageHeader>
      )}
      <WithPreviewSidebar>
        <div>
          {tab === "about" ? (
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
          ) : tab === "pages" && showPagesTab ? (
            <>
              <section className="p-4! md:p-8!">
                <Alert role="status" variant="warning">
                  Pages are a legacy way to lay out your profile and are being phased out. To customize your profile,
                  build a custom page from the Share tab — your agent designs and publishes it for you.
                </Alert>
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
            </>
          ) : (
            <section className="grid gap-8 p-4! md:p-8!">
              <header>
                <h2>Share</h2>
              </header>
              <ShareButtons
                url={profileUrl}
                twitterText={`Check out ${profileSettings.name || username} on @Gumroad`}
                facebookText={profileSettings.name || username}
              />
            </section>
          )}
        </div>
        {previewSidebar}
      </WithPreviewSidebar>
    </>
  );
}
