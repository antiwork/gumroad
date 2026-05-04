import { Link, Sparkle } from "@boxicons/react";
import hands from "images/illustrations/hands.png";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { ResponseError, assertResponseError, request } from "$app/utils/request";

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
import { showAlert } from "$app/components/server-components/Alert";
import { TwitterShareButton } from "$app/components/TwitterShareButton";
import { Alert } from "$app/components/ui/Alert";
import { Fieldset } from "$app/components/ui/Fieldset";
import { Pill } from "$app/components/ui/Pill";
import { Switch } from "$app/components/ui/Switch";
import { useRunOnce } from "$app/components/useRunOnce";

const MAX_ALLOWED_TAGS = 5;
const cleanTag = (tag: string) => tag.toLowerCase().replace(/^[#\s]+|,/gu, "").trim();

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
            <AiTagSuggestions />
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

const AiTagSuggestions = () => {
  const { id, product, updateProduct } = useProductEditContext();
  const [isLoading, setIsLoading] = React.useState(false);
  const [suggestions, setSuggestions] = React.useState<string[]>([]);

  const visibleSuggestions = suggestions.filter((tag) => !product.tags.includes(tag));

  const fetchSuggestions = async () => {
    setIsLoading(true);
    try {
      const response = await request({
        method: "POST",
        url: `/api/v2/products/${encodeURIComponent(id)}/suggest_tags`,
        accept: "json",
      });
      if (!response.ok) throw new ResponseError("Failed to suggest tags.");
      const result = cast<{ tags: string[] }>(await response.json());
      setSuggestions(
        [...new Set(result.tags.map(cleanTag))]
          .filter((tag) => tag.length > 0)
          .slice(0, 7),
      );
    } catch (e) {
      assertResponseError(e);
      showAlert("Failed to suggest tags", "error");
    } finally {
      setIsLoading(false);
    }
  };

  const addTag = (tag: string) => {
    if (product.tags.length >= MAX_ALLOWED_TAGS || product.tags.includes(tag)) return;
    updateProduct({ tags: [...product.tags, tag] });
  };

  return (
    <Fieldset>
      <div className="flex flex-col gap-4">
        <div>
          <Button type="button" color="primary" onClick={() => void fetchSuggestions()} disabled={isLoading}>
            <Sparkle className="size-5" />
            {isLoading ? "Suggesting..." : "✨ Suggest tags with AI"}
          </Button>
        </div>
        {visibleSuggestions.length > 0 ? (
          <div className="flex flex-wrap gap-2">
            {visibleSuggestions.map((tag) => (
              <Pill asChild size="small" key={tag}>
                <button type="button" onClick={() => addTag(tag)} disabled={product.tags.length >= MAX_ALLOWED_TAGS}>
                  {tag}
                </button>
              </Pill>
            ))}
          </div>
        ) : null}
      </div>
    </Fieldset>
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
