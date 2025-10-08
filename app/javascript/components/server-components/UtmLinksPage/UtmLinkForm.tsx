import cx from "classnames";
import * as React from "react";
import { Link, useLoaderData, useNavigate } from "react-router-dom";
import { cast, is } from "ts-safe-cast";

import {
  createUtmLink,
  getUniquePermalink,
  UtmLinkFormContext,
  UtmLinkDestinationOption,
  UtmLink,
  updateUtmLink,
} from "$app/data/utm_links";
import { assertDefined } from "$app/utils/assert";
import { asyncVoid } from "$app/utils/promise";
import { ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { UtmLinkLayout } from "$app/components/server-components/UtmLinksPage";
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

export const UtmLinkForm = () => {
  const { context, utm_link } = cast<{ context: UtmLinkFormContext; utm_link: UtmLink | null }>(useLoaderData());
  const isEditing = utm_link?.id !== undefined;
  const isDuplicating = utm_link !== null && utm_link.id === undefined;
  const navigate = useNavigate();
  const uid = React.useId();
  const [title, setTitle] = React.useState(isDuplicating ? duplicatedTitle(utm_link.title) : (utm_link?.title ?? ""));
  const [destination, setDestination] = React.useState<UtmLinkDestinationOption | null>(
    utm_link?.destination_option?.id
      ? (context.destination_options.find((o) => o.id === assertDefined(utm_link.destination_option).id) ?? null)
      : null,
  );
  const [{ shortUrlProtocol, shortUrlPrefix, permalink }, setShortUrl] = React.useState(() => {
    const { protocol: shortUrlProtocol, host, pathname } = new URL(utm_link?.short_url ?? context.short_url);
    const permalink = pathname.split("/").pop() ?? "";
    const shortUrlPrefix = host + pathname.slice(0, -permalink.length);
    return {
      shortUrlProtocol,
      shortUrlPrefix,
      permalink,
    };
  });
  const [isLoadingNewPermalink, setIsLoadingNewPermalink] = React.useState(false);
  const [utmSource, setUtmSource] = React.useState<string | null>(utm_link?.source ?? null);
  const [utmMedium, setUtmMedium] = React.useState<string | null>(utm_link?.medium ?? null);
  const [utmCampaign, setUtmCampaign] = React.useState<string | null>(utm_link?.campaign ?? null);
  const [utmTerm, setUtmTerm] = React.useState<string | null>(utm_link?.term ?? null);
  const [utmContent, setUtmContent] = React.useState<string | null>(utm_link?.content ?? null);
  const [errorInfo, setErrorInfo] = React.useState<ErrorInfo | null>(null);
  const [isSaving, setIsSaving] = React.useState(false);

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

  React.useEffect(
    () => setErrorInfo(null),
    [title, destination, permalink, utmSource, utmMedium, utmCampaign, utmTerm, utmContent],
  );

  const finalUrl = React.useMemo(() => {
    if (destination && utmSource && utmMedium && utmCampaign) {
      const params = new URLSearchParams();
      params.set("utm_source", utmSource);
      params.set("utm_medium", utmMedium);
      params.set("utm_campaign", utmCampaign);
      if (utmTerm) params.set("utm_term", utmTerm);
      if (utmContent) params.set("utm_content", utmContent);

      return [destination.url, params.toString()].filter(Boolean).join("?");
    }

    return null;
  }, [destination, utmSource, utmMedium, utmCampaign, utmTerm, utmContent]);

  const generateNewPermalink = asyncVoid(async () => {
    setIsLoadingNewPermalink(true);
    try {
      const { permalink } = await getUniquePermalink();
      setShortUrl((shortUrl) => ({ ...shortUrl, permalink }));
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
    if (title.trim().length === 0) {
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

    if (!utmSource || utmSource.trim().length === 0) {
      setErrorInfo({ attrName: "utm_source", message: "Must be present" });
      scrollToAttribute("utm_source");
      return false;
    }

    if (!utmMedium || utmMedium.trim().length === 0) {
      setErrorInfo({ attrName: "utm_medium", message: "Must be present" });
      scrollToAttribute("utm_medium");
      return false;
    }

    if (!utmCampaign || utmCampaign.trim().length === 0) {
      setErrorInfo({ attrName: "utm_campaign", message: "Must be present" });
      scrollToAttribute("utm_campaign");
      return false;
    }

    setErrorInfo(null);
    return true;
  };

  const submit = asyncVoid(async () => {
    const isValid = validate();
    if (!isValid) return;

    const destinationId = assertDefined(destination).id;
    let targetResourceId = null;
    let targetResourceType = null;
    if (["profile_page", "subscribe_page"].includes(destinationId)) {
      targetResourceType = destinationId;
    } else {
      const parts = destinationId.split(/-(.*)/u); // Split by first hyphen
      targetResourceType = parts[0];
      targetResourceId = parts[1] ?? null;
    }

    setIsSaving(true);

    const requestPayload = {
      title,
      target_resource_type: targetResourceType,
      target_resource_id: targetResourceId,
      permalink,
      utm_source: assertDefined(utmSource),
      utm_medium: assertDefined(utmMedium),
      utm_campaign: assertDefined(utmCampaign),
      utm_term: utmTerm,
      utm_content: utmContent,
    };

    try {
      if (isEditing) {
        await updateUtmLink(assertDefined(utm_link.id), requestPayload);
      } else {
        await createUtmLink(requestPayload);
      }

      showAlert(isEditing ? "Link updated!" : "Link created!", "success");
      navigate("/dashboard/utm_links");
    } catch (error) {
      const genericMessage = "Sorry, something went wrong. Please try again.";
      if (error instanceof ResponseError) {
        try {
          const { error: message, attr_name } = cast<{ error: string; attr_name: string | null }>(
            JSON.parse(error.message),
          );
          if (attr_name !== null && is<FieldAttrName>(attr_name)) {
            setErrorInfo({ attrName: attr_name, message });
            scrollToAttribute(attr_name);
          } else {
            showAlert(message, "error");
          }
        } catch {
          showAlert(genericMessage, "error");
        }
      } else {
        showAlert(genericMessage, "error");
      }
    } finally {
      setIsSaving(false);
    }
  });

  return (
    <UtmLinkLayout
      title={isEditing ? "Edit link" : "Create link"}
      actions={
        <>
          <Link to="/dashboard/utm_links" className="button">
            <Icon name="x-square" />
            Cancel
          </Link>
          <Button color="accent" onClick={submit} disabled={isSaving}>
            {isSaving ? "Saving..." : isEditing ? "Save changes" : "Add link"}
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
              value={title}
              ref={titleRef}
              onChange={(e) => setTitle(e.target.value)}
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
              onChange={(option) =>
                setDestination(option ? (context.destination_options.find((o) => o.id === option.id) ?? null) : null)
              }
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
                <div className="pill">{shortUrlPrefix}</div>
                <input
                  type="text"
                  id={`${uid}-link-text`}
                  value={permalink}
                  readOnly
                  disabled={isEditing}
                  ref={permalinkRef}
                />
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
                value={utmSource}
                onChange={setUtmSource}
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
                value={utmMedium}
                onChange={setUtmMedium}
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
              value={utmCampaign}
              onChange={setUtmCampaign}
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
              value={utmTerm}
              onChange={setUtmTerm}
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
              value={utmContent}
              onChange={setUtmContent}
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
    </UtmLinkLayout>
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
      // Lowercase the value, replace non-alphanumeric characters with dashes, and restrict to 64 characters
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
