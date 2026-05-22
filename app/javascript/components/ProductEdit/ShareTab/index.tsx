import { Link } from "@boxicons/react";
import * as React from "react";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDiscoverUrl } from "$app/components/DomainSettings";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { Layout, useProductUrl } from "$app/components/ProductEdit/Layout";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { ProfileSectionsEditor } from "$app/components/ProductEdit/ShareTab/ProfileSectionsEditor";
import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";
import { TaxonomyEditor } from "$app/components/ProductEdit/ShareTab/TaxonomyEditor";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { TwitterShareButton } from "$app/components/TwitterShareButton";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Switch } from "$app/components/ui/Switch";
import { useRunOnce } from "$app/components/useRunOnce";

import hands from "$assets/images/illustrations/hands.png";

export const ShareTab = () => {
  const currentSeller = useCurrentSeller();

  const { product, updateProduct, profileSections, taxonomies, isListedOnDiscover, uniquePermalink } =
    useProductEditContext();

  const url = useProductUrl();
  const discoverUrl = useDiscoverUrl();

  if (!currentSeller) return;
  const discoverLink = new URL(discoverUrl);
  discoverLink.searchParams.set("query", product.name);

  return (
    <Layout preview={<ProductPreview />}>
      <div className="squished">
        <form>
          <section className="grid gap-8 p-4! md:p-8!">
            <DiscoverEligibilityPromo />
            <header>
              <h2>Share</h2>
            </header>
            <div className="flex flex-wrap gap-2">
              <TwitterShareButton url={url} text={`Buy ${product.name} on @Gumroad`} />
              <FacebookShareButton url={url} text={product.name} />
              <CopyToClipboard text={url} tooltipPosition="top">
                <Button color="primary">
                  <Link className="size-5" />
                  Copy URL
                </Button>
              </CopyToClipboard>
            </div>
          </section>
          {currentSeller.pagesEnabled ? <LandingPageSplash productPermalink={uniquePermalink} /> : null}
          <ProfileSectionsEditor
            sectionIds={product.section_ids}
            onChange={(sectionIds) => updateProduct({ section_ids: sectionIds })}
            profileSections={profileSections}
          />
          <section className="grid gap-8 border-t border-border p-4 md:p-8">
            <header style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <h2>Gumroad Discover</h2>
              <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </header>
            {isListedOnDiscover ? (
              <Alert role="status" variant="success">
                <div className="flex flex-col justify-between sm:flex-row">
                  {product.name} is listed on Gumroad Discover.
                  <a href={discoverLink.toString()}>View</a>
                </div>
              </Alert>
            ) : null}
            <div className="flex flex-col gap-4">
              <p>
                Gumroad Discover recommends your products to prospective customers for a flat 30% fee on each sale,
                helping you grow beyond your existing following and find even more people who care about your work.
              </p>
              <p>When enabled, the product will also become part of the Gumroad affiliate program.</p>
            </div>
            <TaxonomyEditor
              taxonomyId={product.taxonomy_id}
              onChange={(taxonomy_id) => updateProduct({ taxonomy_id })}
              taxonomies={taxonomies}
            />
            <TagSelector tags={product.tags} onChange={(tags) => updateProduct({ tags })} />
            <Fieldset>
              <Switch
                checked={product.display_product_reviews}
                onChange={(e) => updateProduct({ display_product_reviews: e.target.checked })}
                label="Display your product's 1-5 star rating to prospective customers"
              />
              <Switch
                checked={product.is_adult}
                onChange={(e) => updateProduct({ is_adult: e.target.checked })}
                label={
                  <>
                    This product contains content meant{" "}
                    <a href="/help/article/156-gumroad-and-adult-content" target="_blank" rel="noreferrer">
                      only for adults,
                    </a>{" "}
                    including the preview
                  </>
                }
              />
            </Fieldset>
          </section>
        </form>
      </div>
    </Layout>
  );
};

const DiscoverEligibilityPromo = () => {
  const [show, setShow] = React.useState(false);

  useRunOnce(() => {
    if (localStorage.getItem("showDiscoverEligibilityPromo") !== "false") setShow(true);
  });

  if (!show) return null;

  return (
    <Alert role="status">
      <div className="flex items-center gap-2">
        <img src={hands} alt="" className="size-12" />
        <div className="flex flex-1 flex-col gap-2">
          <div>
            To appear on Gumroad Discover, make sure to meet all the{" "}
            <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
              eligibility criteria
            </a>
            , which includes making at least one successful sale and completing the Risk Review process explained in
            detail{" "}
            <a href="/help/article/13-getting-paid" target="_blank" rel="noreferrer">
              here
            </a>
            .
          </div>
          <button
            className="w-max cursor-pointer underline all-unset"
            onClick={() => {
              localStorage.setItem("showDiscoverEligibilityPromo", "false");
              setShow(false);
            }}
          >
            Close
          </button>
        </div>
      </div>
    </Alert>
  );
};

const LandingPageSplash = ({ productPermalink }: { productPermalink: string }) => {
  const [existingPageSlug, setExistingPageSlug] = React.useState<string | null>(null);
  const [creating, setCreating] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  // Check if this product already has a page on mount so the button label
  // can flip between "Customize page" (no page yet → POST and redirect) and
  // "Edit page" (page exists → just navigate). One request, single-entry
  // response (PagesController#index is now scoped by product_id).
  React.useEffect(() => {
    if (!productPermalink) return;
    let cancelled = false;
    fetch(`/pages?product_id=${encodeURIComponent(productPermalink)}`, {
      headers: { Accept: "application/json" },
      credentials: "same-origin",
    })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`Page lookup failed: ${r.status}`))))
      .then((data: { pages: { slug: string }[] }) => {
        if (!cancelled && data.pages[0]) setExistingPageSlug(data.pages[0].slug);
      })
      .catch(() => {
        /* silent — falls back to "Customize page" CTA */
      });
    return () => {
      cancelled = true;
    };
  }, [productPermalink]);

  const goToEditor = (slug: string) => {
    window.location.href = `/pages/${slug}/edit?fullscreen=1`;
  };

  const handleCustomize = async () => {
    if (existingPageSlug) {
      goToEditor(existingPageSlug);
      return;
    }
    setCreating(true);
    setError(null);
    try {
      const res = await fetch("/pages", {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": (document.querySelector('meta[name="csrf-token"]') as HTMLMetaElement | null)?.content ?? "",
        },
        credentials: "same-origin",
        body: JSON.stringify({ page: { product_permalink: productPermalink } }),
      });
      const data: { success: boolean; slug?: string; error?: string } = await res.json();
      if (!res.ok || !data.success || !data.slug) {
        setError(data.error ?? "Could not create page.");
        return;
      }
      goToEditor(data.slug);
    } catch {
      setError("Network error. Please try again.");
    } finally {
      setCreating(false);
    }
  };

  return (
    <section className="grid gap-4 border-t border-border p-4 md:p-8">
      <header>
        <h2>Landing page</h2>
        <p className="text-sm text-muted">
          Use the basic Gumroad product page, or let AI build a custom one tailored to this product. The editor is a
          full-screen chat — describe what you want and iterate.
        </p>
      </header>
      <div className="flex items-center gap-3">
        <Button onClick={() => void handleCustomize()} disabled={creating}>
          {creating ? "Opening…" : existingPageSlug ? "Edit page" : "Customize page"}
        </Button>
        {error ? <span className="text-sm text-destructive">{error}</span> : null}
      </div>
    </section>
  );
};
