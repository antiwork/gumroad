import { useForm, usePage } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import { getUniquePermalink } from "$app/data/utm_links";
import { assertDefined } from "$app/utils/assert";
import { asyncVoid } from "$app/utils/promise";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { Pill } from "$app/components/ui/Pill";
import { WithTooltip } from "$app/components/WithTooltip";

import { UtmLinkDestinationOption, UtmLinkFormProps } from "$app/types/utm_link";

const MAX_UTM_PARAM_LENGTH = 200;

const duplicatedTitle = (title?: string) => (title ? `${title} (copy)` : "");

export default function UtmLinksNew() {
  const { context, utm_link } = usePage<UtmLinkFormProps>().props;
  const isDuplicating = utm_link !== null && utm_link.id === undefined;
  const uid = React.useId();

  const [{ shortUrlProtocol, shortUrlPrefix, permalink }, setShortUrl] = React.useState(() => {
    const { protocol: shortUrlProtocol, host, pathname } = new URL(utm_link?.short_url ?? context.short_url);
    const currentPermalink = pathname.split("/").pop() ?? "";
    const shortUrlPrefix = host + pathname.slice(0, -currentPermalink.length);
    return {
      shortUrlProtocol,
      shortUrlPrefix,
      permalink: currentPermalink,
    };
  });
  const [isLoadingNewPermalink, setIsLoadingNewPermalink] = React.useState(false);

  const form = useForm<{
    utm_link: {
      title: string;
      target_resource_type: string | null;
      target_resource_id: string | null;
      permalink: string;
      utm_source: string | null;
      utm_medium: string | null;
      utm_campaign: string | null;
      utm_term: string | null;
      utm_content: string | null;
    };
  }>({
    utm_link: {
      title: isDuplicating ? duplicatedTitle(utm_link.title) : (utm_link?.title ?? ""),
      target_resource_type: null,
      target_resource_id: null,
      permalink,
      utm_source: utm_link?.source ?? null,
      utm_medium: utm_link?.medium ?? null,
      utm_campaign: utm_link?.campaign ?? null,
      utm_term: utm_link?.term ?? null,
      utm_content: utm_link?.content ?? null,
    },
  });
  const { data, setData, post, processing, errors } = form;

  // Initialize destination from utm_link if duplicating
  const [destination, setDestination] = React.useState<UtmLinkDestinationOption | null>(() => {
    if (utm_link?.destination_option?.id) {
      return context.destination_options.find((o) => o.id === assertDefined(utm_link.destination_option).id) ?? null;
    }
    return null;
  });

  // Update form data when destination changes
  React.useEffect(() => {
    if (!destination) {
      setData("utm_link", { ...data.utm_link, target_resource_type: null, target_resource_id: null });
      return;
    }

    const destinationId = destination.id;
    if (["profile_page", "subscribe_page"].includes(destinationId)) {
      setData("utm_link", { ...data.utm_link, target_resource_type: destinationId, target_resource_id: null });
    } else {
      const parts = destinationId.split(/-(.*)/u);
      setData("utm_link", {
        ...data.utm_link,
        target_resource_type: parts[0] ?? null,
        target_resource_id: parts[1] ?? null,
      });
    }
  }, [destination]);

  // Update permalink in form when it changes
  React.useEffect(() => {
    setData("utm_link", { ...data.utm_link, permalink });
  }, [permalink]);

  const titleRef = React.useRef<HTMLInputElement>(null);

  const finalUrl = React.useMemo(() => {
    if (destination && data.utm_link.utm_source && data.utm_link.utm_medium && data.utm_link.utm_campaign) {
      const params = new URLSearchParams();
      params.set("utm_source", data.utm_link.utm_source);
      params.set("utm_medium", data.utm_link.utm_medium);
      params.set("utm_campaign", data.utm_link.utm_campaign);
      if (data.utm_link.utm_term) params.set("utm_term", data.utm_link.utm_term);
      if (data.utm_link.utm_content) params.set("utm_content", data.utm_link.utm_content);
      return [destination.url, params.toString()].filter(Boolean).join("?");
    }
    return null;
  }, [
    destination,
    data.utm_link.utm_source,
    data.utm_link.utm_medium,
    data.utm_link.utm_campaign,
    data.utm_link.utm_term,
    data.utm_link.utm_content,
  ]);

  const generateNewPermalink = asyncVoid(async () => {
    setIsLoadingNewPermalink(true);
    try {
      const { permalink: newPermalink } = await getUniquePermalink();
      setShortUrl((shortUrl) => ({ ...shortUrl, permalink: newPermalink }));
    } catch {
      showAlert("Sorry, something went wrong. Please try again.", "error");
    } finally {
      setIsLoadingNewPermalink(false);
    }
  });

  const validate = () => {
    form.clearErrors();

    if (data.utm_link.title.trim().length === 0) {
      form.setError("utm_link.title", "Must be present");
      titleRef.current?.focus();
      return false;
    }

    if (!destination) {
      form.setError("utm_link.target_resource_id", "Must be present");
      return false;
    }

    if (!data.utm_link.utm_source || data.utm_link.utm_source.trim().length === 0) {
      form.setError("utm_link.utm_source", "Must be present");
      return false;
    }

    if (!data.utm_link.utm_medium || data.utm_link.utm_medium.trim().length === 0) {
      form.setError("utm_link.utm_medium", "Must be present");
      return false;
    }

    if (!data.utm_link.utm_campaign || data.utm_link.utm_campaign.trim().length === 0) {
      form.setError("utm_link.utm_campaign", "Must be present");
      return false;
    }

    return true;
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!validate()) return;

    post(Routes.utm_links_dashboard_index_path(), {
      onError: (errors: Record<string, string | string[]>) => {
        const firstError = Object.values(errors)[0];
        const message = Array.isArray(firstError) ? firstError[0] : firstError;
        if (message) showAlert(message, "error");
      },
    });
  };

  return (
    <AnalyticsLayout
      selectedTab="utm_links"
      showTabs={false}
      title="Create link"
      actions={
        <>
          <NavigationButtonInertia href={Routes.utm_links_dashboard_index_path()} disabled={processing}>
            <Icon name="x-square" />
            Cancel
          </NavigationButtonInertia>
          <Button color="accent" onClick={handleSubmit} disabled={processing}>
            {processing ? "Saving..." : "Add link"}
          </Button>
        </>
      }
    >
      <form onSubmit={handleSubmit}>
        <section className="p-4! md:p-8!">
          <header>
            <p>Create UTM links to track where your traffic is coming from.</p>
            <p>Once set up, simply share the links to see which sources are driving more conversions and revenue.</p>
            <a href="/help/article/74-the-analytics-dashboard" target="_blank" rel="noreferrer">
              Learn more
            </a>
          </header>
          <fieldset className={cx({ danger: errors["utm_link.title"] })}>
            <legend>
              <label htmlFor={`title-${uid}`}>Title</label>
            </legend>
            <input
              id={`title-${uid}`}
              type="text"
              placeholder="Title"
              value={data.utm_link.title}
              ref={titleRef}
              onChange={(e) => {
                setData("utm_link", { ...data.utm_link, title: e.target.value });
                form.clearErrors("utm_link.title");
              }}
            />
            {errors["utm_link.title"] ? <small>{errors["utm_link.title"]}</small> : null}
          </fieldset>
          <fieldset
            className={cx({ danger: errors["utm_link.target_resource_id"] || errors["utm_link.target_resource_type"] })}
          >
            <legend>
              <label htmlFor={`destination-${uid}`}>Destination</label>
            </legend>
            <Select
              inputId={`destination-${uid}`}
              instanceId={`destination-${uid}`}
              placeholder="Select where you want to send your audience"
              options={context.destination_options}
              value={destination}
              isMulti={false}
              onChange={(option) => {
                setDestination(option ? (context.destination_options.find((o) => o.id === option.id) ?? null) : null);
                form.clearErrors("utm_link.target_resource_id");
              }}
            />
            {errors["utm_link.target_resource_id"] || errors["utm_link.target_resource_type"] ? (
              <small>{errors["utm_link.target_resource_id"] || errors["utm_link.target_resource_type"]}</small>
            ) : null}
          </fieldset>
          <fieldset className={cx({ danger: errors["utm_link.permalink"] })}>
            <legend>
              <label htmlFor={`${uid}-link-text`}>Link</label>
            </legend>
            <div style={{ display: "grid", gridTemplateColumns: "1fr auto", gap: "var(--spacer-2)" }}>
              <div className="input">
                <Pill className="-ml-2 shrink-0">{shortUrlPrefix}</Pill>
                <input type="text" id={`${uid}-link-text`} value={permalink} readOnly />
              </div>
              <div className="flex gap-2">
                <CopyToClipboard
                  copyTooltip="Copy short link"
                  text={`${shortUrlProtocol}//${shortUrlPrefix}${permalink}`}
                >
                  <Button type="button" aria-label="Copy short link">
                    <Icon name="link" />
                  </Button>
                </CopyToClipboard>
                <WithTooltip tip="Generate new short link">
                  <Button
                    onClick={generateNewPermalink}
                    disabled={isLoadingNewPermalink}
                    aria-label="Generate new short link"
                  >
                    <Icon name="outline-refresh" />
                  </Button>
                </WithTooltip>
              </div>
            </div>
            {errors["utm_link.permalink"] ? (
              <small>{errors["utm_link.permalink"]}</small>
            ) : (
              <small>This is your short UTM link to share</small>
            )}
          </fieldset>
          <div
            style={{
              display: "grid",
              gap: "var(--spacer-3)",
              gridTemplateColumns: "repeat(auto-fit, max(var(--dynamic-grid), 50% - var(--spacer-3) / 2))",
            }}
          >
            <fieldset className={cx({ danger: errors["utm_link.utm_source"] })}>
              <legend>
                <label htmlFor={`${uid}-source`}>Source</label>
              </legend>
              <UtmFieldSelect
                id={`${uid}-source`}
                placeholder="newsletter"
                baseOptionValues={context.utm_fields_values.sources}
                value={data.utm_link.utm_source}
                onChange={(value) => setData("utm_link", { ...data.utm_link, utm_source: value })}
                onClearError={() => form.clearErrors("utm_link.utm_source")}
              />
              {errors["utm_link.utm_source"] ? (
                <small>{errors["utm_link.utm_source"]}</small>
              ) : (
                <small>Where the traffic comes from e.g Twitter, Instagram</small>
              )}
            </fieldset>
            <fieldset className={cx({ danger: errors["utm_link.utm_medium"] })}>
              <legend>
                <label htmlFor={`${uid}-medium`}>Medium</label>
              </legend>
              <UtmFieldSelect
                id={`${uid}-medium`}
                placeholder="email"
                baseOptionValues={context.utm_fields_values.mediums}
                value={data.utm_link.utm_medium}
                onChange={(value) => setData("utm_link", { ...data.utm_link, utm_medium: value })}
                onClearError={() => form.clearErrors("utm_link.utm_medium")}
              />
              {errors["utm_link.utm_medium"] ? (
                <small>{errors["utm_link.utm_medium"]}</small>
              ) : (
                <small>Medium by which the traffic arrived e.g. email, ads, story</small>
              )}
            </fieldset>
          </div>
          <fieldset className={cx({ danger: errors["utm_link.utm_campaign"] })}>
            <legend>
              <label htmlFor={`${uid}-campaign`}>Campaign</label>
            </legend>
            <UtmFieldSelect
              id={`${uid}-campaign`}
              placeholder="new-course-launch"
              baseOptionValues={context.utm_fields_values.campaigns}
              value={data.utm_link.utm_campaign}
              onChange={(value) => setData("utm_link", { ...data.utm_link, utm_campaign: value })}
              onClearError={() => form.clearErrors("utm_link.utm_campaign")}
            />
            {errors["utm_link.utm_campaign"] ? (
              <small>{errors["utm_link.utm_campaign"]}</small>
            ) : (
              <small>Name of the campaign</small>
            )}
          </fieldset>
          <fieldset className={cx({ danger: errors["utm_link.utm_term"] })}>
            <legend>
              <label htmlFor={`${uid}-term`}>Term</label>
            </legend>
            <UtmFieldSelect
              id={`${uid}-term`}
              placeholder="photo-editing"
              baseOptionValues={context.utm_fields_values.terms}
              value={data.utm_link.utm_term}
              onChange={(value) => setData("utm_link", { ...data.utm_link, utm_term: value })}
            />
            {errors["utm_link.utm_term"] ? (
              <small>{errors["utm_link.utm_term"]}</small>
            ) : (
              <small>Keywords used in ads</small>
            )}
          </fieldset>
          <fieldset className={cx({ danger: errors["utm_link.utm_content"] })}>
            <legend>
              <label htmlFor={`${uid}-content`}>Content</label>
            </legend>
            <UtmFieldSelect
              id={`${uid}-content`}
              placeholder="video-ad"
              baseOptionValues={context.utm_fields_values.contents}
              value={data.utm_link.utm_content}
              onChange={(value) => setData("utm_link", { ...data.utm_link, utm_content: value })}
            />
            {errors["utm_link.utm_content"] ? (
              <small>{errors["utm_link.utm_content"]}</small>
            ) : (
              <small>Use to differentiate ads</small>
            )}
          </fieldset>
          {finalUrl ? (
            <fieldset>
              <legend>
                <label htmlFor={`${uid}-utm-url`}>Generated URL with UTM tags</label>
              </legend>
              <div className="input">
                <ResizableTextarea
                  id={`${uid}-utm-url`}
                  className="resize-none"
                  readOnly
                  value={finalUrl}
                  onChange={() => {}}
                />
                <CopyToClipboard copyTooltip="Copy UTM link" text={finalUrl}>
                  <Button type="button" aria-label="Copy UTM link">
                    <Icon name="link" />
                  </Button>
                </CopyToClipboard>
              </div>
            </fieldset>
          ) : null}
        </section>
      </form>
    </AnalyticsLayout>
  );
}

