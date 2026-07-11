import { Copy, MagicWand, Terminal } from "@boxicons/react";
import { router, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { RichTextEditor } from "$app/components/RichTextEditor";
import { Alert } from "$app/components/ui/Alert";
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

// The copy-paste prompt for building a page with an agent. The agent path is
// the recommended way to build a page; the CLI commands it references are the
// same ones a seller can run by hand.
const agentPrompt = (username: string, slug: string | null, isProfile: boolean) =>
  isProfile
    ? `Build and publish a custom landing page for my Gumroad profile (@${username}). Design a unique, on-brand page — fully responsive, with light and dark mode. Preview it with \`gumroad pages preview\`, then publish with \`gumroad pages push profile\`. The page replaces my entire profile, so link visitors to my product pages instead of adding checkout elements.`
    : `Build and publish a custom page for my Gumroad store (@${username})${slug ? ` at /${slug}` : ""}. Design a unique, on-brand page — fully responsive, with light and dark mode. Preview it with \`gumroad pages preview\`, then publish with \`gumroad pages push ${slug ?? "<slug>"}\`.`;

export default function PagesEdit() {
  const { page, is_profile, is_new, username, profile_url } = typia.assert<PageProps>(usePage().props);

  const [title, setTitle] = React.useState(page.title);
  const [content, setContent] = React.useState(page.content);
  // The preview refreshes on save, not on every keystroke — it renders the
  // saved page through the same wrapper the public page uses.
  const [previewContent, setPreviewContent] = React.useState(page.content);
  const [previewTitle, setPreviewTitle] = React.useState(page.title);
  const [isSaving, setIsSaving] = React.useState(false);

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
      onFinish: () => setIsSaving(false),
    };
    if (is_new) router.post(Routes.pages_path(), params, options);
    else if (page.slug) router.patch(Routes.page_path(page.slug), params, options);
  };

  const agentPanel = (
    <div className="grid gap-3 rounded border border-border p-4">
      <div className="flex items-center gap-2">
        <MagicWand className="size-5" />
        <h3>Build with your agent</h3>
      </div>
      <p className="text-sm text-muted">
        The best way to build a page. Your agent designs it as full HTML — custom layout, animations, anything — and
        publishes it for you. Copy this prompt to get started:
      </p>
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

  const previewSidebar = (
    <PreviewSidebar
      previewLink={(props) => (
        <NavigationButton {...props} size="icon" href={publicUrl} target="_blank" rel="noreferrer" />
      )}
    >
      <div className="overflow-hidden rounded border border-border bg-background">
        {/* DESIGN STUB: the real preview renders the saved page through the same
            sanitizer + wrapper pipeline as the public page, refreshed on save.
            Here we approximate it with the saved rich text inside a storefront-
            like frame. */}
        <div className="border-b border-border p-3">
          <div className="text-sm font-medium">{previewTitle || "Untitled page"}</div>
          <div className="truncate text-xs text-muted">{publicUrl.replace(/^https?:\/\//u, "")}</div>
        </div>
        {is_profile || page.custom_html ? (
          <iframe
            title="Page preview"
            src={publicUrl}
            sandbox="allow-scripts allow-forms"
            className="aspect-[3/4] w-full"
          />
        ) : (
          <div
            className="rich-text aspect-[3/4] w-full overflow-y-auto p-4"
            // eslint-disable-next-line react/no-danger -- design stub; the real preview goes through the sanitizer pipeline server-side
            dangerouslySetInnerHTML={{ __html: previewContent || "<p style='opacity:.5'>Nothing here yet.</p>" }}
          />
        )}
      </div>
      <p className="text-xs text-muted">The preview refreshes when you save.</p>
    </PreviewSidebar>
  );

  if (is_profile) {
    return (
      <>
        <PageHeader
          className="sticky-top"
          title="Profile"
          actions={<NavigationButton href={Routes.settings_profile_path()}>Open profile settings</NavigationButton>}
        />
        <WithPreviewSidebar className="flex-1">
          <div className="grid content-start gap-6 p-4 md:p-8">
            <Alert role="status" variant="info">
              Your profile is the home page of your store. It ships with the default template — product grid, follow
              form, tabs — with the details editable in profile settings. It's yours to change completely: have your
              agent replace it with a fully custom page.
            </Alert>
            {page.custom_html ? (
              <Alert role="status" variant="success">
                Your custom profile page is live — it replaces the default template. Update it with your agent or the
                CLI, or remove it from profile settings to restore the default template.
              </Alert>
            ) : null}
            {agentPanel}
          </div>
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
          <Button color="accent" disabled={isSaving || title.trim() === ""} onClick={save}>
            {isSaving ? "Saving..." : is_new ? "Create page" : "Save changes"}
          </Button>
        }
      />
      <WithPreviewSidebar className="flex-1">
        <div className="grid content-start gap-6 p-4 md:p-8">
          {page.custom_html ? (
            <>
              <Alert role="status" variant="info">
                This page was built with custom HTML by your agent, so it can't be edited here — editing it manually
                would lose the custom layout. Update it with your agent or the CLI instead.
              </Alert>
              {agentPanel}
            </>
          ) : (
            <>
              <fieldset>
                <Label htmlFor="page-title">Title</Label>
                <Input
                  id="page-title"
                  type="text"
                  value={title}
                  placeholder="About"
                  onChange={(e) => setTitle(e.target.value)}
                />
              </fieldset>
              <fieldset>
                <Label htmlFor="page-content">Content</Label>
                <RichTextEditor
                  id="page-content"
                  ariaLabel="Page content"
                  placeholder="Write your page..."
                  initialValue={page.content}
                  onChange={setContent}
                />
              </fieldset>
              {agentPanel}
            </>
          )}
        </div>
        {previewSidebar}
      </WithPreviewSidebar>
    </>
  );
}
