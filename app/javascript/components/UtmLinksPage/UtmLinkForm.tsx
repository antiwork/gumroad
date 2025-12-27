import { Link, useForm } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";
import { is } from "ts-safe-cast";

import { getUniquePermalink } from "$app/data/utm_links";
import type { UtmLinkFormContext, UtmLink, SavedUtmLink } from "$app/types/utm_link";
import { assertDefined } from "$app/utils/assert";
import { asyncVoid } from "$app/utils/promise";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { Pill } from "$app/components/ui/Pill";
import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { WithTooltip } from "$app/components/WithTooltip";

const MAX_UTM_PARAM_LENGTH = 200;

type FieldAttrName =
  | "title"
  | "target_resource_id"
  | "target_resource_type"
  | "permalink"
  | "utm_source"
  | "utm_medium"
  | "utm_campaign"
  | "utm_term"
  | "utm_content";

type ErrorInfo = { attrName: FieldAttrName; message: string };

const duplicatedTitle = (title?: string) => (title ? `${title} (copy)` : "");

type UtmLinkFormProps = {
  context: UtmLinkFormContext;
  utm_link: UtmLink | SavedUtmLink | null;
};

const getInitialDestinationId = (utmLink: UtmLink | SavedUtmLink | null): string | null =>
  utmLink?.destination_option?.id ?? null;

const parseDestinationId = (destinationId: string | null) => {
  if (!destinationId) return { targetResourceType: null, targetResourceId: null };

  if (["profile_page", "subscribe_page"].includes(destinationId)) {
    return { targetResourceType: destinationId, targetResourceId: null };
  }

  const parts = destinationId.split(/-(.*)/u);
  return { targetResourceType: parts[0], targetResourceId: parts[1] ?? null };
};

