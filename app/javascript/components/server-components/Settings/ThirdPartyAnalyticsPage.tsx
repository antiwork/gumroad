import * as React from "react";
import { createCast } from "ts-safe-cast";

import {
  saveThirdPartyAnalytics,
  ThirdPartyAnalytics,
  Snippet,
  SNIPPET_LOCATIONS,
} from "$app/data/third_party_analytics";
import { SettingPage } from "$app/parsers/settings";
import { asyncVoid } from "$app/utils/promise";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { Details } from "$app/components/Details";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { showAlert } from "$app/components/server-components/Alert";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";

type Products = { permalink: string; name: string }[];
type Props = {
  settings_pages: SettingPage[];
  third_party_analytics: ThirdPartyAnalytics;
  products: Products;
};

const ThirdPartyAnalyticsPage = ({ settings_pages, third_party_analytics, products }: Props) => {
  const loggedInUser = useLoggedInUser();
  const [thirdPartyAnalytics, setThirdPartyAnalytics] = React.useState(third_party_analytics);
  const updateThirdPartyAnalytics = (update: Partial<ThirdPartyAnalytics>) =>
    setThirdPartyAnalytics((prevThirdPartyAnalytics) => ({ ...prevThirdPartyAnalytics, ...update }));

  const uid = React.useId();

  const addSnippetButton = (
    <Button
      color="primary"
      onClick={() =>
        updateThirdPartyAnalytics({
          snippets: [
            ...thirdPartyAnalytics.snippets,
            { id: `${NEW_SNIPPET_ID_PREFIX}${Math.random()}`, name: "", location: "receipt", code: "", product: null },
          ],
        })
      }
    >
      <Icon name="plus" />
      Add snippet
    </Button>
  );
  return (
    <SettingsLayout
      currentPage="third_party_analytics"
      pages={settings_pages}
      onSave={asyncVoid(async () => {
        const result = await saveThirdPartyAnalytics({
          ...thirdPartyAnalytics,
          snippets: thirdPartyAnalytics.snippets.map((snippet) => ({
            ...snippet,
            id: snippet.id && !snippet.id.startsWith(NEW_SNIPPET_ID_PREFIX) ? snippet.id : null,
          })),
        });
        if (result.success) showAlert("Changes saved!", "success");
        else showAlert(result.error_message, "error");
      })}
      canUpdate={loggedInUser?.policies.settings_third_party_analytics_user.update || false}
    >
      <form>
        <section className="p-4! md:p-8!">
          <header>
            <h2>Third-party analytics</h2>
            <a href="/help/article/174-third-party-analytics" target="_blank" rel="noreferrer">
              Learn more
            </a>
            <div>
              You can add a Facebook tracking pixel and link your Google Analytics properties to track your visitors.
            </div>
          </header>
          <Details
            className="toggle"
            open={!thirdPartyAnalytics.disable_third_party_analytics}
            summary={
              <label>
                <input
                  type="checkbox"
                  role="switch"
                  checked={!thirdPartyAnalytics.disable_third_party_analytics}
                  onChange={(evt) => updateThirdPartyAnalytics({ disable_third_party_analytics: !evt.target.checked })}
                />
                Enable third-party analytics services
              </label>
            }
          >
            <div className="dropdown paragraphs">
              <fieldset>
                <legend>
                  <label htmlFor={`${uid}googleAnalyticsId`}>Google Analytics Property ID</label>
                  <a href="/help/article/174-third-party-analytics" target="_blank" rel="noreferrer">
                    Learn more
                  </a>
                </legend>
                <input
                  id={`${uid}googleAnalyticsId`}
                  type="text"
                  placeholder="G-ABCD232DSE"
                  value={thirdPartyAnalytics.google_analytics_id}
                  onChange={(evt) => updateThirdPartyAnalytics({ google_analytics_id: evt.target.value })}
                />
              </fieldset>
              <fieldset>
                <legend>
                  <label htmlFor={`${uid}facebookPixel`}>Facebook Pixel</label>
                  <a href="/help/article/174-third-party-analytics" target="_blank" rel="noreferrer">
                    Learn more
                  </a>
                </legend>
                <input
                  id={`${uid}facebookPixel`}
                  type="text"
                  placeholder="9127380912836192"
                  value={thirdPartyAnalytics.facebook_pixel_id}
                  onChange={(evt) => updateThirdPartyAnalytics({ facebook_pixel_id: evt.target.value })}
                />
              </fieldset>
              <label>
                <input
                  type="checkbox"
                  checked={!thirdPartyAnalytics.skip_free_sale_analytics}
                  onChange={(evt) => updateThirdPartyAnalytics({ skip_free_sale_analytics: !evt.target.checked })}
                />
                Send 'Purchase' events for free ($0) sales
              </label>
            </div>
          </Details>
        </section>
        <section className="p-4! md:p-8!">
          <header>
            <h2>Domain verification</h2>
          </header>
          <Details
            className="toggle"
            open={thirdPartyAnalytics.enable_verify_domain_third_party_services}
            summary={
              <label>
                <input
                  type="checkbox"
                  role="switch"
                  checked={thirdPartyAnalytics.enable_verify_domain_third_party_services}
                  onChange={(evt) =>
                    updateThirdPartyAnalytics({ enable_verify_domain_third_party_services: evt.target.checked })
                  }
                />
                Verify domain in third-party services
              </label>
            }
          >
            <div className="dropdown paragraphs">
              <fieldset>
                <legend>
                  <label htmlFor={`${uid}facebookMetaTag`}>Facebook Business</label>
                  <a href="/help/article/290-facebook-domain-verification" target="_blank" rel="noreferrer">
                    Learn more
                  </a>
                </legend>
                <textarea
                  id={`${uid}facebookMetaTag`}
                  placeholder='<meta name="facebook-domain-verification" content="me2vv6lgwoh" />'
                  value={thirdPartyAnalytics.facebook_meta_tag}
                  onChange={(evt) => updateThirdPartyAnalytics({ facebook_meta_tag: evt.target.value })}
                />
                <small>Enter meta tag containing the Facebook domain verification code.</small>
              </fieldset>
            </div>
          </Details>
        </section>
        <section className="p-4! md:p-8!">
          <header>
            <h2>Snippets</h2>
            <div>Add custom JavaScript to pages in the checkout flow.</div>
            <a href="/help/article/174-third-party-analytics" target="_blank" rel="noreferrer">
              Learn more
            </a>
          </header>
          {thirdPartyAnalytics.snippets.length > 0 ? (
            <>
              <div className="rows" role="list">
                {thirdPartyAnalytics.snippets.map((snippet) => (
                  <SnippetRow
                    key={snippet.id}
                    snippet={snippet}
                    thirdPartyAnalytics={thirdPartyAnalytics}
                    updateThirdPartyAnalytics={updateThirdPartyAnalytics}
                    products={products}
                  />
                ))}
              </div>
              {addSnippetButton}
            </>
          ) : (
            <div className="placeholder">{addSnippetButton}</div>
          )}
        </section>
      </form>
    </SettingsLayout>
  );
};

