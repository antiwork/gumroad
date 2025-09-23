import { DirectUpload } from "@rails/activestorage";
import { Content, Editor, JSONContent } from "@tiptap/core";
import cx from "classnames";
import { addHours, format, startOfDay, startOfHour } from "date-fns";
import React from "react";
import { Link, Location, useLoaderData, useLocation, useNavigate, useSearchParams } from "react-router-dom";
import { cast } from "ts-safe-cast";

import {
  AudienceType,
  getRecipientCount,
  InstallmentFormContext,
  Installment,
  createInstallment,
  updateInstallment,
} from "$app/data/installments";
import { assertDefined } from "$app/utils/assert";
import Countdown from "$app/utils/countdown";
import { ALLOWED_EXTENSIONS } from "$app/utils/file";
import { asyncVoid } from "$app/utils/promise";
import { AbortError, assertResponseError, request } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { DateInput } from "$app/components/DateInput";
import { useDomains } from "$app/components/DomainSettings";
import {
  EmailAttachments,
  FilesDispatchProvider,
  FilesProvider,
  filesReducer,
  isFileUploading,
  mapEmailFilesToFileState,
} from "$app/components/EmailAttachments";
import { EvaporateUploaderProvider } from "$app/components/EvaporateUploader";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Popover } from "$app/components/Popover";
import { PriceInput } from "$app/components/PriceInput";
import { ImageUploadSettingsContext, RichTextEditor } from "$app/components/RichTextEditor";
import { S3UploadConfigProvider } from "$app/components/S3UploadConfig";
import { showAlert } from "$app/components/server-components/Alert";
import { editEmailPath, emailTabPath, newEmailPath } from "$app/components/server-components/EmailsPage";
import { TagInput } from "$app/components/TagInput";
import { UpsellCard } from "$app/components/TiptapExtensions/UpsellCard";
import { PageHeader } from "$app/components/ui/PageHeader";
import { useConfigureEvaporate } from "$app/components/useConfigureEvaporate";
import { useDebouncedCallback } from "$app/components/useDebouncedCallback";
import { useRunOnce } from "$app/components/useRunOnce";
import { WithTooltip } from "$app/components/WithTooltip";

type ProductOrVariantOption = {
  id: string;
  productPermalink: string;
  label: string;
  archived: boolean;
  type: "product" | "variant";
};

type InvalidFieldName =
  | "channel"
  | "paidMoreThan"
  | "paidLessThan"
  | "afterDate"
  | "beforeDate"
  | "title"
  | "scheduleDate"
  | "publishDate";
type SaveAction =
  | "save"
  | "save_and_preview_email"
  | "save_and_preview_post"
  | "save_and_schedule"
  | "save_and_publish";

const getRecipientType = (audienceType: AudienceType, boughtItems: ProductOrVariantOption[]) => {
  if (audienceType === "everyone") return "audience";
  if (audienceType === "followers") return "follower";
  if (audienceType === "affiliates") return "affiliate";
  if (boughtItems.length === 1) return boughtItems[0]?.type === "variant" ? "variant" : "product";
  return "seller";
};

const selectableProductOptions = (options: ProductOrVariantOption[], alwaysIncludeIds: string[]) =>
  options.filter((option) => alwaysIncludeIds.includes(option.id) || !option.archived);

const getBundleMarketingMessage = (searchParams: URLSearchParams) => {
  const bundleName = searchParams.get("bundle_name");
  const bundlePermalink = searchParams.get("bundle_permalink");
  if (!bundleName || !bundlePermalink) return [];

  const messageContent: JSONContent[] = [];
  for (const text of `Hey there,
I've put together a bundle of my products that I think you'll love.`.split("\n")) {
    messageContent.push({ type: "paragraph", content: [{ type: "text", text }] });
  }
  messageContent.push({ type: "horizontalRule" });
  messageContent.push({
    type: "paragraph",
    content: [{ type: "text", text: bundleName, marks: [{ type: "bold" }] }],
  });
  messageContent.push({
    type: "paragraph",
    content: [
      { type: "text", text: searchParams.get("standalone_price") ?? "", marks: [{ type: "strike" }] },
      { type: "text", text: ` ${searchParams.get("bundle_price") ?? ""}` },
    ],
  });
  messageContent.push({
    type: "paragraph",
    content: [{ type: "text", text: "Included in this bundle" }],
  });
  const productNames = searchParams.getAll("bundle_product_names[]");
  const permalinks = searchParams.getAll("bundle_product_permalinks[]");
  const hasLinks = productNames.length === permalinks.length;
  messageContent.push({
    type: "bulletList",
    content: productNames.map((productName, index) => ({
      type: "listItem",
      content: [
        {
          type: "paragraph",
          content: [
            {
              type: "text",
              text: productName,
              marks:
                hasLinks && permalinks[index]
                  ? [
                      {
                        type: "link",
                        attrs: {
                          href: Routes.short_link_url(assertDefined(permalinks[index])),
                          rel: "noopener noreferrer nofollow",
                          target: "_blank",
                        },
                      },
                    ]
                  : [],
            },
          ],
        },
      ],
    })),
  });

  messageContent.push({
    type: "button",
    attrs: {
      href: Routes.short_link_url(bundlePermalink),
      rel: "noopener noreferrer nofollow",
      target: "_blank",
    },
    content: [{ type: "text", text: "Get your bundle" }],
  });
  messageContent.push({ type: "horizontalRule" });
  messageContent.push({
    type: "paragraph",
    content: [{ type: "text", text: "Thanks for your support!" }],
  });

  return messageContent;
};