const UtmFieldSelect = ({
  id,
  placeholder,
  baseOptionValues,
  value,
  onChange,
  onClearError,
}: {
  id: string;
  placeholder: string;
  baseOptionValues: string[];
  value: string | null;
  onChange: (value: string | null) => void;
  onClearError?: () => void;
}) => {
  const [inputValue, setInputValue] = React.useState<string | null>(null);
  const options = [...new Set([value, inputValue, ...baseOptionValues])]
    .flatMap((val) => (val !== null && val !== "" ? [{ id: val, label: val }] : []))
    .sort((a, b) => a.label.localeCompare(b.label));

  return (
    <Select
      inputId={id}
      instanceId={id}
      placeholder={placeholder}
      isMulti={false}
      isClearable
      escapeClearsValue
      options={options}
      value={value ? (options.find((o) => o.id === value) ?? null) : null}
      onChange={(option) => {
        onChange(option ? option.id : null);
        onClearError?.();
      }}
      inputValue={inputValue ?? ""}
      onInputChange={(value) =>
        setInputValue(
          value
            .toLocaleLowerCase()
            .replace(/[^a-z0-9-_]/gu, "-")
            .slice(0, MAX_UTM_PARAM_LENGTH),
        )
      }
      noOptionsMessage={() => "Enter something..."}
    />
  );
};

const ResizableTextarea = (props: React.ComponentProps<"textarea">) => {
  const ref = React.useRef<HTMLTextAreaElement | null>(null);
  React.useEffect(() => {
    if (!ref.current) return;
    ref.current.style.height = "inherit";
    ref.current.style.height = `${ref.current.scrollHeight}px`;
  }, [props.value]);

  return <textarea ref={ref} {...props} />;
};
