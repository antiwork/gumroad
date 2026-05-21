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

  const { product, updateProduct, profileSections, taxonomies, isListedOnDiscover } = useProductEditContext();

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
          {currentSeller.pagesEnabled ? (
            <LandingPageSplash productPermalink={product.custom_permalink ?? product.unique_permalink ?? ""} />
          ) : null}
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

type Template = {
  id: string;
  name: string;
  description: string;
  icon: string;
};

const LandingPageSplash = ({ productPermalink }: { productPermalink: string }) => {
  const [templates, setTemplates] = React.useState<Template[]>([]);

  React.useEffect(() => {
    let cancelled = false;
    fetch("/pages/templates", { headers: { Accept: "application/json" }, credentials: "same-origin" })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`Templates fetch failed: ${r.status}`))))
      .then((data: { templates: Template[] }) => {
        if (!cancelled) setTemplates(data.templates);
      })
      .catch(() => {
        /* silent — section still works as a plain CTA */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const newPageHref = (templateId?: string) => {
    const params = new URLSearchParams();
    if (productPermalink) params.set("product_id", productPermalink);
    if (templateId) params.set("template", templateId);
    return `/pages/new?${params.toString()}`;
  };

  return (
    <section className="grid gap-6 border-t border-border p-4 md:p-8">
      <header>
        <h2>Landing page</h2>
        <p className="text-sm text-muted">
          Use the basic Gumroad product page, or pick a template and let AI build a custom landing page for this
          product.
        </p>
      </header>
      {templates.length > 0 ? (
        <div className="grid grid-cols-2 gap-3 md:grid-cols-3 lg:grid-cols-4">
          {templates.map((template) => (
            <a
              key={template.id}
              href={newPageHref(template.id)}
              className="flex flex-col items-start gap-2 rounded-lg border border-border p-4 text-left no-underline transition-colors hover:border-accent/50"
            >
              <span className="text-3xl leading-none" aria-hidden="true">
                {template.icon}
              </span>
              <h4 className="font-bold">{template.name}</h4>
              <p className="text-sm text-muted">{template.description}</p>
            </a>
          ))}
        </div>
      ) : null}
      <div>
        <Button asChild>
          <a href={newPageHref()}>Start from scratch</a>
        </Button>
      </div>
    </section>
  );
};