const NEW_SNIPPET_ID_PREFIX = "__GUMROAD";

const LOCATION_TITLES: Record<string, string> = {
  receipt: "Receipt",
  product: "Product page",
  all: "All pages",
};

const SnippetRow = ({
  snippet,
  thirdPartyAnalytics,
  updateThirdPartyAnalytics,
  products,
}: {
  snippet: Snippet;
  thirdPartyAnalytics: ThirdPartyAnalytics;
  updateThirdPartyAnalytics: (update: Partial<ThirdPartyAnalytics>) => void;
  products: Products;
}) => {
  const [expanded, setExpanded] = React.useState(!!snippet.id?.startsWith(NEW_SNIPPET_ID_PREFIX));

  const updateSnippet = (update: Partial<Snippet>) => {
    const snippetIndex = thirdPartyAnalytics.snippets.findIndex(({ id }) => id === snippet.id);
    updateThirdPartyAnalytics({
      snippets: [
        ...thirdPartyAnalytics.snippets.slice(0, snippetIndex),
        { ...snippet, ...update },
        ...thirdPartyAnalytics.snippets.slice(snippetIndex + 1),
      ],
    });
  };

  const uid = React.useId();

  return (
    <div role="listitem">
      <div className="content">
        <Icon name="code-square" className="type-icon" />
        <div>
          <h4>{snippet.name || "Untitled"}</h4>
          <ul className="inline">
            <li>{products.find(({ permalink }) => permalink === snippet.product)?.name ?? "All products"}</li>
            <li>{LOCATION_TITLES[snippet.location]}</li>
          </ul>
        </div>
      </div>
      <div className="actions">
        <Button onClick={() => setExpanded((prevExpanded) => !prevExpanded)} aria-label="Edit snippet">
          {expanded ? <Icon name="outline-cheveron-up" /> : <Icon name="outline-cheveron-down" />}
        </Button>
        <Button
          onClick={() =>
            updateThirdPartyAnalytics({
              snippets: thirdPartyAnalytics.snippets.filter(({ id }) => id !== snippet.id),
            })
          }
          aria-label="Delete snippet"
        >
          <Icon name="trash2" />
        </Button>
      </div>
      {expanded ? (
        <div className="paragraphs">
          <fieldset>
            <label htmlFor={`${uid}name`}>Name</label>
            <input
              id={`${uid}name`}
              type="text"
              value={snippet.name}
              onChange={(evt) => updateSnippet({ name: evt.target.value })}
            />
          </fieldset>
          <fieldset>
            <label htmlFor={`${uid}location`}>Location</label>
            <TypeSafeOptionSelect
              id={`${uid}location`}
              value={snippet.location}
              onChange={(key) => updateSnippet({ location: key })}
              options={SNIPPET_LOCATIONS.map((location) => ({
                id: location,
                label: LOCATION_TITLES[location] ?? "Receipt",
              }))}
            />
          </fieldset>
          <fieldset>
            <label htmlFor={`${uid}product`}>Products</label>
            <TypeSafeOptionSelect
              id={`${uid}product`}
              value={snippet.product ?? ""}
              onChange={(key) => updateSnippet({ product: key || null })}
              options={[
                { id: "", label: "All products" },
                ...products.map(({ permalink, name }) => ({
                  id: permalink,
                  label: name,
                })),
              ]}
            />
          </fieldset>
          <fieldset>
            <label htmlFor={`${uid}code`}>Code</label>
            <textarea
              id={`${uid}code`}
              placeholder="Enter your analytics code"
              value={snippet.code}
              onChange={(evt) => updateSnippet({ code: evt.target.value })}
            />
          </fieldset>
        </div>
      ) : null}
    </div>
  );
};

export default register({ component: ThirdPartyAnalyticsPage, propParser: createCast() });
