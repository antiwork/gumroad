import * as React from "react";
import ReactDOMServer from "react-dom/server";
import { createCast } from "ts-safe-cast";

import { register } from "$app/utils/serverComponentUtil";
import { buildOverlayCodeToCopy, buildEmbedCodeToCopy } from "$app/utils/widgetCodeToCopyBuilders";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { CodeContainer } from "$app/components/Developer/CodeContainer";
import { FollowFormEmbed, FOLLOW_FORM_EMBED_INPUT_ID } from "$app/components/Developer/FollowFormEmbed";
import { Layout } from "$app/components/Developer/Layout";
import { ProductSelect, Product } from "$app/components/Developer/ProductSelect";
import { Tab, Tabs } from "$app/components/Developer/Tabs";
import { useHasChanged } from "$app/components/Developer/useHasChanged";
import { DomainSettingsProvider, useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";

type Props = {
  default_product: Product;
  display_product_select: boolean;
  products: Product[];
  affiliated_products: Product[];
};

export const WidgetsPage = ({ display_product_select, products, affiliated_products, default_product }: Props) => {
  const currentSeller = useCurrentSeller();
  const domains = useDomains();

  const copyButtonUID = React.useId();
  const followFormEmbedUID = React.useId();
  const [followFormEmbedHTML, setFollowFormEmbedHTML] = React.useState("");
  React.useEffect(
    () =>
      setFollowFormEmbedHTML(
        currentSeller
          ? ReactDOMServer.renderToString(
              <DomainSettingsProvider value={domains}>
                <FollowFormEmbed sellerId={currentSeller.id} />
              </DomainSettingsProvider>,
            )
          : "",
      ),
    [currentSeller],
  );

  return (
    <Layout currentPage="widgets">
      <form>
        <section className="p-4! md:p-8!">
          <header>
            <h3>Share your product</h3>
            <p>
              You can easily bring the Gumroad purchase page right into your site, without directing your buyers
              elsewhere.{" "}
              <a href="/help/article/44-build-gumroad-into-your-website" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </p>
          </header>
          <div>
            <Widgets
              display_product_select={display_product_select}
              products={products}
              affiliated_products={affiliated_products}
              default_product={default_product}
            />
          </div>
        </section>
        {currentSeller ? (
          <section className="p-4! md:p-8!">
            <header>
              <h3>Subscribe form</h3>
              <p>
                Share your subscribe form on any website or blog using an embed or URL.{" "}
                <a href="/help/article/170-audience" target="_blank" rel="noreferrer">
                  Learn more
                </a>
              </p>
            </header>
            <fieldset>
              <legend>
                <label htmlFor={copyButtonUID}>Share your subscribe page and grow your audience</label>
              </legend>
              <CopyToClipboard
                text={Routes.custom_domain_subscribe_url({ host: currentSeller.subdomain })}
                copyTooltip="Copy link"
                tooltipPosition="bottom"
              >
                <Button id={copyButtonUID} color="primary">
                  <Icon name="link" />
                  Copy link
                </Button>
              </CopyToClipboard>
            </fieldset>
            <fieldset>
              <legend>
                <label htmlFor={FOLLOW_FORM_EMBED_INPUT_ID}>Test your subscribe form with your email</label>
              </legend>
              <FollowFormEmbed sellerId={currentSeller.id} preview />
            </fieldset>
            <fieldset>
              <legend>
                <label htmlFor={followFormEmbedUID}>Subscribe form embed code</label>
                <CopyToClipboard text={followFormEmbedHTML} copyTooltip="Copy to Clipboard" tooltipPosition="top">
                  <button type="button" className="link">
                    Copy embed code
                  </button>
                </CopyToClipboard>
              </legend>
              <textarea id={followFormEmbedUID} value={followFormEmbedHTML} readOnly />
            </fieldset>
          </section>
        ) : null}
      </form>
    </Layout>
  );
};

const Widgets = ({ display_product_select, products, affiliated_products, default_product }: Props) => {
  const [selectedProduct, setSelectedProduct] = React.useState(default_product);
  const [selectedTab, setSelectedTab] = React.useState<Tab>("overlay");
  const overlayTabpanelUID = React.useId();
  const embedTabpanelUID = React.useId();

  const productSelect = (
    <ProductSelect
      selectedProductUrl={selectedProduct.url}
      products={products}
      affiliatedProducts={affiliated_products}
      onProductSelectChange={setSelectedProduct}
    />
  );

  return (
    <>
      <Tabs
        tab={selectedTab}
        setTab={setSelectedTab}
        overlayTabpanelUID={overlayTabpanelUID}
        embedTabpanelUID={embedTabpanelUID}
      />
      <div
        role="tabpanel"
        id={overlayTabpanelUID}
        style={{
          display: selectedTab === "overlay" ? "grid" : "none",
          gap: "var(--spacer-6)",
        }}
      >
        {display_product_select ? productSelect : null}
        <OverlayPanel selectedProduct={selectedProduct} />
      </div>
      <div
        role="tabpanel"
        id={embedTabpanelUID}
        style={{
          display: selectedTab === "embed" ? "grid" : "none",
          gap: "var(--spacer-6)",
        }}
      >
        {display_product_select ? productSelect : null}
        <EmbedPanel selectedProduct={selectedProduct} />
      </div>
    </>
  );
};

type PanelProps = {
  selectedProduct: Product;
};

const OverlayPanel = ({ selectedProduct }: PanelProps) => {
  const [isWanted, setIsWanted] = React.useState(false);
  const [buttonText, setButtonText] = React.useState("");
  const [codeToCopy, setCodeToCopy] = React.useState("");
  const [overlayPreviewUrl, setOverlayPreviewUrl] = React.useState("");
  const buttonTextUID = React.useId();
  const overlayPreviewUID = React.useId();

  React.useEffect(() => {
    const { script_base_url: scriptBaseUrl, url: productUrl } = selectedProduct;

    setCodeToCopy(
      buildOverlayCodeToCopy({
        scriptBaseUrl,
        productUrl,
        isWanted,
        buttonText,
      }),
    );
  }, [selectedProduct, buttonText, isWanted]);

  React.useEffect(() => setOverlayPreviewUrl(selectedProduct.gumroad_domain_url), [selectedProduct, isWanted]);

  const hasChanged = useHasChanged([overlayPreviewUrl, isWanted]);

  return (
    <>
      <div style={{ display: "flex", flexWrap: "wrap", gap: "var(--spacer-5)" }}>
        <fieldset style={{ flexGrow: 1 }}>
          <legend>
            <label htmlFor={buttonTextUID}>Button text</label>
          </legend>
          <input
            id={buttonTextUID}
            type="text"
            placeholder="Buy on"
            value={buttonText}
            onChange={(evt) => setButtonText(evt.target.value)}
          />
        </fieldset>
        <fieldset>
          <legend>
            <label htmlFor={overlayPreviewUID}>Button Preview</label>
          </legend>
          {!hasChanged ? (
            <a
              id={overlayPreviewUID}
              href={overlayPreviewUrl}
              className="gumroad-button"
              data-gumroad-overlay-checkout={isWanted}
            >
              {/* Without <span> React overwrites overlay script changes  - https://github.com/gumroad/web/pull/27983 */}
              <span>{buttonText || "Buy on"}</span>
            </a>
          ) : null}
        </fieldset>
      </div>
      <CodeContainer codeToCopy={codeToCopy} />
      <fieldset className="override grid gap-4">
        <label>
          <input type="checkbox" checked={isWanted} onChange={(e) => setIsWanted(e.target.checked)} role="switch" />
          Send directly to checkout page
        </label>
      </fieldset>
    </>
  );
};

const EmbedPanel = ({ selectedProduct }: PanelProps) => {
  const [codeToCopy, setCodeToCopy] = React.useState("");

  React.useEffect(() => {
    const { script_base_url: scriptBaseUrl, url: productUrl } = selectedProduct;

    setCodeToCopy(buildEmbedCodeToCopy({ scriptBaseUrl, productUrl }));
  }, [selectedProduct]);

  const hasChanged = useHasChanged([selectedProduct.url]);

  return (
    <>
      <div className="embed-preview-wrapper">
        {!hasChanged ? (
          <div>
            <div className="gumroad-product-embed">
              <a href={selectedProduct.url}>Loading...</a>
            </div>
          </div>
        ) : null}
      </div>
      <CodeContainer codeToCopy={codeToCopy} />
    </>
  );
};

export default register({ component: WidgetsPage, propParser: createCast() });
