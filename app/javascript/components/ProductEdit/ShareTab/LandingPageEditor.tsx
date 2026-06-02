import * as React from "react";

import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Modal } from "$app/components/Modal";
import { useProductUrl } from "$app/components/ProductEdit/Layout";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { Details, DetailsToggle } from "$app/components/ui/Details";

export const LandingPageEditor = () => {
  const { product, uniquePermalink, customHtmlPagesEnabled, updateProduct } = useProductEditContext();
  const url = useProductUrl();
  const hasLandingPage = !!product.custom_html?.trim();
  const [isRemoveOpen, setIsRemoveOpen] = React.useState(false);
  const [isRemoving, setIsRemoving] = React.useState(false);

  if (!customHtmlPagesEnabled) return null;

  const agentPrompt = `Build and publish a custom landing page for my Gumroad product ${uniquePermalink}.

Design a unique, conversion-focused page tailored to this product — fully responsive, accessible, and supporting light and dark mode. Save it as one self-contained file, landing.html. The page is sanitized and runs sandboxed: inline CSS/JS (animations, scroll effects, modals) and a Tailwind CDN work. For images and media, use only your product's own assets (run gumroad products view ${uniquePermalink} for its cover and thumbnail URLs), inline data: URIs, or CSS — external image/media hosts are blocked, and the page can't fetch external URLs or read the buyer's account.

IMPORTANT: a custom landing page REPLACES the entire product page, including the native price and "I want this!" button. Your HTML must include at least one buy element (see below) or the product becomes unpurchasable. Always end by loading the live page and clicking through to checkout to confirm the buy flow works.

Mark live values and buy buttons with data attributes that Gumroad fills in server-side:
- data-gumroad-field="name|price|description" — interpolated with the product's current values.
- data-gumroad-action="buy" — wired up to launch the Gumroad checkout. Use on any element (<a>, <button>, <div>).

For products with selection state, set the choice directly on the buy element so the checkout opens pre-selected (an invalid value silently falls back to the product defaults — it won't break the page):
- data-gumroad-option="<variant name>" — for products with variants/versions/tiers.
- data-gumroad-quantity="<integer>" — for products with quantity enabled.
- data-gumroad-price="<decimal>" — for pay-what-you-want products (major units, e.g. "9.99"). This sets ONE fixed price and sends the buyer straight to checkout.
- data-gumroad-recurrence="monthly|quarterly|biannually|yearly|every_two_years" — for membership/subscription products.

Example buy buttons:
  <a data-gumroad-action="buy">Buy now</a>
  <a data-gumroad-action="buy" data-gumroad-option="Pro" data-gumroad-recurrence="yearly">Buy Pro – $99/year</a>
  <button data-gumroad-action="buy" data-gumroad-quantity="2">Buy 2 seats</button>

For a pay-what-you-want product where the buyer should name their OWN price on the page, render a price <input> and post the chosen amount to checkout yourself (do NOT put data-gumroad-action="buy" on this button — Gumroad's delegated buy handler would intercept it before your custom price is added). The page is allowed to post a "gumroad:checkout" message to its parent with any of: variant, quantity, price, recurrence. Use variant for a variant/version/tier name. An empty price falls back to Gumroad's own price-entry step, so there is no dead end:
  <input id="gr-price" type="number" min="0" step="0.01" placeholder="9.99" />
  <button id="gr-buy" type="button">I want this</button>
  <script>
    document.getElementById("gr-buy").addEventListener("click", function () {
      var v = (document.getElementById("gr-price").value || "").trim(), params = {};
      if (v !== "") { var n = parseFloat(v); if (!isNaN(n) && n >= 0) params.price = String(n); }
      parent.postMessage({ type: "gumroad:checkout", params: params }, "*");
    });
  </script>

Then preview, publish, and verify it with the Gumroad CLI:
- Run the real server-side sanitizer WITHOUT publishing and read what it changed: gumroad products page preview ${uniquePermalink} ./landing.html --json --no-input --non-interactive — inspect .sanitization_report. If it stripped tags or attributes your page needs (a buy element, an <input>, a <script>), fix the HTML and preview again. Do this until the report is clean so you never publish a broken page.
- Also inspect the top-level .warning from preview/publish. If it says the page has no buy element, add data-gumroad-action="buy" or a gumroad:checkout postMessage before publishing.
- Publish (or update) the page once preview is clean: gumroad products page publish ${uniquePermalink} ./landing.html --json --no-input --non-interactive — .sanitization_report reflects what actually shipped.
- Confirm it's live and find the public URL: gumroad products page url ${uniquePermalink} --json --jq '.product.landing_url' --no-input --non-interactive
- Remove the landing page and restore the default product page: gumroad products page clear ${uniquePermalink} --yes --json --no-input --non-interactive

If the gumroad CLI isn't installed: brew install antiwork/cli/gumroad (or curl -fsSL https://gumroad.com/install-cli.sh | bash), then run gumroad auth login.`;

  const removeLandingPage = async () => {
    const previousCustomHtml = product.custom_html;
    setIsRemoving(true);
    updateProduct({ custom_html: null });

    try {
      const response = await request({
        method: "POST",
        accept: "json",
        url: Routes.link_path(uniquePermalink),
        data: { custom_html: null },
      });
      const json: { success?: boolean; message?: string; error_message?: string } = await response.json();
      if (!response.ok || json.success === false) throw new ResponseError(json.message ?? json.error_message);

      setIsRemoveOpen(false);
      showAlert("Landing page removed.", "success");
    } catch (e) {
      assertResponseError(e);
      updateProduct({ custom_html: previousCustomHtml });
      showAlert(e.message, "error");
    } finally {
      setIsRemoving(false);
    }
  };

  return (
    <section className="grid gap-8 border-t border-border p-4 md:p-8">
      <header style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <h2>Landing page</h2>
        <a href="/api#custom-html" target="_blank" rel="noreferrer">
          Learn more
        </a>
      </header>
      {hasLandingPage ? (
        <Alert role="status" variant="success">
          <div className="flex flex-col justify-between sm:flex-row">
            A custom landing page is live on this product.
            <a href={url} target="_blank" rel="noreferrer">
              View
            </a>
          </div>
        </Alert>
      ) : null}
      <div className="grid gap-2">
        <p>
          Replace your default product page with a custom landing page. Copy the prompt and hand it to your AI agent
          (Claude, Cursor, etc.) — it builds and publishes the page for you.
        </p>
        <p className="text-sm text-muted">
          For safety, your landing page is sandboxed: animations and interactive effects work, but it can't reach your
          Gumroad account or send data to other sites.
        </p>
      </div>
      <div className="flex flex-wrap gap-3">
        <CopyToClipboard text={agentPrompt} tooltipPosition="top">
          <Button color="primary">Copy prompt</Button>
        </CopyToClipboard>
        {hasLandingPage ? <Button onClick={() => setIsRemoveOpen(true)}>Remove landing page</Button> : null}
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
          title="Remove landing page?"
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
          This removes your live landing page, so buyers will see your default product page again. You can't undo it —
          if you might want the page back, save its HTML first.
        </Modal>
      ) : null}
    </section>
  );
};
