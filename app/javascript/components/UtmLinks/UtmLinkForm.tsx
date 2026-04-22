import { Link, RefreshCcw, XSquare } from "@boxicons/react";
import { router, useForm } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { UtmLink, UtmLinkDestinationOption, SavedUtmLink } from "$app/types/utm_link";
import { assertDefined } from "$app/utils/assert";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { Select } from "$app/components/Select";
import { showAlert } from "$app/components/server-components/Alert";
import { Fieldset, FieldsetDescription, FieldsetTitle } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Input } from "$app/components/ui/Input";
import { InputGroup } from "$app/components/ui/InputGroup";
import { Label } from "$app/components/ui/Label";
import { Pill } from "$app/components/ui/Pill";
import { Textarea } from "$app/components/ui/Textarea";
import { WithTooltip } from "$app/components/WithTooltip";

type UtmLinkFormData = {
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
};

type UtmLinkFormContext = {
  destination_options: UtmLinkDestinationOption[];
  short_url: string;
  utm_fields_values: {
    campaigns: string[];
    mediums: string[];
    sources: string[];
    terms: string[];
    contents: string[];
  };
};

type UtmLinkFormAdditionalMetadata = {
  new_permalink: string;
};

export type UtmLinkFormProps = {
  context: UtmLinkFormContext;
  utm_link: UtmLink | null;
  additional_metadata?: UtmLinkFormAdditionalMetadata;
};

export type UtmLinkEditProps = {
  context: UtmLinkFormContext;
  utm_link: SavedUtmLink;
};

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

const computeTargetResource = (dest: UtmLinkDestinationOption | null) => {
  if (!dest) return { target_resource_type: null, target_resource_id: null };

  if (["profile_page", "subscribe_page"].includes(dest.id)) {
    return { target_resource_type: dest.id, target_resource_id: null };
  }

  const parts = dest.id.split(/-(.*)/u);
  return {
    target_resource_type: parts[0] || null,
    target_resource_id: parts[1] ?? null,
  };
};

const duplicatedTitle = (title?: string) => (title ? `${title} (copy)` : "");

