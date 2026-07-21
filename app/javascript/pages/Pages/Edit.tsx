import { MagicWand } from "@boxicons/react";
import { router, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PreviewChrome, PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { RichTextEditor } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { PageHeader } from "$app/components/ui/PageHeader";

type PageProps = {
  page: {
    slug: string | null;
    title: string;
    content: string;
    // Built by an agent/CLI as full HTML. The in-app editor doesn't attempt a
    // lossy HTML -> rich text conversion; it shows the agent/CLI path instead.
    custom_html: boolean;
  };
  is_profile: boolean;
  is_new: boolean;
  username: string;
  profile_url: string;
};

// The copy-paste prompt for building a page with an agent. The CLI commands it
// references are the same ones a seller can run by hand. The follow-form
// instructions match the serve-time gumroad:follow bridge: a form marked
// data-gumroad-follow gets wired to the seller's email audience automatically.
const followFormHint = `If I want an email signup, add a \`<form data-gumroad-follow>\` with an email input and an element marked \`data-gumroad-follow-message\` for the confirmation text — Gumroad wires the form to my email audience automatically.`;

const agentPrompt = (username: string, slug: string | null, isProfile: boolean) =>
  isProfile
    ? `Build and publish a custom landing page for my Gumroad profile (@${username}). Design a unique, on-brand page — fully responsive, with light and dark mode. Preview it with \`gumroad pages preview\`, then publish with \`gumroad pages push profile\`. The page replaces my entire profile, so link visitors to my product pages instead of adding checkout elements. ${followFormHint}`
    : `Build and publish a custom page for my Gumroad store (@${username})${slug ? ` at /${slug}` : ""}. Design a unique, on-brand page — fully responsive, with light and dark mode. Preview it with \`gumroad pages preview\`, then publish with \`gumroad pages push ${slug ?? "<slug>"}\`. ${followFormHint}`;

export default function PagesEdit() {
  const { page, is_profile, is_new, username, profile_url } = typia.assert<PageProps>(usePage().props);
  const loggedInUser = useLoggedInUser();
  // Mirrors PagePolicy: create? also gates update? and destroy?, so one flag
  // covers everything the editor can change. Viewers without it get a
  // read-only editor instead of buttons whose requests would fail.
  const canEdit = !!loggedInUser?.policies.page.create;

  const [title, setTitle] = React.useState(page.title);
  const [content, setContent] = React.useState(page.content);
  // The last-saved values, for unsaved-changes detection. The preview pane
  // frames the saved page, so it refreshes on save (previewVersion below), not
  // on every keystroke.
  const [savedTitle, setSavedTitle] = React.useState(page.title);
  const [savedContent, setSavedContent] = React.useState(page.content);
  const [previewVersion, setPreviewVersion] = React.useState(0);
  const [isSaving, setIsSaving] = React.useState(false);

  // Only rich-text pages are editable in place; the profile and custom HTML
  // pages change through profile settings or the agent/CLI.
  const isEditable = canEdit && !is_profile && !page.custom_html;
  const isDirty = isEditable && (title !== savedTitle || content !== savedContent);

  // Warn before navigating away with unsaved edits. `beforeunload` covers full
  // navigations (close tab, hard link); the Inertia "before" listener covers
  // in-app navigations like the sidebar, which are SPA visits the browser
  // event never sees. Background visits (prefetch, async reloads, or ones that
  // preserve component state) don't discard the editor's local state, so they
  // don't prompt. The Cancel button confirms explicitly in backToList.
  const isDirtyRef = React.useRef(isDirty);
  isDirtyRef.current = isDirty;
  React.useEffect(() => {
    const beforeUnload = (e: BeforeUnloadEvent) => {
      if (isDirtyRef.current) e.preventDefault();
    };
    window.addEventListener("beforeunload", beforeUnload);

    const removeInertiaListener = router.on("before", (event) => {
      const visit = event.detail.visit;
      if (!isDirtyRef.current || visit.method !== "get") return;
      if (visit.prefetch || visit.async || visit.preserveState === true) return;
      // eslint-disable-next-line no-alert
      if (!window.confirm("You have unsaved changes. Discard them and leave this page?")) event.preventDefault();
    });

    return () => {
      window.removeEventListener("beforeunload", beforeUnload);
      removeInertiaListener();
    };
  }, []);

  const backToList = () => {
    // eslint-disable-next-line no-alert
    if (isDirty && !window.confirm("You have unsaved changes. Discard them and go back to Pages?")) return;
    // Clear the dirty flag first so the router listener above doesn't prompt a
    // second time for the navigation the user just confirmed.
    isDirtyRef.current = false;
    router.visit(Routes.pages_path());
  };

  const publicUrl = is_profile
    ? profile_url
    : `${profile_url.replace(/\/$/u, "")}/${page.slug ?? title.toLowerCase().replace(/[^a-z0-9]+/gu, "-")}`;

  // Custom HTML pages can't frame their public URL from the dashboard: the
  // public page is a wrapper whose nested embed answers with
  // X-Frame-Options: SAMEORIGIN, and the dashboard is a different origin, so
  // the browser blocks the frame. The dashboard's own preview endpoint serves
  // the same document same-origin instead — the sanitized custom HTML for
  // agent-built pages, or the real styled document for rich text pages.
  const previewPath = page.slug ? Routes.preview_page_path(page.slug) : null;

  const save = () => {
    setIsSaving(true);
    const params = { title, content };
    const options = {
      onSuccess: () => {
        setSavedTitle(title);
        setSavedContent(content);
        // Bump the preview frame's cache-busting param so it reloads and shows
        // the page as just saved.
        setPreviewVersion((version) => version + 1);
      },
      onError: (errors: Record<string, unknown>) => {
        const message = Object.values(errors).find((value) => typeof value === "string");
        showAlert(typeof message === "string" ? message : "Sorry, something went wrong. Please try again.", "error");
      },
      onFinish: () => setIsSaving(false),
    };
    if (is_new) router.post(Routes.pages_path(), params, options);
    else if (page.slug) router.patch(Routes.page_path(page.slug), params, options);
  };

  const [isRemovingCustomHtml, setIsRemovingCustomHtml] = React.useState(false);
  // Removing the custom HTML takeover restores the profile's default
  // storefront template. The server clears it and redirects back here.
  const removeProfileCustomHtml = () => {
    setIsRemovingCustomHtml(true);
    router.patch(
      Routes.page_path("profile"),
      { remove_custom_html: true },
      {
        onError: () => showAlert("Failed to remove the custom page. Please try again.", "error"),
        onFinish: () => setIsRemovingCustomHtml(false),
      },
    );
  };

  // The panel's pitch depends on where the seller is standing: on a custom
  // HTML page the agent is the ONLY way to edit (this line doubles as the
  // "why is there no editor here" explanation — no separate alert repeats
  // it), on a rich-text page it's an upgrade path, and on the profile it
  // replaces the default template.
  const agentPanelHeading = !is_profile && page.custom_html ? "Update with your agent" : "Build with your agent";
  const agentPanelIntro = is_profile
    ? "Replace the default template with a page your agent designs as full HTML — custom layout, animations, anything."
    : page.custom_html
      ? "This page is custom HTML built by your agent, so it can't be edited here — hand your agent this prompt to change it."
      : "Want more than rich text? Your agent can redesign this page as full HTML and publish it for you.";

  // Matches the product Share tab's landing-page pattern: one-sentence pitch,
  // a Copy prompt button, and the full prompt tucked behind a toggle. The
  // prompt is there to be copied, not read.
  const agentPanel = (
    <div className="grid gap-3 rounded border border-border p-4">
      <div className="flex items-center gap-2">
        <MagicWand className="size-5" />
        <h3>{agentPanelHeading}</h3>
      </div>
      <p className="text-sm text-muted">{agentPanelIntro}</p>
      <div className="flex flex-wrap gap-3">
        <CopyToClipboard text={agentPrompt(username, page.slug, is_profile)}>
          <Button color="primary">Copy prompt</Button>
        </CopyToClipboard>
      </div>
      <Details>
        <DetailsToggle>Show prompt</DetailsToggle>
        <pre className="rounded border border-border bg-background p-4 text-sm whitespace-pre-wrap">
          {agentPrompt(username, page.slug, is_profile)}
        </pre>
      </Details>
      <p className="text-sm text-muted">
        Or use the CLI: <code>gumroad pages list / create / push / preview</code>.
      </p>
    </div>
  );

  // Rich text previews render through the dashboard's same-origin preview
  // endpoint (the same styled document the public page serves), so the frame's
  // document is readable — size the frame to its content like the other
  // previews in the app instead of forcing a fixed box shape.
  const richTextFrameRef = React.useRef<HTMLIFrameElement>(null);
  const sizeRichTextPreview = () => {
    const frame = richTextFrameRef.current;
    const height = frame?.contentDocument?.documentElement.scrollHeight;
    if (frame && height) frame.style.height = `${Math.min(height, window.innerHeight)}px`;
  };

  // The preview renders inside the shared browser-style chrome (see PreviewChrome): a top
  // bar with the page's title and URL centered and an arrow that opens the live page in a
  // new tab. The chrome IS the preview's identity strip, so the sidebar's old preview link
  // and the separate URL caption are gone — everything lives in one place.
  const displayTitle = is_profile ? "Home" : is_new ? title || "New page" : page.title;
  const previewChrome = (frame: React.ReactNode) => (
    <PreviewChrome
      title={displayTitle}
      url={publicUrl}
      // A new page has nothing to open yet — the link would 404.
      link={
        is_new
          ? undefined
          : (props) => <NavigationButton {...props} href={publicUrl} target="_blank" rel="noreferrer" />
      }
    >
      {frame}
    </PreviewChrome>
  );

  const previewSidebar = (
    // The chrome bar already says "this is a preview", so the sidebar carries no heading —
    // the chrome lines up vertically with the top of the edit form on the left.
    <PreviewSidebar>
      {is_profile && !page.custom_html
        ? previewChrome(
            // The default-template home page frames the live storefront.
            // `allow-same-origin` is needed for the storefront's own scripts to
            // boot — without it the page loads but renders blank. The frame
            // shows our own domain (the seller's public profile), same trust
            // level as the parent page.
            // eslint-disable-next-line react/iframe-missing-sandbox -- allow-scripts + allow-same-origin is intentional for framing our own storefront
            <iframe
              title="Page preview"
              src={publicUrl}
              sandbox="allow-scripts allow-forms allow-same-origin"
              className="h-[75vh] min-h-150 w-full bg-white"
            />,
          )
        : page.custom_html && previewPath
          ? previewChrome(
              // Agent-built pages (and a custom HTML home page) render through the
              // dashboard's same-origin preview endpoint — see the note on
              // previewPath above for why the public URL can't be framed. The
              // sandbox makes the document unreadable from here, so it can't be
              // sized to content; it gets the same tall frame as the profile.
              <iframe
                title="Page preview"
                src={previewPath}
                sandbox="allow-scripts"
                className="h-[75vh] min-h-150 w-full bg-white"
              />,
            )
          : is_new
            ? previewChrome(
                <div className="bg-background p-4 text-sm text-muted">Create the page to see a preview.</div>,
              )
            : previewPath
              ? previewChrome(
                  // The real page document, sized to its content. The endpoint renders
                  // sanitized rich text — no seller scripts can run (the sandbox has no
                  // allow-scripts) — and `allow-same-origin` keeps the same-origin
                  // document readable so the frame can be measured.
                  <iframe
                    ref={richTextFrameRef}
                    title="Page preview"
                    key={previewVersion}
                    src={`${previewPath}?v=${previewVersion}`}
                    sandbox="allow-same-origin"
                    onLoad={sizeRichTextPreview}
                    className="w-full bg-white"
                  />,
                )
              : null}
      {isEditable ? <p className="text-xs text-muted">The preview refreshes when you save.</p> : null}
    </PreviewSidebar>
  );

  if (is_profile) {
    return (
      <>
        <PageHeader
          className="sticky-top"
          // "Home" matches the pinned entry in the Pages list — the same page
          // shouldn't change names between the list and its editor.
          title="Home"
          actions={<NavigationButton href={Routes.settings_profile_path()}>Open profile settings</NavigationButton>}
        />
        <WithPreviewSidebar className="flex-1">
          <section className="grid content-start gap-8 p-4! md:p-8!">
            {page.custom_html ? (
              <Alert role="status" variant="success">
                <div className="flex flex-col justify-between gap-2 sm:flex-row sm:items-center">
                  <span>
                    Your custom home page is live — it replaces the default template. Update it with your agent or the
                    CLI, or remove it to restore the default template.
                  </span>
                  {canEdit ? (
                    <Button color="danger" outline disabled={isRemovingCustomHtml} onClick={removeProfileCustomHtml}>
                      {isRemovingCustomHtml ? "Removing..." : "Remove custom page"}
                    </Button>
                  ) : null}
                </div>
              </Alert>
            ) : null}
            {canEdit ? agentPanel : null}
          </section>
          {previewSidebar}
        </WithPreviewSidebar>
      </>
    );
  }

  return (
    <>
      <PageHeader
        className="sticky-top"
        title={is_new ? "New page" : page.title}
        actions={
          // Custom HTML pages can't be edited here, so a save button would be
          // a dead control; read-only roles get no buttons for the same reason.
          isEditable ? (
            <div className="flex items-center gap-2">
              <Button disabled={isSaving} onClick={backToList}>
                Cancel
              </Button>
              <Button color="accent" disabled={isSaving || title.trim() === ""} onClick={save}>
                {isSaving ? "Saving..." : is_new ? "Create page" : "Save changes"}
              </Button>
            </div>
          ) : (
            <NavigationButton href={Routes.pages_path()}>Back to Pages</NavigationButton>
          )
        }
      />
      <WithPreviewSidebar className="flex-1">
        <section className="grid content-start gap-8 p-4! md:p-8!">
          {!canEdit ? (
            <Alert role="status" variant="info">
              Your role can view this page but can't make changes. Ask an admin or marketing teammate to edit it.
            </Alert>
          ) : null}
          {page.custom_html ? (
            // The agent panel's intro already explains why there's no editor
            // here ("custom HTML, can't be edited here"), so no separate alert.
            canEdit ? (
              agentPanel
            ) : null
          ) : (
            <>
              <Fieldset>
                <Label htmlFor="page-title">Title</Label>
                <Input
                  id="page-title"
                  type="text"
                  value={title}
                  placeholder="About"
                  disabled={!canEdit}
                  onChange={(e) => setTitle(e.target.value)}
                />
              </Fieldset>
              <Fieldset>
                <Label htmlFor="page-content">Content</Label>
                <RichTextEditor
                  id="page-content"
                  className="textarea block w-full rounded border border-border bg-background px-4 py-3 text-foreground placeholder:text-muted focus-within:outline-2 focus-within:outline-offset-0 focus-within:outline-accent"
                  ariaLabel="Page content"
                  placeholder="Write your page..."
                  initialValue={page.content}
                  editable={canEdit}
                  onChange={setContent}
                />
              </Fieldset>
              {canEdit ? agentPanel : null}
            </>
          )}
        </section>
        {previewSidebar}
      </WithPreviewSidebar>
    </>
  );
}
