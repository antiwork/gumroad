import * as React from "react";

import { Layout, useProductUrl } from "$app/components/BundleEdit/Layout";
import { ProductPreview } from "$app/components/BundleEdit/ProductPreview";
import { MarketingEmailStatus } from "$app/components/BundleEdit/ShareTab/MarketingEmailStatus";
import { useBundleEditContext } from "$app/components/BundleEdit/state";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { FacebookShareButton } from "$app/components/FacebookShareButton";
import { Icon } from "$app/components/Icons";
import { ProfileSectionsEditor } from "$app/components/ProductEdit/ShareTab/ProfileSectionsEditor";
import { TagSelector } from "$app/components/ProductEdit/ShareTab/TagSelector";
import { TaxonomyEditor } from "$app/components/ProductEdit/ShareTab/TaxonomyEditor";
import { Toggle } from "$app/components/Toggle";
import { TwitterShareButton } from "$app/components/TwitterShareButton";

export const ShareTab = () => {
  const { bundle, updateBundle, taxonomies, profileSections } = useBundleEditContext();
  const currentSeller = useCurrentSeller();
  const url = useProductUrl();

  if (!currentSeller) return;

  return (
    <Layout preview={<ProductPreview />}>
      <form>
        <section className="p-4! md:p-8!">
          <header>
            <h2>Share</h2>
          </header>
          <div className="button-group">
            <TwitterShareButton url={url} text={`Buy ${bundle.name} on @Gumroad`} />
            <FacebookShareButton url={url} text={bundle.name} />
            <CopyToClipboard text={url} tooltipPosition="top">
              <Button color="primary">
                <Icon name="link" />
                Copy URL
              </Button>
            </CopyToClipboard>
          </div>
          <section>
            <MarketingEmailStatus />
          </section>
        </section>
        <ProfileSectionsEditor
          sectionIds={bundle.section_ids}
          onChange={(sectionIds) => updateBundle({ section_ids: sectionIds })}
          profileSections={profileSections}
        />
        <section className="p-4! md:p-8!">
          <header className="flex items-center justify-between">
            <h2>Gumroad Discover</h2>
            <a href="/help/article/79-gumroad-discover" target="_blank" rel="noreferrer">
              Learn more
            </a>
          </header>
          <div className="paragraphs">
            <p>
              Gumroad Discover recommends your products to prospective customers for a flat 30% fee on each sale,
              helping you grow beyond your existing following and find even more people who care about your work.
            </p>
            <p>When enabled, the product will also become part of the Gumroad affiliate program.</p>
          </div>
          <TaxonomyEditor
            taxonomyId={bundle.taxonomy_id}
            onChange={(taxonomy_id) => updateBundle({ taxonomy_id })}
            taxonomies={taxonomies}
          />
          <TagSelector tags={bundle.tags} onChange={(tags) => updateBundle({ tags })} />
          <fieldset>
            <Toggle
              value={bundle.display_product_reviews}
              onChange={(newValue) => updateBundle({ display_product_reviews: newValue })}
            >
              Display your product's 1-5 star rating to prospective customers
            </Toggle>
            <Toggle value={bundle.is_adult} onChange={(newValue) => updateBundle({ is_adult: newValue })}>
              This product contains content meant only for adults, including the preview
            </Toggle>
          </fieldset>
        </section>
      </form>
    </Layout>
  );
};
