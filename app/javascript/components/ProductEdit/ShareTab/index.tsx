import hands from "images/illustrations/hands.png";
import * as React from "react";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDiscoverUrl } from "$app/components/DomainSettings";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { Icon } from "$app/components/Icons";
import { Layout, useProductUrl } from "$app/components/ProductEdit/Layout";
import { ProductPreview } from "$app/components/ProductEdit/ProductPreview";
import { ProfileSectionsEditor } from "$app/components/ProductEdit/ShareTab/ProfileSectionsEditor";
import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";
import { TaxonomyEditor } from "$app/components/ProductEdit/ShareTab/TaxonomyEditor";
import { useProductEditContext } from "$app/components/ProductEdit/state";
import { Toggle } from "$app/components/Toggle";
import { TwitterShareButton } from "$app/components/TwitterShareButton";
import { useRunOnce } from "$app/components/useRunOnce";

export const ShareTab = () => {
  const currentSeller = useCurrentSeller();

  const { id, product, updateProduct, profileSections, taxonomies, isListedOnDiscover } = useProductEditContext();

  const url = useProductUrl();
  const discoverUrl = useDiscoverUrl();

  if (!currentSeller) return;
  const discoverLink = new URL(discoverUrl);
  discoverLink.searchParams.set("query", product.name);

  return (
    <Layout preview={<ProductPreview />}>
      <div className="squished">
        <form>
          <section className="!p-4 md:!p-8">
            <DiscoverEligibilityPromo />
            <header>
              <h2>Share</h2>
            </header>
            <div className="button-group">
              <TwitterShareButton url={url} text={`Buy ${product.name} on @Gumroad`} />
              <FacebookShareButton url={url} text={product.name} />
              <CopyToClipboard text={url} tooltipPosition="top">
                <Button color="primary">
                  <Icon name="link" />
                  Copy URL
                </Button>
              </CopyToClipboard>
              <NavigationButton
                href={`https://gum.new?productId=${id}`}
                target="_blank"
                rel="noopener noreferrer"
                color="accent"
              >
                <Icon name="plus" />
                Create Gum
              </NavigationButton>
            </div>
          </section>
          <ProfileSectionsEditor
            sectionIds={product.section_ids}
            onChange={(sectionIds) => updateProduct({ section_ids: sectionIds })}
            profileSections={profileSections}
          />
          <section className="!p-8">
            <header style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <h2>Gumroad Discover</h2>
              <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </header>
            {isListedOnDiscover ? (
              <div role="status" className="success">
                <div>{product.name} is listed on Gumroad Discover.</div>
                <a className="close" href={discoverLink.toString()}>
                  View
                </a>
              </div>
            ) : null}
            <div className="paragraphs">
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
            <fieldset>
              <Toggle
                value={product.display_product_reviews}
                onChange={(newValue) => updateProduct({ display_product_reviews: newValue })}
              >
                Display your product's 1-5 star rating to prospective customers
              </Toggle>
              <Toggle value={product.is_adult} onChange={(newValue) => updateProduct({ is_adult: newValue })}>
                This product contains content meant{" "}
                <a href="/help/article/156-gumroad-and-adult-content" target="_blank" rel="noreferrer">
                  only for adults,
                </a>{" "}
                including the preview
              </Toggle>
            </fieldset>
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
    <div role="status" className="promo">
      <img src={hands} />
      <div>
        To appear on Gumroad Discover, make sure to meet all the{" "}
        <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
          eligibility criteria
        </a>
        , which includes making at least one successful sale and completing the Risk Review process explained in detail{" "}
        <a href="/help/article/13-getting-paid" target="_blank" rel="noreferrer">
          here
        </a>
        .
      </div>
      <button
        className="link close"
        onClick={() => {
          localStorage.setItem("showDiscoverEligibilityPromo", "false");
          setShow(false);
        }}
      >
        Close
      </button>
    </div>
  );
};