export const UtmLinkForm = (pageProps: UtmLinkFormProps | UtmLinkEditProps) => {
  const { context, utm_link } = pageProps;

  const isEditing = utm_link?.id !== undefined;
  const isDuplicating = !isEditing && utm_link !== null;

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

  const initialDestination = utm_link?.destination_option?.id
    ? (context.destination_options.find((o) => o.id === assertDefined(utm_link.destination_option).id) ?? null)
    : null;
  const initialTargetResource = computeTargetResource(initialDestination);

  const formKey = isEditing ? `EditUtmLink:${utm_link.id}` : "CreateUtmLink";
  const form = useForm<UtmLinkFormData>(formKey, {
    utm_link: {
      title: isDuplicating ? duplicatedTitle(utm_link.title) : (utm_link?.title ?? ""),
      target_resource_type: initialTargetResource.target_resource_type,
      target_resource_id: initialTargetResource.target_resource_id,
      permalink,
      utm_source: utm_link?.source ?? null,
      utm_medium: utm_link?.medium ?? null,
      utm_campaign: utm_link?.campaign ?? null,
      utm_term: utm_link?.term ?? null,
      utm_content: utm_link?.content ?? null,
    },
  });
  const { data, setData, post, patch, processing, errors } = form;

  const [destination, setDestination] = React.useState<UtmLinkDestinationOption | null>(initialDestination);

  const titleRef = React.useRef<HTMLInputElement>(null);

  React.useEffect(() => {
    if (Object.keys(errors).length > 0) form.clearErrors();
  }, [data]);

  React.useLayoutEffect(() => {
    if (Object.keys(errors).length > 0) {
      document.querySelector("fieldset.danger")?.scrollIntoView({
        behavior: "smooth",
        block: "center",
      });
    }
  }, [errors]);

  const getFieldError = (attrName: FieldAttrName): string | undefined => {
    const error = errors[`utm_link.${attrName}`];
    if (error) return error;

    if (attrName === "target_resource_id" || attrName === "target_resource_type") {
      return errors["utm_link.target_resource_id"] || errors["utm_link.target_resource_type"] || undefined;
    }

    return undefined;
  };

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

  const generateNewPermalink = () => {
    setIsLoadingNewPermalink(true);
    router.reload({
      only: ["additional_metadata"],
      onSuccess: (page) => {
        const additionalMetadata = cast<UtmLinkFormAdditionalMetadata | undefined>(page.props.additional_metadata);
        const newPermalink = additionalMetadata?.new_permalink;
        if (newPermalink) {
          setShortUrl((shortUrl) => ({ ...shortUrl, permalink: newPermalink }));
          setData("utm_link.permalink", newPermalink);
        }
      },
      onError: () => {
        showAlert("Sorry, something went wrong. Please try again.", "error");
      },
      onFinish: () => {
        setIsLoadingNewPermalink(false);
      },
    });
  };

  const validate = () => {
    form.clearErrors();

    if (data.utm_link.title.trim().length === 0) {
      form.setError("utm_link.title", "Must be present");
      titleRef.current?.focus();
      return false;
    }

    if (!isEditing && !destination) {
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

    const onError = (submitErrors: Record<string, string | string[]>) => {
      const firstError = Object.values(submitErrors)[0];
      const message = Array.isArray(firstError) ? firstError[0] : firstError;
      if (message) showAlert(message, "error");
    };

    if (isEditing && utm_link.id) {
      patch(Routes.dashboard_utm_link_path(utm_link.id), { onError });
    } else {
      const url = new URL(window.location.href);
      const copyFrom = url.searchParams.get("copy_from");
      const postUrl = copyFrom
        ? Routes.dashboard_utm_links_path({ copy_from: copyFrom })
        : Routes.dashboard_utm_links_path();

      post(postUrl, { onError });
    }
  };

  return (
    <AnalyticsLayout
      selectedTab="utm_links"
      showTabs={false}
      title={isEditing ? "Edit link" : "Create link"}
      actions={
        <>
          <NavigationButtonInertia href={Routes.dashboard_utm_links_path()} disabled={processing}>
            <XSquare className="size-5" />
            Cancel
          </NavigationButtonInertia>
          <Button color="accent" onClick={handleSubmit} disabled={processing}>
            {processing ? "Saving..." : isEditing ? "Save changes" : "Add link"}
          </Button>
        </>
      }
    >
      <form onSubmit={handleSubmit}>
        <FormSection
          header={
            <>
              <p>Create UTM links to track where your traffic is coming from.</p>
              <p>Once set up, simply share the links to see which sources are driving more conversions and revenue.</p>
              <a href="/help/article/74-the-analytics-dashboard" target="_blank" rel="noreferrer">
                Learn more
              </a>
            </>
          }
        >
          <Fieldset state={getFieldError("title") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`title-${uid}`}>Title</Label>
            </FieldsetTitle>
            <Input
              id={`title-${uid}`}
              type="text"
              value={data.utm_link.title}
              ref={titleRef}
              onChange={(e) => setData("utm_link.title", e.target.value)}
            />
            {getFieldError("title") ? <FieldsetDescription>{getFieldError("title")}</FieldsetDescription> : null}
          </Fieldset>
          <Fieldset
            state={getFieldError("target_resource_id") || getFieldError("target_resource_type") ? "danger" : undefined}
          >
            <FieldsetTitle>
              <Label htmlFor={`destination-${uid}`}>Destination</Label>
            </FieldsetTitle>
            <Select
              inputId={`destination-${uid}`}
              instanceId={`destination-${uid}`}
              options={context.destination_options}
              value={destination}
              isMulti={false}
              isDisabled={isEditing}
              onChange={(option) => {
                const newDest = option ? (context.destination_options.find((o) => o.id === option.id) ?? null) : null;
                setDestination(newDest);
                const { target_resource_type, target_resource_id } = computeTargetResource(newDest);
                setData("utm_link", { ...data.utm_link, target_resource_type, target_resource_id });
              }}
            />
            {getFieldError("target_resource_id") || getFieldError("target_resource_type") ? (
              <FieldsetDescription>
                {getFieldError("target_resource_id") || getFieldError("target_resource_type")}
              </FieldsetDescription>
            ) : null}
          </Fieldset>
          <Fieldset state={getFieldError("permalink") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-link-text`}>Link</Label>
            </FieldsetTitle>
            <div className="grid grid-cols-[1fr_auto] gap-2">
              <InputGroup disabled={isEditing}>
                <Pill className="-ml-2 shrink-0">{shortUrlPrefix}</Pill>
                <Input
                  type="text"
                  id={`${uid}-link-text`}
                  value={isEditing ? permalink : data.utm_link.permalink}
                  readOnly
                  disabled={isEditing}
                />
              </InputGroup>
              <div className="flex gap-2">
                <CopyToClipboard
                  copyTooltip="Copy short link"
                  text={`${shortUrlProtocol}//${shortUrlPrefix}${isEditing ? permalink : data.utm_link.permalink}`}
                >
                  <Button type="button" size="icon" aria-label="Copy short link">
                    <Link className="size-5" />
                  </Button>
                </CopyToClipboard>
                {!isEditing && (
                  <WithTooltip tip="Generate new short link">
                    <Button
                      size="icon"
                      onClick={generateNewPermalink}
                      disabled={isLoadingNewPermalink}
                      aria-label="Generate new short link"
                    >
                      <RefreshCcw className="size-5" />
                    </Button>
                  </WithTooltip>
                )}
              </div>
            </div>
            {getFieldError("permalink") ? (
              <FieldsetDescription>{getFieldError("permalink")}</FieldsetDescription>
            ) : (
              <FieldsetDescription>This is your short UTM link to share</FieldsetDescription>
            )}
          </Fieldset>
          <div
            style={{
              display: "grid",
              gap: "var(--spacer-3)",
              gridTemplateColumns: "repeat(auto-fit, max(var(--dynamic-grid), 50% - var(--spacer-3) / 2))",
            }}
          >
            <Fieldset state={getFieldError("utm_source") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-source`}>Source</Label>
              </FieldsetTitle>
              <UtmFieldSelect
                id={`${uid}-source`}
                baseOptionValues={context.utm_fields_values.sources}
                value={data.utm_link.utm_source}
                onChange={(value) => setData("utm_link.utm_source", value)}
              />
              {getFieldError("utm_source") ? (
                <FieldsetDescription>{getFieldError("utm_source")}</FieldsetDescription>
              ) : (
                <FieldsetDescription>Where the traffic comes from e.g Twitter, Instagram</FieldsetDescription>
              )}
            </Fieldset>
            <Fieldset state={getFieldError("utm_medium") ? "danger" : undefined}>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-medium`}>Medium</Label>
              </FieldsetTitle>
              <UtmFieldSelect
                id={`${uid}-medium`}
                baseOptionValues={context.utm_fields_values.mediums}
                value={data.utm_link.utm_medium}
                onChange={(value) => setData("utm_link.utm_medium", value)}
              />
              {getFieldError("utm_medium") ? (
                <FieldsetDescription>{getFieldError("utm_medium")}</FieldsetDescription>
              ) : (
                <FieldsetDescription>Medium by which the traffic arrived e.g. email, ads, story</FieldsetDescription>
              )}
            </Fieldset>
          </div>
          <Fieldset state={getFieldError("utm_campaign") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-campaign`}>Campaign</Label>
            </FieldsetTitle>
            <UtmFieldSelect
              id={`${uid}-campaign`}
              baseOptionValues={context.utm_fields_values.campaigns}
              value={data.utm_link.utm_campaign}
              onChange={(value) => setData("utm_link.utm_campaign", value)}
            />
            {getFieldError("utm_campaign") ? (
              <FieldsetDescription>{getFieldError("utm_campaign")}</FieldsetDescription>
            ) : (
              <FieldsetDescription>Name of the campaign</FieldsetDescription>
            )}
          </Fieldset>
          <Fieldset state={getFieldError("utm_term") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-term`}>Term</Label>
            </FieldsetTitle>
            <UtmFieldSelect
              id={`${uid}-term`}
              baseOptionValues={context.utm_fields_values.terms}
              value={data.utm_link.utm_term}
              onChange={(value) => setData("utm_link.utm_term", value)}
            />
            {getFieldError("utm_term") ? (
              <FieldsetDescription>{getFieldError("utm_term")}</FieldsetDescription>
            ) : (
              <FieldsetDescription>Keywords used in ads</FieldsetDescription>
            )}
          </Fieldset>
          <Fieldset state={getFieldError("utm_content") ? "danger" : undefined}>
            <FieldsetTitle>
              <Label htmlFor={`${uid}-content`}>Content</Label>
            </FieldsetTitle>
            <UtmFieldSelect
              id={`${uid}-content`}
              baseOptionValues={context.utm_fields_values.contents}
              value={data.utm_link.utm_content}
              onChange={(value) => setData("utm_link.utm_content", value)}
            />
            {getFieldError("utm_content") ? (
              <FieldsetDescription>{getFieldError("utm_content")}</FieldsetDescription>
            ) : (
              <FieldsetDescription>Use to differentiate ads</FieldsetDescription>
            )}
          </Fieldset>
          {finalUrl ? (
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`${uid}-utm-url`}>Generated URL with UTM tags</Label>
              </FieldsetTitle>
              <InputGroup>
                <ResizableTextarea
                  id={`${uid}-utm-url`}
                  className="resize-none"
                  readOnly
                  value={finalUrl}
                  onChange={() => {}}
                />
                <CopyToClipboard copyTooltip="Copy UTM link" text={finalUrl}>
                  <Button type="button" size="icon" aria-label="Copy UTM link">
                    <Link className="size-5" />
                  </Button>
                </CopyToClipboard>
              </InputGroup>
            </Fieldset>
          ) : null}
        </FormSection>
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
  placeholder?: string;
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

  return <Textarea ref={ref} {...props} />;
};
