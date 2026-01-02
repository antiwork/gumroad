import { useForm, router } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { UtmLinkNewPageProps, UtmLinkEditPageProps, UtmLinkFormData } from "$app/data/utm_links";
import { assertDefined } from "$app/utils/assert";

import { AnalyticsLayout } from "$app/components/Analytics/AnalyticsLayout";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { Icon } from "$app/components/Icons";
import { NavigationButtonInertia } from "$app/components/NavigationButton";
import { Select } from "$app/components/Select";
import { Pill } from "$app/components/ui/Pill";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { WithTooltip } from "$app/components/WithTooltip";

const MAX_UTM_PARAM_LENGTH = 200;

export const UtmLinkForm = ({ context, utm_link }: UtmLinkNewPageProps | UtmLinkEditPageProps) => {
  const isEditing = "id" in utm_link;
  const uid = React.useId();
  const form = useForm<UtmLinkFormData>(isEditing ? `EditUtmLink:${utm_link.id}` : "CreateUtmLink", utm_link);
  const [isLoadingNewPermalink, setIsLoadingNewPermalink] = React.useState(false);
  const searchParams = new URL(useOriginalLocation()).searchParams;

  const titleRef = React.useRef<HTMLInputElement>(null);

  React.useEffect(() => {
    if (Object.keys(form.errors).length > 0) form.clearErrors();
  }, [form.data]);

  React.useLayoutEffect(() => {
    if (Object.keys(form.errors).length > 0)
      document.querySelector("fieldset.danger")?.scrollIntoView({ behavior: "smooth", block: "center" });
  }, [form.errors]);

  const finalUrl = React.useMemo(() => {
    if (form.data.destination_option && form.data.utm_source && form.data.utm_medium && form.data.utm_campaign) {
      const params = new URLSearchParams();
      params.set("utm_source", form.data.utm_source);
      params.set("utm_medium", form.data.utm_medium);
      params.set("utm_campaign", form.data.utm_campaign);
      if (form.data.utm_term) params.set("utm_term", form.data.utm_term);
      if (form.data.utm_content) params.set("utm_content", form.data.utm_content);

      return [form.data.destination_option.url, params.toString()].filter(Boolean).join("?");
    }

    return null;
  }, [
    form.data.destination_option,
    form.data.utm_source,
    form.data.utm_medium,
    form.data.utm_campaign,
    form.data.utm_term,
    form.data.utm_content,
  ]);

  const generateNewPermalink = () => {
    router.reload({
      only: ["utm_link"],
      onStart: () => setIsLoadingNewPermalink(true),
      onSuccess: (data) => {
        form.setData("permalink", cast<{ utm_link: UtmLinkFormData }>(data.props).utm_link.permalink);
      },
      onFinish: () => setIsLoadingNewPermalink(false),
    });
  };

  const getFieldError = (attrName: keyof UtmLinkFormData) => {
    const error = form.errors[attrName];
    if (error) return error;

    if (attrName === "target_resource_id" || attrName === "target_resource_type") {
      return form.errors.target_resource_id || form.errors.target_resource_type || null;
    }

    return null;
  };

  const validateUtmParam = (field: keyof Pick<UtmLinkFormData, "utm_source" | "utm_medium" | "utm_campaign">) => {
    if (!form.data[field] || form.data[field].trim().length === 0) {
      form.setError(field, "Must be present");
      return false;
    }
    return true;
  };

  const validate = () => {
    if (form.data.title.trim().length === 0) {
      form.setError("title", "Must be present");
      titleRef.current?.focus();
      return false;
    }

    if (!form.data.destination_option) {
      form.setError("target_resource_id", "Must be present");
      return false;
    }

    if (!validateUtmParam("utm_source") || !validateUtmParam("utm_medium") || !validateUtmParam("utm_campaign"))
      return false;

    return true;
  };

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!validate()) return;

    if (isEditing) {
      form.patch(Routes.dashboard_utm_link_path(assertDefined(utm_link.id)));
    } else {
      form.transform((data) => {
        if (!data.destination_option) return data;

        const [targetResourceType, targetResourceId] = data.destination_option.id.split(/-(.*)/u);

        return {
          ...data,
          target_resource_type: ["profile_page", "subscribe_page"].includes(targetResourceType)
            ? data.destination_option.id
            : targetResourceType,
          target_resource_id: targetResourceId,
        };
      });

      form.post(
        Routes.dashboard_utm_links_path({
          copy_from: searchParams.get("copy_from"),
        }),
      );
    }
  };

  const whenProcessingOrLoadingNewPermalink = form.processing || isLoadingNewPermalink;

  return (
    <AnalyticsLayout
      title={isEditing ? "Edit link" : "Create link"}
      selectedTab="utm_links"
      actions={
        <>
          <NavigationButtonInertia
            disabled={whenProcessingOrLoadingNewPermalink}
            href={Routes.dashboard_utm_links_path()}
          >
            <Icon name="x-square" />
            Cancel
          </NavigationButtonInertia>
          <Button
            color="accent"
            onClick={submit}
            disabled={whenProcessingOrLoadingNewPermalink}
            type="submit"
            form="utm-link-form"
          >
            {form.processing ? "Saving..." : isEditing ? "Save changes" : "Add link"}
          </Button>
        </>
      }
    >
      <form id="utm-link-form" onSubmit={submit}>
        <section className="p-4! md:p-8!">
          <header>
            <p>Create UTM links to track where your traffic is coming from. </p>
            <p>Once set up, simply share the links to see which sources are driving more conversions and revenue.</p>
            <a href="/help/article/74-the-analytics-dashboard" target="_blank" rel="noreferrer">
              Learn more
            </a>
          </header>
          <fieldset className={cx({ danger: getFieldError("title") })}>
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
            {getFieldError("title") ? <small>{getFieldError("title")}</small> : null}
          </fieldset>
          <fieldset
            className={cx({
              danger: getFieldError("target_resource_id") || getFieldError("target_resource_type"),
            })}
          >
            <legend>
              <label htmlFor={`destination-${uid}`}>Destination</label>
            </legend>
            <Select
              inputId={`destination-${uid}`}
              instanceId={`destination-${uid}`}
              placeholder="Select where you want to send your audience"
              options={context.destination_options}
              value={form.data.destination_option}
              isMulti={false}
              isDisabled={isEditing}
              onChange={(option) => {
                form.setData(
                  "destination_option",
                  option ? (context.destination_options.find((o) => o.id === option.id) ?? null) : null,
                );
                form.clearErrors();
              }}
            />
            {getFieldError("target_resource_id") || getFieldError("target_resource_type") ? (
              <small>{getFieldError("target_resource_id") || getFieldError("target_resource_type")}</small>
            ) : null}
          </fieldset>
          <fieldset className={cx({ danger: getFieldError("permalink") })}>
            <legend>
              <label htmlFor={`${uid}-link-text`}>Link</label>
            </legend>
            <div style={{ display: "grid", gridTemplateColumns: "1fr auto", gap: "var(--spacer-2)" }}>
              <div className={cx("input", { disabled: isEditing })}>
                <Pill className="-ml-2 shrink-0">{context.short_url_prefix}</Pill>
                <input type="text" id={`${uid}-link-text`} value={form.data.permalink} readOnly disabled={isEditing} />
              </div>
              <div className="flex gap-2">
                <CopyToClipboard
                  copyTooltip="Copy short link"
                  text={`${context.short_url_protocol}://${context.short_url_prefix}${form.data.permalink}`}
                >
                  <Button type="button" aria-label="Copy short link">
                    <Icon name="link" />
                  </Button>
                </CopyToClipboard>
                {isEditing ? null : (
                  <WithTooltip tip="Generate new short link">
                    <Button
                      onClick={generateNewPermalink}
                      disabled={whenProcessingOrLoadingNewPermalink}
                      aria-label="Generate new short link"
                      type="button"
                    >
                      <Icon name="outline-refresh" />
                    </Button>
                  </WithTooltip>
                )}
              </div>
            </div>
            {getFieldError("permalink") ? (
              <small>{getFieldError("permalink")}</small>
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
            <fieldset className={cx({ danger: getFieldError("utm_source") })}>
              <legend>
                <label htmlFor={`${uid}-source`}>Source</label>
              </legend>
              <UtmFieldSelect
                id={`${uid}-source`}
                placeholder="newsletter"
                baseOptionValues={context.utm_fields_values.sources}
                value={form.data.utm_source}
                onChange={(value) => form.setData("utm_source", value ?? "")}
              />
              {getFieldError("utm_source") ? (
                <small>{getFieldError("utm_source")}</small>
              ) : (
                <small>Where the traffic comes from e.g Twitter, Instagram</small>
              )}
            </fieldset>
            <fieldset className={cx({ danger: getFieldError("utm_medium") })}>
              <legend>
                <label htmlFor={`${uid}-medium`}>Medium</label>
              </legend>
              <UtmFieldSelect
                id={`${uid}-medium`}
                placeholder="email"
                baseOptionValues={context.utm_fields_values.mediums}
                value={form.data.utm_medium}
                onChange={(value) => form.setData("utm_medium", value ?? "")}
              />
              {getFieldError("utm_medium") ? (
                <small>{getFieldError("utm_medium")}</small>
              ) : (
                <small>Medium by which the traffic arrived e.g. email, ads, story</small>
              )}
            </fieldset>
          </div>
          <fieldset className={cx({ danger: getFieldError("utm_campaign") })}>
            <legend>
              <label htmlFor={`${uid}-campaign`}>Campaign</label>
            </legend>
            <UtmFieldSelect
              id={`${uid}-campaign`}
              placeholder="new-course-launch"
              baseOptionValues={context.utm_fields_values.campaigns}
              value={form.data.utm_campaign}
              onChange={(value) => form.setData("utm_campaign", value ?? "")}
            />
            {getFieldError("utm_campaign") ? (
              <small>{getFieldError("utm_campaign")}</small>
            ) : (
              <small>Name of the campaign</small>
            )}
          </fieldset>
          <fieldset className={cx({ danger: getFieldError("utm_term") })}>
            <legend>
              <label htmlFor={`${uid}-term`}>Term</label>
            </legend>
            <UtmFieldSelect
              id={`${uid}-term`}
              placeholder="photo-editing"
              baseOptionValues={context.utm_fields_values.terms}
              value={form.data.utm_term}
              onChange={(value) => form.setData("utm_term", value)}
            />
            {getFieldError("utm_term") ? (
              <small>{getFieldError("utm_term")}</small>
            ) : (
              <small>Keywords used in ads</small>
            )}
          </fieldset>
          <fieldset className={cx({ danger: getFieldError("utm_content") })}>
            <legend>
              <label htmlFor={`${uid}-content`}>Content</label>
            </legend>
            <UtmFieldSelect
              id={`${uid}-content`}
              placeholder="video-ad"
              baseOptionValues={context.utm_fields_values.contents}
              value={form.data.utm_content}
              onChange={(value) => form.setData("utm_content", value)}
            />
            {getFieldError("utm_content") ? (
              <small>{getFieldError("utm_content")}</small>
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
