import * as React from "react";

import { assertResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Modal } from "$app/components/Modal";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";

export const ProfileLandingPageEditor = ({
  username,
  profileUrl,
  hasLandingPage,
  onRemove,
}: {
  username: string;
  profileUrl: string;
  hasLandingPage: boolean;
  // Clears the custom HTML through the session-authed profile form (blank reset). Returns true on
  // success so the modal only closes when the page was actually removed.
  onRemove: () => Promise<boolean>;
}) => {
  const [isRemoveOpen, setIsRemoveOpen] = React.useState(false);
  const [isRemoving, setIsRemoving] = React.useState(false);

  // No checkout affordances here, unlike the product landing page: a profile has no native buy
  // button, so the prompt links to products/sections instead of embedding buy elements.
  const agentPrompt = `Build and publish a custom landing page for my Gumroad profile (@${username}).

Design a unique, on-brand profile page that reflects who I am and what I sell — fully responsive, accessible, and supporting light and dark mode. Save it as one self-contained file, profile.html. The page is sanitized and runs sandboxed: inline CSS/JS (animations, scroll effects, modals) and a Tailwind CDN work. For images and media, use only inline data: URIs or CSS — external image/media hosts are blocked, and the page can't fetch external URLs or read your account.

A custom profile page REPLACES your entire public profile at gumroad.com/${username}, including the default sections and product grid. There is NO buy button on a profile, so don't add checkout elements — instead, link visitors to your individual product pages or to a section of your storefront.

Gumroad fills in live values server-side, so the page stays current without you editing it. Mark text with data attributes:
- data-gumroad-field="name" — interpolated with your profile name.
- data-gumroad-field="bio" — interpolated with your profile bio.

Your live catalog is injected server-side as JSON in <script id="gumroad-data" type="application/json">, so prefer rendering products/posts/pages dynamically from it (it updates automatically as you add or remove them) instead of hardcoding. Read it with:
  const data = JSON.parse(document.getElementById("gumroad-data").textContent);
Shape: { products: [{ name, url, price, native_type, thumbnail_url, description }], posts: [{ name, url, published_at }], pages: [{ name }] }. Link products via product.url (their public product page) using plain <a> tags with no target attribute — Gumroad injects a navigation bridge that opens store links in the visitor's tab (target="_top"/"_parent" are stripped by the sanitizer, so don't use them). The page can't fetch anything at runtime (it's sandboxed), so this injected data is the source of truth.

Then preview, publish, and verify it with the Gumroad CLI:
- Run the real server-side sanitizer WITHOUT publishing and read what it changed: gumroad user page preview ./profile.html --json --no-input --non-interactive — inspect .sanitization_report. If it stripped tags or attributes your page needs, fix the HTML and preview again. Do this until the report is clean so you never publish a broken page.
- Publish (or update) the page once preview is clean: gumroad user page publish ./profile.html --json --no-input --non-interactive — .sanitization_report reflects what actually shipped.
- Confirm it's live and find the public URL: gumroad user page url --json --jq '.profile.landing_url' --no-input --non-interactive
- Remove the custom profile page and restore your default profile: gumroad user page clear --yes --json --no-input --non-interactive

If the gumroad CLI isn't installed: brew install antiwork/cli/gumroad (or curl -fsSL https://gumroad.com/install-cli.sh | bash), then run gumroad auth login.`;

  const removeLandingPage = async () => {
    setIsRemoving(true);
    try {
      const removed = await onRemove();
      if (removed) {
        setIsRemoveOpen(false);
        showAlert("Your custom profile page is removed.", "success");
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsRemoving(false);
    }
  };

  return (
    <section className="grid gap-8 border-t border-border p-4 md:p-8">
      <header className="flex items-center justify-between">
        <h2>Custom profile page</h2>
        <a href="/api#custom-html" target="_blank" rel="noreferrer">
          Learn more about custom pages
        </a>
      </header>
      {hasLandingPage ? (
        <Alert role="status" variant="success">
          <div className="flex flex-col justify-between sm:flex-row">
            Your custom profile page is live.
            <a href={profileUrl} target="_blank" rel="noreferrer">
              View page
            </a>
          </div>
        </Alert>
      ) : null}
      <div className="grid gap-2">
        <p>
          Replace your default profile with a fully custom page — your own background, fonts, and layout. Copy the
          prompt and hand it to your AI agent (Claude, Cursor, etc.) — it builds and publishes the page for you.
        </p>
        <p className="text-sm text-muted">
          Your page runs safely on its own: animations and interactive effects work, but it can't reach your Gumroad
          account or send your data to other sites.
        </p>
      </div>
      <div className="flex flex-wrap gap-3">
        <CopyToClipboard text={agentPrompt} tooltipPosition="top">
          <Button color="primary">Copy prompt</Button>
        </CopyToClipboard>
        {hasLandingPage ? <Button onClick={() => setIsRemoveOpen(true)}>Remove custom page</Button> : null}
      </div>
      <Details>
        <DetailsToggle>Show prompt</DetailsToggle>
        <pre className="rounded border border-border bg-background p-4 text-sm whitespace-pre-wrap">{agentPrompt}</pre>
      </Details>
      {isRemoveOpen ? (
        <Modal
          open
          allowClose={!isRemoving}
          onClose={() => setIsRemoveOpen(false)}
          title="Remove custom profile page?"
          footer={
            <>
              <Button disabled={isRemoving} onClick={() => setIsRemoveOpen(false)}>
                Cancel
              </Button>
              <Button color="danger" disabled={isRemoving} onClick={() => void removeLandingPage()}>
                {isRemoving ? "Removing..." : "Remove"}
              </Button>
            </>
          }
        >
          This removes your custom page, so visitors will see your default profile again. You can't undo it — if you
          might want the page back, save its HTML first.
        </Modal>
      ) : null}
    </section>
  );
};
