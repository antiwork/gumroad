import { Copy, MagicWand, Terminal } from "@boxicons/react";
import { router, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { RichTextEditor } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
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
// references are the same ones a seller can run by hand.
const agentPrompt = (username: string, slug: string | null, isProfile: boolean) =>
  isProfile
    ? `Build and publish a custom landing page for my Gumroad profile (@${username}). Design a unique, on-brand page — fully responsive, with light and dark mode. Preview it with \`gumroad pages preview\`, then publish with \`gumroad pages push profile\`. The page replaces my entire profile, so link visitors to my product pages instead of adding checkout elements.`
    : `Build and publish a custom page for my Gumroad store (@${username})${slug ? ` at /${slug}` : ""}. Design a unique, on-brand page — fully responsive, with light and dark mode. Preview it with \`gumroad pages preview\`, then publish with \`gumroad pages push ${slug ?? "<slug>"}\`.`;

export default function PagesEdit() {
  const { page, is_profile, is_new, username, profile_url } = typia.assert<PageProps>(usePage().props);
  const loggedInUser = useLoggedInUser();
  // Mirrors PagePolicy: create? also gates update? and destroy?, so one flag
  // covers everything the editor can change. Viewers without it get a
  // read-only editor instead of buttons whose requests would fail.
  const canEdit = !!loggedInUser?.policies.page.create;

  const [title, setTitle] = React.useState(page.title);
  const [content, setContent] = React.useState(page.content);
  // The preview refreshes on save, not on every keystroke — it renders the
  // saved page through the same wrapper the public page uses. These also
  // double as the last-saved values for unsaved-changes detection.
  const [previewContent, setPreviewContent] = React.useState(page.content);
  const [previewTitle, setPreviewTitle] = React.useState(page.title);
  const [isSaving, setIsSaving] = React.useState(false);

  // Only rich-text pages are editable in place; the profile and custom HTML
  // pages change through profile settings or the agent/CLI.
  const isEditable = canEdit && !is_profile && !page.custom_html;
  const isDirty = isEditable && (title !== previewTitle || content !== previewContent);

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

  const save = () => {
    setIsSaving(true);
    const params = { title, content };
    const options = {
      onSuccess: () => {
        setPreviewContent(content);
        setPreviewTitle(title);
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
  // HTML page the agent is the ONLY way to edit, on a rich-text page it's an
  // upgrade path, and on the profile it replaces the default template.
  const agentPanelHeading = !is_profile && page.custom_html ? "Update with your agent" : "Build with your agent";
  const agentPanelIntro = is_profile
    ? "Replace the default template with a page your agent designs as full HTML — custom layout, animations, anything. Copy this prompt to get started:"
    : page.custom_html
      ? "This page is custom HTML, so your agent (or the CLI) is how you change it. Copy this prompt to get started:"
      : "Want more than rich text? Your agent can redesign this page as full HTML — custom layout, animations, anything — and publish it for you. Copy this prompt to get started:";

  const agentPanel = (
    <div className="grid gap-3 rounded border border-border p-4">
      <div className="flex items-center gap-2">
        <MagicWand className="size-5" />
        <h3>{agentPanelHeading}</h3>
      </div>
      <p className="text-sm text-muted">{agentPanelIntro}</p>
      <div className="flex items-start gap-2 rounded bg-active-bg p-3">
        <p className="min-w-0 flex-1 text-sm">{agentPrompt(username, page.slug, is_profile)}</p>
        <CopyToClipboard text={agentPrompt(username, page.slug, is_profile)}>
          <Button size="icon" aria-label="Copy agent prompt">
            <Copy className="size-4" />
          </Button>
        </CopyToClipboard>
      </div>
      <div className="flex items-center gap-2 text-sm text-muted">
        <Terminal className="size-4" />
        <span>
          Prefer the command line? <code>gumroad pages list</code>, <code>create</code>, <code>push</code>, and{" "}
          <code>preview</code> do the same thing by hand.
        </span>
      </div>
    </div>
  );

  // The caption has to match how each page actually updates: rich-text pages
  // refresh on save, the profile and custom HTML pages frame the live page,
  // and a new page has no public URL until it's created.
  const previewCaption = is_new
    ? "Your page will live at this link once you create it."
    : is_profile || page.custom_html
      ? "The preview shows the live page."
      : "The preview refreshes when you save.";

  const previewSidebar = (
    <PreviewSidebar
      previewLink={
        // A new page has nothing to open yet — the link would 404.
        is_new
          ? undefined
          : (props) => <NavigationButton {...props} size="icon" href={publicUrl} target="_blank" rel="noreferrer" />
      }
    >
      <div className="overflow-hidden rounded border border-border bg-background">
        <div className="border-b border-border p-3">
          <div className="text-sm font-medium">{previewTitle || "Untitled page"}</div>
          <div className="truncate text-xs text-muted">{publicUrl.replace(/^https?:\/\//u, "")}</div>
        </div>
        {is_profile ? (
          // The live storefront in a frame. `allow-same-origin` is needed for the
          // storefront's own scripts to boot — without it the page loads but
          // renders blank. The frame shows our own domain (the seller's public
          // profile), same trust level as the parent page.
          // eslint-disable-next-line react/iframe-missing-sandbox -- allow-scripts + allow-same-origin is intentional for framing our own storefront
          <iframe
            title="Page preview"
            src={publicUrl}
            sandbox="allow-scripts allow-forms allow-same-origin"
            className="aspect-[3/4] w-full"
          />
        ) : page.custom_html ? (
          // Agent-built pages frame the live public page, which serves the
          // stored HTML through the sandboxed wrapper pipeline.
          <iframe title="Page preview" src={publicUrl} sandbox="allow-scripts" className="aspect-[3/4] w-full" />
        ) : (
          <div
            className="rich-text aspect-[3/4] w-full overflow-y-auto p-4"
            dangerouslySetInnerHTML={{ __html: previewContent || "<p style='opacity:.5'>Nothing here yet.</p>" }}
          />
        )}
      </div>
      <p className="text-xs text-muted">{previewCaption}</p>
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
            <Alert role="status" variant="info">
              Your home page is your public profile. It ships with the default template — product grid, follow form,
              tabs — with the details editable in profile settings. It's yours to change completely: have your agent
              replace it with a fully custom page.
            </Alert>
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
            <>
              <Alert role="status" variant="info">
                This page was built with custom HTML by your agent, so it can't be edited here — editing it manually
                would lose the custom layout. Update it with your agent or the CLI instead.
              </Alert>
              {canEdit ? agentPanel : null}
            </>
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