const getAudienceType = (installmentType: string): AudienceType => {
  if (installmentType === "affiliate") return "affiliates";
  if (installmentType === "follower") return "followers";
  if (["seller", "product", "variant"].includes(installmentType)) return "customers";
  return "everyone";
};

const toISODateString = (date: Date | string | undefined | null) => (date ? format(date, "yyyy-MM-dd") : "");

const DEFAULT_SECONDS_LEFT_TO_PUBLISH = 5;

export const EmailForm = () => {
  const uid = React.useId();
  const currentSeller = assertDefined(useCurrentSeller());
  const { context, installment } = cast<{ context: InstallmentFormContext; installment: Installment | null }>(
    useLoaderData(),
  );
  const hasAudience = context.audience_types.length > 0;
  const [audienceType, setAudienceType] = React.useState<AudienceType>(
    installment ? getAudienceType(installment.installment_type) : "everyone",
  );
  const [channel, setChannel] = React.useState<{ email: boolean; profile: boolean }>({
    email: installment?.send_emails ?? hasAudience,
    profile: installment?.shown_on_profile ?? true,
  });
  const [shownInProfileSections, setShownInProfileSections] = React.useState(
    installment?.shown_in_profile_sections ?? [],
  );
  const [affiliatedProducts, setAffiliatedProducts] = React.useState<string[]>(installment?.affiliate_products ?? []);
  const [recipientCount, setRecipientCount] = React.useState<{
    count: number;
    total: number;
    loading: boolean;
  }>({ count: 0, total: 0, loading: false });
  const activeRecipientCountRequest = React.useRef<{ cancel: () => void } | null>(null);
  const [searchParams] = useSearchParams();
  const routerLocation = cast<Location<{ from?: string | undefined } | null>>(useLocation());
  const [bought, setBought] = React.useState<string[]>(() => {
    if (!installment) return [];
    return installment.installment_type === "variant" && installment.variant_external_id
      ? [installment.variant_external_id]
      : installment.installment_type === "product" && installment.unique_permalink
        ? [installment.unique_permalink]
        : [...(installment.bought_products ?? []), ...(installment.bought_variants ?? [])];
  });
  const [notBought, setNotBought] = React.useState<string[]>(
    installment?.not_bought_products ?? installment?.not_bought_variants ?? [],
  );
  const [paidMoreThanCents, setPaidMoreThanCents] = React.useState<number | null>(
    installment?.paid_more_than_cents ?? null,
  );
  const [paidLessThanCents, setPaidLessThanCents] = React.useState<number | null>(
    installment?.paid_less_than_cents ?? null,
  );
  const [afterDate, setAfterDate] = React.useState(installment?.created_after ?? "");
  const [beforeDate, setBeforeDate] = React.useState(installment?.created_before ?? "");
  const [fromCountry, setFromCountry] = React.useState(installment?.bought_from ?? "");
  const [allowComments, setAllowComments] = React.useState(
    installment?.allow_comments ?? context.allow_comments_by_default,
  );
  const [title, setTitle] = React.useState(installment?.name ?? "");
  const [publishDate, setPublishDate] = React.useState(toISODateString(installment?.published_at));
  React.useEffect(() => setPublishDate(toISODateString(installment?.published_at)), [installment]);
  const [message, setMessage] = React.useState(installment?.message ?? "");
  const [initialMessage, setInitialMessage] = React.useState<Content>(message);
  const handleMessageChange = useDebouncedCallback(setMessage, 500);
  const [messageEditor, setMessageEditor] = React.useState<Editor | null>(null);
  React.useEffect(() => {
    if (initialMessage !== "" && messageEditor?.isEmpty) {
      queueMicrotask(() => messageEditor.commands.setContent(initialMessage, true));
    }
  }, [messageEditor]);
  const [scheduleDate, setScheduleDate] = React.useState<Date | null>(startOfHour(addHours(new Date(), 1)));
  const [secondsLeftToPublish, setSecondsLeftToPublish] = React.useState(0);
  const publishCountdownRef = React.useRef<Countdown | null>(null);
  const titleRef = React.useRef<HTMLInputElement>(null);
  const sendEmailRef = React.useRef<HTMLInputElement>(null);
  const paidMoreThanRef = React.useRef<HTMLInputElement>(null);
  const afterDateRef = React.useRef<HTMLInputElement>(null);
  const publishDateRef = React.useRef<HTMLInputElement>(null);
  const [invalidFields, setInvalidFields] = React.useState(new Set<InvalidFieldName>());
  const [imagesUploading, setImagesUploading] = React.useState<Set<File>>(new Set());
  const { appDomain } = useDomains();
  const imageSettings = React.useMemo(
    () => ({
      onUpload: (file: File) => {
        setImagesUploading((prev) => new Set(prev).add(file));
        return new Promise<string>((resolve, reject) => {
          const upload = new DirectUpload(file, Routes.rails_direct_uploads_path());
          upload.create((error, blob) => {
            setImagesUploading((prev) => {
              const updated = new Set(prev);
              updated.delete(file);
              return updated;
            });

            if (error) reject(error);
            // Fetch the CDN URL for the image
            else
              request({
                method: "GET",
                accept: "json",
                url: Routes.s3_utility_cdn_url_for_blob_path({ key: blob.key }),
              })
                .then((response) => response.json())
                .then((data) => resolve(cast<{ url: string }>(data).url))
                .catch((e: unknown) => {
                  assertResponseError(e);
                  reject(e);
                });
          });
        });
      },
      allowedExtensions: ALLOWED_EXTENSIONS,
    }),
    [],
  );
  const { evaporateUploader, s3UploadConfig } = useConfigureEvaporate({
    aws_access_key_id: context.aws_access_key_id,
    s3_url: context.s3_url,
    user_id: context.user_id,
  });
  const [files, filesDispatch] = React.useReducer(
    filesReducer,
    installment?.external_id ? mapEmailFilesToFileState(installment.files, uid) : [],
  );
  const [isStreamOnly, setIsStreamOnly] = React.useState(installment?.stream_only ?? false);
  const productOptions = React.useMemo(
    () =>
      context.products.flatMap((product) => [
        {
          id: product.permalink,
          productPermalink: product.permalink,
          label: product.name,
          archived: product.archived,
          type: "product" as const,
        },
        ...product.variants.map((variant) => ({
          id: variant.id,
          productPermalink: product.permalink,
          label: `${product.name} - ${variant.name}`,
          archived: product.archived,
          type: "variant" as const,
        })),
      ]),
    [context.products],
  );

  useRunOnce(() => {
    if (routerLocation.pathname !== newEmailPath || searchParams.size === 0) return;

    const tier = searchParams.get("tier");
    const permalink = searchParams.get("product");
    const productName = productOptions.find((option) => option.id === permalink)?.label;
    const canSendToCustomers = context.audience_types.includes("customers");
    const template = searchParams.get("template");
    const isBundleMarketing = template === "bundle_marketing";

    if (template === "content_updates" && permalink) {
      const bought = searchParams.getAll("bought[]");
      setTitle(`New content added to ${productName}`);
      setBought(bought);
      setAudienceType("customers");
      setChannel({ profile: false, email: true });
      setInitialMessage({
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [
              {
                type: "text",
                text: "New content has been added to ",
              },
              {
                type: "text",
                marks: [
                  {
                    type: "link",
                    attrs: {
                      href: Routes.short_link_url(permalink, {
                        host: currentSeller.subdomain ?? appDomain,
                      }),
                    },
                  },
                ],
                text: productName ?? "your product",
              },
              {
                type: "text",
                text: ".",
              },
            ],
          },
          {
            type: "paragraph",
            content: [
              {
                type: "text",
                text: "You can access it by visiting your Gumroad Library or through the link in your email receipt.",
              },
            ],
          },
        ],
      });

      return;
    }

    if (tier !== null && productOptions.findIndex((option) => option.id === tier) !== -1 && canSendToCustomers) {
      setAudienceType("customers");
      setBought([tier]);
    } else if (permalink !== null && productName) {
      if (canSendToCustomers) {
        setAudienceType("customers");
        setBought([permalink]);
      }
      setTitle(`${productName} - updated!`);
      setInitialMessage({
        type: "doc",
        content: [
          {
            type: "paragraph",
            content: [
              {
                type: "text",
                text: `I have recently updated some files associated with ${productName}. They're yours for free.`,
              },
            ],
          },
        ],
      });
    } else if (isBundleMarketing) {
      if (canSendToCustomers) {
        const permalinks = searchParams
          .getAll("bundle_product_permalinks[]")
          .filter((permalink) => productOptions.findIndex((option) => option.id === permalink) !== -1);
        setAudienceType("customers");
        setBought(permalinks);
      }
      setChannel((prev) => ({ ...prev, profile: false }));
      const bundleName = searchParams.get("bundle_name");
      const bundlePermalink = searchParams.get("bundle_permalink");
      if (bundleName && bundlePermalink) {
        setTitle(`Introducing ${bundleName}`);
        setInitialMessage({ type: "doc", content: getBundleMarketingMessage(searchParams) });
      }
    }
  });

  const affiliateProductOptions = React.useMemo(
    () =>
      context.affiliate_products.map((product) => ({
        id: product.permalink,
        productPermalink: product.permalink,
        label: product.name,
        archived: product.archived,
        type: "product" as const,
      })),
    [context.affiliate_products],
  );

  const filterByType = (type: ProductOrVariantOption["type"], ids: string[]) =>
    productOptions.filter((option) => option.type === type && ids.includes(option.id));
  const boughtProducts =
    audienceType === "customers" || audienceType === "followers" ? filterByType("product", bought) : [];
  const boughtVariants =
    audienceType === "customers" || audienceType === "followers" ? filterByType("variant", bought) : [];
  const notBoughtProducts = audienceType === "affiliates" ? [] : filterByType("product", notBought);
  const notBoughtVariants = audienceType === "affiliates" ? [] : filterByType("variant", notBought);
  const boughtItems = [...boughtProducts, ...boughtVariants];
  const recipientType = getRecipientType(audienceType, boughtItems);
  const productId =
    recipientType === "product" || recipientType === "variant" ? (boughtItems[0]?.productPermalink ?? null) : null;
  const variantId = recipientType === "variant" ? (boughtVariants[0]?.id ?? null) : null;
  const filtersPayload = {
    paid_more_than_cents: audienceType === "customers" ? paidMoreThanCents : null,
    paid_less_than_cents: audienceType === "customers" ? paidLessThanCents : null,
    bought_from: audienceType === "customers" ? fromCountry : null,
    installment_type: recipientType,
    created_after: afterDate,
    created_before: beforeDate,
    bought_products:
      audienceType === "customers" || audienceType === "followers" ? boughtProducts.map(({ id }) => id) : null,
    bought_variants:
      audienceType === "customers" || audienceType === "followers" ? boughtVariants.map(({ id }) => id) : null,
    not_bought_products: audienceType === "affiliates" ? null : notBoughtProducts.map(({ id }) => id),
    not_bought_variants: audienceType === "affiliates" ? null : notBoughtVariants.map(({ id }) => id),
    affiliate_products: audienceType === "affiliates" ? affiliatedProducts : null,
    send_emails: channel.email,
    shown_on_profile: channel.profile,
    allow_comments: allowComments,
  };
  React.useEffect(() => {
    setRecipientCount((prev) => ({ ...prev, loading: true }));

    asyncVoid(async () => {
      try {
        activeRecipientCountRequest.current?.cancel();
        const request = getRecipientCount(filtersPayload);
        activeRecipientCountRequest.current = request;
        const response = await request.response;
        setRecipientCount({
          count: response.recipient_count,
          total: response.audience_count,
          loading: false,
        });
        activeRecipientCountRequest.current = null;
      } catch (error) {
        if (error instanceof AbortError) return;
        setRecipientCount((prev) => ({ ...prev, loading: false }));
        assertResponseError(error);
      }
    })();
  }, [JSON.stringify(filtersPayload)]);
  const isPublished = !!(installment?.external_id && installment.published_at);

  const validate = (action: SaveAction) => {
    const invalidFieldRefsAndErrors: [React.RefObject<HTMLElement> | null, string][] = [];
    const invalidFieldNames = new Set<InvalidFieldName>();

    if (title.trim() === "") {
      invalidFieldNames.add("title");
      invalidFieldRefsAndErrors.push([titleRef, "Please set a title."]);
    }

    if (!channel.email && !channel.profile) {
      invalidFieldNames.add("channel");
      invalidFieldRefsAndErrors.push([sendEmailRef, "Please set at least one channel for your update."]);
    }

    if (
      audienceType === "customers" &&
      !isPublished &&
      paidMoreThanCents &&
      paidLessThanCents &&
      paidMoreThanCents > paidLessThanCents
    ) {
      invalidFieldNames.add("paidMoreThan");
      invalidFieldNames.add("paidLessThan");
      invalidFieldRefsAndErrors.push([paidMoreThanRef, "Please enter valid paid more than and paid less than values."]);
    }

    if (hasAudience && !isPublished && afterDate && beforeDate && new Date(afterDate) > new Date(beforeDate)) {
      invalidFieldNames.add("afterDate");
      invalidFieldNames.add("beforeDate");
      invalidFieldRefsAndErrors.push([afterDateRef, "Please enter valid before and after dates."]);
    }

    if (action === "save_and_schedule" && (!scheduleDate || new Date(scheduleDate) < new Date())) {
      invalidFieldNames.add("scheduleDate");
      invalidFieldRefsAndErrors.push([null, "Please select a date and time in the future."]);
    }

    if (
      action !== "save_and_publish" &&
      action !== "save_and_schedule" &&
      isPublished &&
      publishDate &&
      startOfDay(publishDate) > new Date()
    ) {
      invalidFieldNames.add("publishDate");
      invalidFieldRefsAndErrors.push([publishDateRef, "Please enter a publish date in the past."]);
    }

    setInvalidFields(invalidFieldNames);
    const invalidFieldRefAndError = invalidFieldRefsAndErrors[0];
    if (invalidFieldRefAndError) {
      invalidFieldRefAndError[0]?.current?.focus();
      showAlert(invalidFieldRefAndError[1], "error");
    }

    return invalidFieldNames.size === 0;
  };
  const markFieldAsValid = (fieldName: InvalidFieldName) => {
    if (invalidFields.has(fieldName)) {
      setInvalidFields((prev) => {
        const updated = new Set(prev);
        updated.delete(fieldName);
        return updated;
      });
    }
  };
  const navigate = useNavigate();
  const [isSaving, setIsSaving] = React.useState(false);
  const save = asyncVoid(async (action: SaveAction = "save") => {
    if (!validate(action)) return;

    const payload = {
      installment: {
        name: title,
        message,
        files: files.map((file, position) => ({
          external_id: file.id,
          position,
          url: file.url,
          stream_only: file.is_streamable && isStreamOnly,
          subtitle_files: file.subtitle_files,
        })),
        link_id: productId,
        published_at:
          isPublished &&
          publishDate !== toISODateString(installment.published_at) &&
          action !== "save_and_schedule" &&
          action !== "save_and_publish"
            ? publishDate
            : null,
        shown_in_profile_sections: audienceType === "everyone" && channel.profile ? [...shownInProfileSections] : [],
        ...filtersPayload,
      },
      variant_external_id: variantId,
      send_preview_email: action === "save_and_preview_email",
      to_be_published_at: action === "save_and_schedule" ? scheduleDate : null,
      publish: action === "save_and_publish",
    };

    try {
      setIsSaving(true);
      const response = installment?.external_id
        ? await updateInstallment(installment.external_id, payload)
        : await createInstallment(payload);
      showAlert(
        action === "save_and_preview_email"
          ? "A preview has been sent to your email."
          : action === "save_and_preview_post"
            ? "Preview link opened."
            : action === "save_and_schedule"
              ? "Email successfully scheduled!"
              : action === "save_and_publish"
                ? `Email successfully ${channel.profile ? "published" : "sent"}!`
                : installment?.external_id
                  ? "Changes saved!"
                  : "Email created!",
        "success",
      );
      if (action === "save_and_preview_post") {
        window.open(response.full_url, "_blank");
      }

      if (action === "save_and_schedule") {
        navigate(emailTabPath("scheduled"));
      } else if (action === "save_and_publish") {
        navigate(emailTabPath("published"));
      } else {
        navigate(editEmailPath(response.installment_id), {
          replace: true,
          state: { from: routerLocation.state?.from },
        });
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error", { html: true });
    } finally {
      setIsSaving(false);
    }
  });
  const isBusy =
    isSaving ||
    imagesUploading.size > 0 ||
    files.some((file) => isFileUploading(file) || file.subtitle_files.some(isFileUploading));

  const cancelPath =
    routerLocation.state?.from ?? emailTabPath(context.has_scheduled_emails ? "scheduled" : "published");

  return (
    <div>
      <PageHeader
        title={installment?.external_id ? "Edit email" : "New email"}
        actions={
          <>
            {channel.email && channel.profile ? (
              <Popover
                trigger={
                  <Button disabled={isBusy}>
                    <Icon name="eye-fill" />
                    Preview
                    <Icon name="outline-cheveron-down" />
                  </Button>
                }
              >
                <div style={{ display: "grid", gap: "var(--spacer-3)" }}>
                  <Button disabled={isBusy} onClick={() => save("save_and_preview_post")}>
                    <Icon name="file-earmark-medical-fill" />
                    Preview Post
                  </Button>
                  <Button disabled={isBusy} onClick={() => save("save_and_preview_email")}>
                    <Icon name="envelope-fill" />
                    Preview Email
                  </Button>
                </div>
              </Popover>
            ) : (
              <Button
                disabled={isBusy}
                onClick={() => save(channel.profile ? "save_and_preview_post" : "save_and_preview_email")}
              >
                <Icon name="eye-fill" />
                Preview
              </Button>
            )}
            <Link to={cancelPath} className="button" inert={isBusy}>
              <Icon name="x-square" />
              Cancel
            </Link>
            <Popover
              trigger={
                <Button disabled={isBusy}>
                  {channel.profile ? "Publish" : "Send"}
                  <Icon name="outline-cheveron-down" />
                </Button>
              }
            >
              <div style={{ display: "grid", gap: "var(--spacer-3)" }}>
                <div style={{ display: "grid", gridTemplateColumns: "1fr max-content" }}>
                  {isSaving && secondsLeftToPublish > 0 ? (
                    <>
                      <Button color="accent" disabled>
                        {channel.profile ? "Publishing" : "Sending"} in {secondsLeftToPublish}...
                      </Button>
                      <Button
                        style={{ marginLeft: "var(--spacer-2)" }}
                        onClick={() => {
                          if (publishCountdownRef.current) {
                            publishCountdownRef.current.abort();
                            publishCountdownRef.current = null;
                          }
                          setIsSaving(false);
                          setSecondsLeftToPublish(0);
                        }}
                      >
                        <Icon name="x" />
                      </Button>
                    </>
                  ) : (
                    <Button
                      color="accent"
                      onClick={() => {
                        if (!validate("save_and_publish")) return;

                        setIsSaving(true);
                        publishCountdownRef.current = new Countdown(
                          DEFAULT_SECONDS_LEFT_TO_PUBLISH,
                          (secondsLeft) => {
                            setSecondsLeftToPublish(secondsLeft);
                          },
                          () => {
                            publishCountdownRef.current = null;
                            save("save_and_publish");
                          },
                        );
                      }}
                    >
                      {channel.profile ? "Publish now" : "Send now"}
                    </Button>
                  )}
                </div>
                <div role="separator">OR</div>
                <fieldset className={cx({ danger: invalidFields.has("scheduleDate") })}>
                  <DateInput
                    withTime
                    aria-label="Schedule date"
                    value={scheduleDate}
                    min={new Date()}
                    disabled={isPublished}
                    onChange={(date) => {
                      if (date) setScheduleDate(date);
                      markFieldAsValid("scheduleDate");
                    }}
                  />
                </fieldset>
                <Button disabled={isPublished || isBusy} onClick={() => save("save_and_schedule")}>
                  Schedule
                </Button>
              </div>
            </Popover>
            <Button color="accent" disabled={isBusy} onClick={() => save()}>
              Save
            </Button>
          </>
        }
      />
      <section className="space-y-4 p-4 md:p-8">
        <div className="with-sidebar">
          <div className="stack">
            <div>
              <fieldset role="group">
                <legend>
                  <div>Audience</div>
                  {hasAudience ? (
                    recipientCount.loading ? (
                      <div>
                        <LoadingSpinner width="1.25em" />
                      </div>
                    ) : (
                      <div aria-label="Recipient count">{`${recipientCount.count.toLocaleString()} / ${recipientCount.total.toLocaleString()}`}</div>
                    )
                  ) : null}
                </legend>
                <label htmlFor={`${uid}-recipient_everyone`}>
                  Everyone
                  <input
                    id={`${uid}-recipient_everyone`}
                    type="radio"
                    checked={audienceType === "everyone"}
                    disabled={isPublished}
                    onChange={() => setAudienceType("everyone")}
                  />
                </label>
                {context.audience_types.includes("followers") ? (
                  <label htmlFor={`${uid}-recipient_followers_only`}>
                    Followers only
                    <input
                      id={`${uid}-recipient_followers_only`}
                      type="radio"
                      checked={audienceType === "followers"}
                      disabled={isPublished}
                      onChange={() => setAudienceType("followers")}
                    />
                  </label>
                ) : null}
                {context.audience_types.includes("customers") ? (
                  <label htmlFor={`${uid}-recipient_customers_only`}>
                    Customers only
                    <input
                      id={`${uid}-recipient_customers_only`}
                      type="radio"
                      checked={audienceType === "customers"}
                      disabled={isPublished}
                      onChange={() => setAudienceType("customers")}
                    />
                  </label>
                ) : null}
                {context.audience_types.includes("affiliates") ? (
                  <label htmlFor={`${uid}-recipient_affiliates_only`}>
                    Affiliates only
                    <input
                      id={`${uid}-recipient_affiliates_only`}
                      type="radio"
                      checked={audienceType === "affiliates"}
                      disabled={isPublished}
                      onChange={() => setAudienceType("affiliates")}
                    />
                  </label>
                ) : null}
              </fieldset>
            </div>
            <div>
              <fieldset role="group" className={cx({ danger: invalidFields.has("channel") })}>
                <legend>Channel</legend>
                {hasAudience ? (
                  <label htmlFor={`${uid}-channel_email`}>
                    Send email
                    <input
                      id={`${uid}-channel_email`}
                      type="checkbox"
                      ref={sendEmailRef}
                      checked={channel.email}
                      disabled={!!(installment?.external_id && installment.has_been_blasted)}
                      onChange={(event) => {
                        setChannel((prev) => ({ ...prev, email: event.target.checked }));
                        markFieldAsValid("channel");
                      }}
                    />
                  </label>
                ) : null}
                <label htmlFor={`${uid}-channel_profile`}>
                  Post to profile
                  <WithTooltip
                    tip={
                      audienceType === "everyone"
                        ? "This post will be visible to anyone who visits your profile."
                        : audienceType === "customers"
                          ? "This post will be visible to your logged-in customers only."
                          : audienceType === "followers"
                            ? "This post will be visible to your logged-in followers only."
                            : "This post will be visible to your logged-in affiliates only."
                    }
                    position="top"
                  >
                    (?)
                  </WithTooltip>
                  <input
                    id={`${uid}-channel_profile`}
                    type="checkbox"
                    checked={channel.profile}
                    onChange={(event) => {
                      setChannel((prev) => ({ ...prev, profile: event.target.checked }));
                      markFieldAsValid("channel");
                    }}
                  />
                </label>
                {audienceType === "everyone" && channel.profile ? (
                  context.profile_sections.length > 0 ? (
                    <>
                      {context.profile_sections.map((section) => (
                        <label key={section.id} style={{ width: "fit-content" }}>
                          <input
                            type="checkbox"
                            role="switch"
                            checked={shownInProfileSections.includes(section.id)}
                            onChange={() => {
                              setShownInProfileSections((prevSections) =>
                                prevSections.includes(section.id)
                                  ? prevSections.filter((id) => id !== section.id)
                                  : [...prevSections, section.id],
                              );
                            }}
                          />

                          {section.name || "Unnamed section"}
                        </label>
                      ))}
                      {installment?.published_at ? null : (
                        <div className="info" role="status">
                          <div>The post will be shown in the selected profile sections once it is published.</div>
                        </div>
                      )}
                    </>
                  ) : (
                    <div className="info" role="status">
                      <div>
                        You currently have no sections in your profile to display this,{" "}
                        <a href={Routes.root_url({ host: currentSeller.subdomain })}>create one here</a>
                      </div>
                    </div>
                  )
                ) : null}
              </fieldset>
            </div>
            {audienceType === "affiliates" ? (
              <div>
                <fieldset role="group">
                  <legend>Affiliated products</legend>
                  <label htmlFor={`${uid}-all_affiliated_products`}>
                    All products
                    <input
                      id={`${uid}-all_affiliated_products`}
                      type="checkbox"
                      checked={affiliatedProducts.length === affiliateProductOptions.length}
                      disabled={isPublished}
                      onChange={(event) =>
                        setAffiliatedProducts(event.target.checked ? affiliateProductOptions.map(({ id }) => id) : [])
                      }
                    />
                  </label>
                  <TagInput
                    inputId={`${uid}-affiliated_products_dropdown`}
                    placeholder="Select products..."
                    tagIds={affiliatedProducts}
                    tagList={selectableProductOptions(affiliateProductOptions, affiliatedProducts)}
                    onChangeTagIds={setAffiliatedProducts}
                    isDisabled={isPublished}
                  />
                </fieldset>
              </div>
            ) : null}
            {audienceType === "customers" || audienceType === "followers" ? (
              <div>
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-bought`}>Bought</label>
                  </legend>
                  <TagInput
                    inputId={`${uid}-bought`}
                    placeholder="Any product"
                    tagIds={bought}
                    tagList={selectableProductOptions(productOptions, bought)}
                    onChangeTagIds={setBought}
                    isDisabled={isPublished}
                  />
                </fieldset>
              </div>
            ) : null}
            {hasAudience && audienceType !== "affiliates" ? (
              <div>
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-not_bought`}>Has not yet bought</label>
                  </legend>
                  <TagInput
                    inputId={`${uid}-not_bought`}
                    placeholder="No products"
                    tagIds={notBought}
                    tagList={selectableProductOptions(productOptions, notBought)}
                    onChangeTagIds={setNotBought}
                    isDisabled={isPublished}
                    // Displayed as a multi-select for consistency, but supports only one option for now
                    maxTags={1}
                  />
                </fieldset>
              </div>
            ) : null}
            {audienceType === "customers" ? (
              <div>
                <div
                  style={{
                    display: "grid",
                    gap: "var(--spacer-4)",
                    gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr)",
                  }}
                >
                  <fieldset className={cx({ danger: invalidFields.has("paidMoreThan") })}>
                    <legend>
                      <label htmlFor={`${uid}-paid_more_than`}>Paid more than</label>
                    </legend>
                    <PriceInput
                      id={`${uid}-paid_more_than`}
                      ref={paidMoreThanRef}
                      currencyCode={context.currency_type}
                      cents={paidMoreThanCents}
                      disabled={isPublished}
                      onChange={(cents) => {
                        setPaidMoreThanCents(cents);
                        markFieldAsValid("paidMoreThan");
                        markFieldAsValid("paidLessThan");
                      }}
                      placeholder="0"
                    />
                  </fieldset>
                  <fieldset className={cx({ danger: invalidFields.has("paidLessThan") })}>
                    <legend>
                      <label htmlFor={`${uid}-paid_less_than`}>Paid less than</label>
                    </legend>
                    <PriceInput
                      id={`${uid}-paid_less_than`}
                      currencyCode={context.currency_type}
                      cents={paidLessThanCents}
                      disabled={isPublished}
                      onChange={(cents) => {
                        setPaidLessThanCents(cents);
                        markFieldAsValid("paidMoreThan");
                        markFieldAsValid("paidLessThan");
                      }}
                      placeholder="∞"
                    />
                  </fieldset>
                </div>
              </div>
            ) : null}
            {hasAudience ? (
              <div>
                <div
                  style={{
                    display: "grid",
                    gap: "var(--spacer-4)",
                    gridTemplateColumns: "repeat(auto-fit, minmax(var(--dynamic-grid), 1fr))",
                  }}
                >
                  <fieldset className={cx({ danger: invalidFields.has("afterDate") })}>
                    <legend>
                      <label htmlFor={`${uid}-after_date`}>After</label>
                    </legend>
                    <input
                      type="date"
                      id={`${uid}-after_date`}
                      ref={afterDateRef}
                      value={afterDate}
                      disabled={isPublished}
                      onChange={(event) => {
                        setAfterDate(event.target.value);
                        markFieldAsValid("afterDate");
                        markFieldAsValid("beforeDate");
                      }}
                    />
                    <small>00:00 {context.timezone}</small>
                  </fieldset>
                  <fieldset className={cx({ danger: invalidFields.has("beforeDate") })}>
                    <legend>
                      <label htmlFor={`${uid}-before_date`}>Before</label>
                    </legend>
                    <input
                      type="date"
                      id={`${uid}-before_date`}
                      value={beforeDate}
                      disabled={isPublished}
                      onChange={(event) => {
                        setBeforeDate(event.target.value);
                        markFieldAsValid("beforeDate");
                        markFieldAsValid("afterDate");
                      }}
                    />
                    <small>11:59 {context.timezone}</small>
                  </fieldset>
                </div>
              </div>
            ) : null}
            {audienceType === "customers" ? (
              <div>
                <fieldset>
                  <legend>
                    <label htmlFor={`${uid}-from_country`}>From</label>
                  </legend>
                  <select
                    id={`${uid}-from_country`}
                    value={fromCountry}
                    disabled={isPublished}
                    onChange={(event) => setFromCountry(event.target.value)}
                  >
                    <option value="">Anywhere</option>
                    {context.countries.map((country) => (
                      <option key={country} value={country}>
                        {country}
                      </option>
                    ))}
                  </select>
                </fieldset>
              </div>
            ) : null}
            <div>
              <fieldset role="group">
                <legend>Engagement</legend>
                <label htmlFor={`${uid}-allow_comments`}>
                  Allow comments
                  <input
                    id={`${uid}-allow_comments`}
                    type="checkbox"
                    checked={allowComments}
                    onChange={(event) => setAllowComments(event.target.checked)}
                  />
                </label>
              </fieldset>
            </div>
          </div>
          <S3UploadConfigProvider value={s3UploadConfig}>
            <EvaporateUploaderProvider value={evaporateUploader}>
              <div style={{ display: "grid", gap: "var(--spacer-5)" }}>
                <fieldset className={cx({ danger: invalidFields.has("title") })}>
                  <input
                    ref={titleRef}
                    type="text"
                    placeholder="Title"
                    maxLength={255}
                    value={title}
                    onChange={(e) => {
                      setTitle(e.target.value);
                      markFieldAsValid("title");
                    }}
                  />
                </fieldset>
                {isPublished ? (
                  <fieldset className={cx({ danger: invalidFields.has("publishDate") })}>
                    <input
                      ref={publishDateRef}
                      type="date"
                      placeholder="Publish date"
                      id={`${uid}-publish_date`}
                      value={publishDate}
                      onChange={(event) => {
                        setPublishDate(event.target.value);
                        markFieldAsValid("publishDate");
                      }}
                      max={toISODateString(new Date())}
                    />
                  </fieldset>
                ) : null}
                <ImageUploadSettingsContext.Provider value={imageSettings}>
                  <RichTextEditor
                    className="textarea"
                    ariaLabel="Email message"
                    placeholder="Write a personalized message..."
                    initialValue={initialMessage}
                    onChange={handleMessageChange}
                    onCreate={setMessageEditor}
                    extensions={[UpsellCard]}
                  />
                </ImageUploadSettingsContext.Provider>
                <FilesProvider value={files}>
                  <FilesDispatchProvider value={filesDispatch}>
                    <EmailAttachments emailId={uid} isStreamOnly={isStreamOnly} setIsStreamOnly={setIsStreamOnly} />
                  </FilesDispatchProvider>
                </FilesProvider>
              </div>
            </EvaporateUploaderProvider>
          </S3UploadConfigProvider>
        </div>
      </section>
    </div>
  );
};