export const UtmLinkForm = ({ context, utm_link }: UtmLinkFormProps) => {
  const isEditing = utm_link?.id !== undefined;
  const isDuplicating = utm_link !== null && utm_link.id === undefined;
  const uid = React.useId();

  const initialShortUrl = React.useMemo(() => {
    const { protocol: shortUrlProtocol, host, pathname } = new URL(utm_link?.short_url ?? context.short_url);
    const permalinkValue = pathname.split("/").pop() ?? "";
    const shortUrlPrefixValue = host + pathname.slice(0, -permalinkValue.length);
    return {
      shortUrlProtocol,
      shortUrlPrefix: shortUrlPrefixValue,
      permalink: permalinkValue,
    };
  }, []);

  const form = useForm({
    title: isDuplicating ? duplicatedTitle(utm_link.title) : (utm_link?.title ?? ""),
    destination_id: getInitialDestinationId(utm_link),
    permalink: initialShortUrl.permalink,
    utm_source: utm_link?.source ?? "",
    utm_medium: utm_link?.medium ?? "",
    utm_campaign: utm_link?.campaign ?? "",
    utm_term: utm_link?.term ?? "",
    utm_content: utm_link?.content ?? "",
  });

  const { shortUrlProtocol, shortUrlPrefix } = initialShortUrl;
  const [isLoadingNewPermalink, setIsLoadingNewPermalink] = React.useState(false);
  const [errorInfo, setErrorInfo] = React.useState<ErrorInfo | null>(null);

  const destination = form.data.destination_id
    ? (context.destination_options.find((o) => o.id === form.data.destination_id) ?? null)
    : null;

  const titleRef = React.useRef<HTMLInputElement>(null);
  const destinationRef = React.useRef<HTMLFieldSetElement>(null);
  const permalinkRef = React.useRef<HTMLInputElement>(null);
  const utmSourceRef = React.useRef<HTMLFieldSetElement>(null);
  const utmMediumRef = React.useRef<HTMLFieldSetElement>(null);
  const utmCampaignRef = React.useRef<HTMLFieldSetElement>(null);
  const utmTermRef = React.useRef<HTMLFieldSetElement>(null);
  const utmContentRef = React.useRef<HTMLFieldSetElement>(null);

  const attributeRefs = React.useMemo(
    () => ({
      title: titleRef,
      target_resource_id: destinationRef,
      target_resource_type: destinationRef,
      permalink: permalinkRef,
      utm_source: utmSourceRef,
      utm_medium: utmMediumRef,
      utm_campaign: utmCampaignRef,
      utm_term: utmTermRef,
      utm_content: utmContentRef,
    }),
    [],
  );

  React.useEffect(() => setErrorInfo(null), [form.data]);

  const finalUrl = React.useMemo(() => {
    if (destination && form.data.utm_source && form.data.utm_medium && form.data.utm_campaign) {
      const params = new URLSearchParams();
      params.set("utm_source", form.data.utm_source);
      params.set("utm_medium", form.data.utm_medium);
      params.set("utm_campaign", form.data.utm_campaign);
      if (form.data.utm_term) params.set("utm_term", form.data.utm_term);
      if (form.data.utm_content) params.set("utm_content", form.data.utm_content);

      return [destination.url, params.toString()].filter(Boolean).join("?");
    }

    return null;
  }, [
    destination,
    form.data.utm_source,
    form.data.utm_medium,
    form.data.utm_campaign,
    form.data.utm_term,
    form.data.utm_content,
  ]);

  const generateNewPermalink = asyncVoid(async () => {
    setIsLoadingNewPermalink(true);
    try {
      const { permalink: newPermalink } = await getUniquePermalink();
      form.setData("permalink", newPermalink);
    } catch {
      showAlert("Sorry, something went wrong. Please try again.", "error");
    } finally {
      setIsLoadingNewPermalink(false);
    }
  });

  const scrollToAttribute = (attrName: FieldAttrName) => {
    attributeRefs[attrName].current?.scrollIntoView({ behavior: "smooth", block: "center" });
  };

  const validate = () => {
    if (form.data.title.trim().length === 0) {
      setErrorInfo({ attrName: "title", message: "Must be present" });
      titleRef.current?.focus();
      scrollToAttribute("title");
      return false;
    }

    if (!destination) {
      setErrorInfo({ attrName: "target_resource_id", message: "Must be present" });
      scrollToAttribute("target_resource_id");
      return false;
    }

    if (!form.data.utm_source || form.data.utm_source.trim().length === 0) {
      setErrorInfo({ attrName: "utm_source", message: "Must be present" });
      scrollToAttribute("utm_source");
      return false;
    }

    if (!form.data.utm_medium || form.data.utm_medium.trim().length === 0) {
      setErrorInfo({ attrName: "utm_medium", message: "Must be present" });
      scrollToAttribute("utm_medium");
      return false;
    }

    if (!form.data.utm_campaign || form.data.utm_campaign.trim().length === 0) {
      setErrorInfo({ attrName: "utm_campaign", message: "Must be present" });
      scrollToAttribute("utm_campaign");
      return false;
    }

    setErrorInfo(null);
    return true;
  };

  const submit = () => {
    const isValid = validate();
    if (!isValid) return;

    const { targetResourceType, targetResourceId } = parseDestinationId(form.data.destination_id);

    const requestPayload = {
      utm_link: {
        title: form.data.title,
        target_resource_type: targetResourceType,
        target_resource_id: targetResourceId,
        permalink: form.data.permalink,
        utm_source: form.data.utm_source,
        utm_medium: form.data.utm_medium,
        utm_campaign: form.data.utm_campaign,
        utm_term: form.data.utm_term || null,
        utm_content: form.data.utm_content || null,
      },
    };

    form.transform(() => requestPayload);

    const options = {
      onError: (errors: Record<string, string>) => {
        const firstErrorKey = Object.keys(errors)[0];
        if (firstErrorKey && is<FieldAttrName>(firstErrorKey)) {
          setErrorInfo({ attrName: firstErrorKey, message: errors[firstErrorKey] ?? "Invalid value" });
          scrollToAttribute(firstErrorKey);
        } else {
          showAlert("Sorry, something went wrong. Please try again.", "error");
        }
      },
    };

    if (isEditing) {
      form.patch(`${Routes.utm_links_dashboard_path()}/${assertDefined(utm_link.id)}`, options);
    } else {
      form.post(Routes.utm_links_dashboard_path(), options);
    }
  };

  return (
    <AnalyticsLayout
      selectedTab="utm_links"
      actions={
        <>
          <Link href={Routes.utm_links_dashboard_path()} className="button">
            <Icon name="x-square" />
            Cancel
          </Link>
          <Button color="accent" onClick={submit} disabled={form.processing}>
            {form.processing ? "Saving..." : isEditing ? "Save changes" : "Add link"}
          </Button>
        </>
      }
    >
      <form>
        <section className="p-4! md:p-8!">
          <header>
            <p>Create UTM links to track where your traffic is coming from. </p>
            <p>Once set up, simply share the links to see which sources are driving more conversions and revenue.</p>
            <a href="/help/article/74-the-analytics-dashboard" target="_blank" rel="noreferrer">
              Learn more
            </a>
          </header>
          <fieldset className={cx({ danger: errorInfo?.attrName === "title" })}>
            <legend>
              <label htmlFor={`title-${uid}`}>Title</label>
            </legend>
            <input
              id={`title-${uid}`}
              type="text"
              placeholder="Title"
              value={form.data.title}
              ref={titleRef}
              onChange={(e) => form.setData("title", e.target.value)}
            />
            {errorInfo?.attrName === "title" ? <small>{errorInfo.message}</small> : null}
          </fieldset>
          <fieldset
            className={cx({
              danger: errorInfo?.attrName === "target_resource_id" || errorInfo?.attrName === "target_resource_type",
            })}
            ref={destinationRef}
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
              isDisabled={isEditing}
              onChange={(option) => form.setData("destination_id", option ? option.id : null)}
            />
            {errorInfo?.attrName === "target_resource_id" || errorInfo?.attrName === "target_resource_type" ? (
              <small>{errorInfo.message}</small>
            ) : null}
          </fieldset>
          <fieldset className={cx({ danger: errorInfo?.attrName === "permalink" })}>
            <legend>
              <label htmlFor={`${uid}-link-text`}>Link</label>
            </legend>
            <div style={{ display: "grid", gridTemplateColumns: "1fr auto", gap: "var(--spacer-2)" }}>
              <div className={cx("input", { disabled: isEditing })}>
                <Pill className="-ml-2 shrink-0">{shortUrlPrefix}</Pill>
                <input
                  type="text"
                  id={`${uid}-link-text`}
                  value={form.data.permalink}
                  readOnly
                  disabled={isEditing}
                  ref={permalinkRef}
                />
              </div>
              <div className="flex gap-2">
                <CopyToClipboard
                  copyTooltip="Copy short link"
                  text={`${shortUrlProtocol}//${shortUrlPrefix}${form.data.permalink}`}
                >
                  <Button type="button" aria-label="Copy short link">
                    <Icon name="link" />
                  </Button>
                </CopyToClipboard>
                {isEditing ? null : (
                  <WithTooltip tip="Generate new short link">
                    <Button
                      onClick={generateNewPermalink}
                      disabled={isLoadingNewPermalink}
                      aria-label="Generate new short link"
                    >
                      <Icon name="outline-refresh" />
                    </Button>
                  </WithTooltip>
                )}
              </div>
            </div>
            {errorInfo?.attrName === "permalink" ? (
              <small>{errorInfo.message}</small>
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
            <fieldset className={cx({ danger: errorInfo?.attrName === "utm_source" })} ref={utmSourceRef}>
              <legend>
                <label htmlFor={`${uid}-source`}>Source</label>
              </legend>
              <UtmFieldSelect
                id={`${uid}-source`}
                placeholder="newsletter"
                baseOptionValues={context.utm_fields_values.sources}
                value={form.data.utm_source || null}
                onChange={(value) => form.setData("utm_source", value ?? "")}
              />
              {errorInfo?.attrName === "utm_source" ? (
                <small>{errorInfo.message}</small>
              ) : (
                <small>Where the traffic comes from e.g Twitter, Instagram</small>
              )}
            </fieldset>
            <fieldset className={cx({ danger: errorInfo?.attrName === "utm_medium" })} ref={utmMediumRef}>
              <legend>
                <label htmlFor={`${uid}-medium`}>Medium</label>
              </legend>
              <UtmFieldSelect
                id={`${uid}-medium`}
                placeholder="email"
                baseOptionValues={context.utm_fields_values.mediums}
                value={form.data.utm_medium || null}
                onChange={(value) => form.setData("utm_medium", value ?? "")}
              />
              {errorInfo?.attrName === "utm_medium" ? (
                <small>{errorInfo.message}</small>
              ) : (
                <small>Medium by which the traffic arrived e.g. email, ads, story</small>
              )}
            </fieldset>
          </div>
          <fieldset className={cx({ danger: errorInfo?.attrName === "utm_campaign" })} ref={utmCampaignRef}>
            <legend>
              <label htmlFor={`${uid}-campaign`}>Campaign</label>
            </legend>
            <UtmFieldSelect
              id={`${uid}-campaign`}
              placeholder="new-course-launch"
              baseOptionValues={context.utm_fields_values.campaigns}
              value={form.data.utm_campaign || null}
              onChange={(value) => form.setData("utm_campaign", value ?? "")}
            />
            {errorInfo?.attrName === "utm_campaign" ? (
              <small>{errorInfo.message}</small>
            ) : (
              <small>Name of the campaign</small>
            )}
          </fieldset>
          <fieldset className={cx({ danger: errorInfo?.attrName === "utm_term" })} ref={utmTermRef}>
            <legend>
              <label htmlFor={`${uid}-term`}>Term</label>
            </legend>
            <UtmFieldSelect
              id={`${uid}-term`}
              placeholder="photo-editing"
              baseOptionValues={context.utm_fields_values.terms}
              value={form.data.utm_term || null}
              onChange={(value) => form.setData("utm_term", value ?? "")}
            />
            {errorInfo?.attrName === "utm_term" ? (
              <small>{errorInfo.message}</small>
            ) : (
              <small>Keywords used in ads</small>
            )}
          </fieldset>
          <fieldset className={cx({ danger: errorInfo?.attrName === "utm_content" })} ref={utmContentRef}>
            <legend>
              <label htmlFor={`${uid}-content`}>Content</label>
            </legend>
            <UtmFieldSelect
              id={`${uid}-content`}
              placeholder="video-ad"
              baseOptionValues={context.utm_fields_values.contents}
              value={form.data.utm_content || null}
              onChange={(value) => form.setData("utm_content", value ?? "")}
            />
            {errorInfo?.attrName === "utm_content" ? (
              <small>{errorInfo.message}</small>
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
};

const UtmFieldSelect = ({
  id,
  placeholder,
  baseOptionValues,
  value,
  onChange,
}: {
  id: string;
  placeholder: string;
  baseOptionValues: string[];
  value: string | null;
  onChange: (value: string | null) => void;
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
      onChange={(option) => onChange(option ? option.id : null)}
      inputValue={inputValue ?? ""}
      onInputChange={(inputVal) =>
        setInputValue(
          inputVal
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
