import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { ThirdPartyAnalytics, Snippet, SNIPPET_LOCATIONS } from "$app/data/third_party_analytics";
import { SettingPage } from "$app/parsers/settings";

import { Button } from "$app/components/Button";
import { Details } from "$app/components/Details";
import { Dropdown } from "$app/components/Dropdown";
import { Icon } from "$app/components/Icons";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { Layout as SettingsLayout } from "$app/components/Settings/Layout";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Placeholder } from "$app/components/ui/Placeholder";
import { Row, RowActions, RowContent, RowDetails, Rows } from "$app/components/ui/Rows";

type Products = { permalink: string; name: string }[];

type ThirdPartyAnalyticsPageProps = {
  settings_pages: SettingPage[];
  third_party_analytics: ThirdPartyAnalytics;
  products: Products;
};

export default function ThirdPartyAnalyticsPage() {
  const props = cast<ThirdPartyAnalyticsPageProps>(usePage().props);
  const loggedInUser = useLoggedInUser();

  const form = useForm({
    user: props.third_party_analytics,
  });

  const thirdPartyAnalytics = form.data.user;
  const updateThirdPartyAnalytics = (update: Partial<ThirdPartyAnalytics>) =>
    form.setData("user", {
      ...form.data.user,
      ...update,
    });

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
  const handleSave = () => {
    form.transform((data) => ({
      user: {
        ...data.user,
        snippets: data.user.snippets.map((snippet: Snippet) => ({
          ...snippet,
          id: snippet.id && !snippet.id.startsWith(NEW_SNIPPET_ID_PREFIX) ? snippet.id : null,
        })),
      },
    }));

    form.put(Routes.settings_third_party_analytics_path(), {
      preserveScroll: true,
    });
  };

  return (
    <SettingsLayout
      currentPage="third_party_analytics"
      pages={props.settings_pages}
      onSave={handleSave}
      canUpdate={Boolean(loggedInUser?.policies.settings_third_party_analytics_user.update) && !form.processing}
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
            <Dropdown className="flex flex-col gap-4">
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
            </Dropdown>
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
            <Dropdown className="flex flex-col gap-4">
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
            </Dropdown>
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
              <Rows role="list">
                {thirdPartyAnalytics.snippets.map((snippet) => (
                  <SnippetRow
                    key={snippet.id}
                    snippet={snippet}
                    thirdPartyAnalytics={thirdPartyAnalytics}
                    updateThirdPartyAnalytics={updateThirdPartyAnalytics}
                    products={props.products}
                  />
                ))}
              </Rows>
              {addSnippetButton}
            </>
          ) : (
            <Placeholder>{addSnippetButton}</Placeholder>
          )}
        </section>
      </form>
    </SettingsLayout>
  );
}

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
    <Row role="listitem">
      <RowContent>
        <Icon name="code-square" className="type-icon" />
        <div>
          <h4>{snippet.name || "Untitled"}</h4>
          <ul className="inline">
            <li>{products.find(({ permalink }) => permalink === snippet.product)?.name ?? "All products"}</li>
            <li>{LOCATION_TITLES[snippet.location]}</li>
          </ul>
        </div>
      </RowContent>
      <RowActions>
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
      </RowActions>
      {expanded ? (
        <RowDetails className="flex flex-col gap-4">
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
        </RowDetails>
      ) : null}
    </Row>
  );
};
