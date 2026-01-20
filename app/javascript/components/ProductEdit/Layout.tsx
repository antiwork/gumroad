import { router } from "@inertiajs/react";
import { DirectUpload } from "@rails/activestorage";
import cx from "classnames";
import { isEqual } from "lodash-es";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { saveProduct } from "$app/data/product_edit";
import { OtherRefundPolicy } from "$app/data/products/other_refund_policies";
import { setProductPublished } from "$app/data/publish_product";
import { Thumbnail } from "$app/data/thumbnails";
import { RatingsWithPercentages } from "$app/parsers/product";
import { classNames } from "$app/utils/classNames";
import { CurrencyCode } from "$app/utils/currency";
import { Taxonomy } from "$app/utils/discover";
import { ALLOWED_EXTENSIONS } from "$app/utils/file";
import { assertResponseError, request } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Preview } from "$app/components/Preview";
import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { Seller } from "$app/components/Product";
import { getDownloadUrl } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { Page } from "$app/components/ProductEdit/ContentTab/PageTab";
import { RefundPolicy } from "$app/components/ProductEdit/RefundPolicy";
import {
  ProductEditContext,
  Product,
  ProfileSection,
  ExistingFileEntry,
  ShippingCountry,
  ContentUpdates,
} from "$app/components/ProductEdit/state";
import { ImageUploadSettingsContext } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { SubtitleFile } from "$app/components/SubtitleList/Row";
import { Alert } from "$app/components/ui/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { WithTooltip } from "$app/components/WithTooltip";

import { FileEntry, useProductEditContext } from "./state";

type TabType = "product" | "content" | "receipt" | "share";

export type ProductEditProps = {
  product: Product;
  id: string;
  unique_permalink: string;
  thumbnail: Thumbnail | null;
  refund_policies: OtherRefundPolicy[];
  currency_type: CurrencyCode;
  is_tiered_membership: boolean;
  is_listed_on_discover: boolean;
  is_physical: boolean;
  profile_sections: ProfileSection[];
  taxonomies: Taxonomy[];
  earliest_membership_price_change_date: string;
  custom_domain_verification_status: { success: boolean; message: string } | null;
  sales_count_for_inventory: number;
  successful_sales_count: number;
  ratings: RatingsWithPercentages;
  seller: Seller;
  existing_files: ExistingFileEntry[];
  aws_key: string;
  s3_url: string;
  available_countries: ShippingCountry[];
  google_client_id: string;
  google_calendar_enabled: boolean;
  seller_refund_policy_enabled: boolean;
  seller_refund_policy: Pick<RefundPolicy, "title" | "fine_print">;
  cancellation_discounts_enabled: boolean;
  ai_generated: boolean;
};

const createContextValue = (props: ProductEditProps) => ({
  id: props.id,
  product: props.product,
  updateProduct: () => {},
  uniquePermalink: props.unique_permalink,
  refundPolicies: props.refund_policies,
  thumbnail: props.thumbnail,
  currencyType: props.currency_type,
  isTieredMembership: props.is_tiered_membership,
  isListedOnDiscover: props.is_listed_on_discover,
  isPhysical: props.is_physical,
  profileSections: props.profile_sections,
  taxonomies: props.taxonomies,
  earliestMembershipPriceChangeDate: new Date(props.earliest_membership_price_change_date),
  customDomainVerificationStatus: props.custom_domain_verification_status,
  salesCountForInventory: props.sales_count_for_inventory,
  successfulSalesCount: props.successful_sales_count,
  ratings: props.ratings,
  seller: props.seller,
  existingFiles: props.existing_files,
  setExistingFiles: () => {},
  awsKey: props.aws_key,
  s3Url: props.s3_url,
  availableCountries: props.available_countries,
  saving: false,
  save: async () => {},
  googleClientId: props.google_client_id,
  googleCalendarEnabled: props.google_calendar_enabled,
  seller_refund_policy_enabled: props.seller_refund_policy_enabled,
  seller_refund_policy: props.seller_refund_policy,
  cancellationDiscountsEnabled: props.cancellation_discounts_enabled,
  contentUpdates: null,
  setContentUpdates: () => {},
  filesById: new Map(props.product.files.map((file) => [file.id, { ...file, url: getDownloadUrl(props.id, file) }])),
});

const pagesHaveSameContent = (pages1: Page[], pages2: Page[]): boolean => isEqual(pages1, pages2);

const findUpdatedContent = (product: Product, lastSavedProduct: Product) => {
  const contentUpdatedVariantIds = product.variants
    .filter((variant) => {
      const lastSavedVariant = lastSavedProduct.variants.find((v) => v.id === variant.id);
      return !pagesHaveSameContent(variant.rich_content, lastSavedVariant?.rich_content ?? []);
    })
    .map((variant) => variant.id);

  const sharedContentUpdated = !pagesHaveSameContent(product.rich_content, lastSavedProduct.rich_content);

  return {
    sharedContentUpdated,
    contentUpdatedVariantIds,
  };
};

export const useProductUrl = (params = {}) => {
  const { product, uniquePermalink } = useProductEditContext();
  const currentSeller = useCurrentSeller();
  const { appDomain } = useDomains();
  return product.native_type === "coffee" && currentSeller
    ? Routes.custom_domain_coffee_url({ host: currentSeller.subdomain, ...params })
    : Routes.short_link_url(product.custom_permalink ?? uniquePermalink, {
        host: currentSeller?.subdomain ?? appDomain,
        ...params,
      });
};

const NotifyAboutProductUpdatesAlert = () => {
  const { uniquePermalink, contentUpdates, setContentUpdates } = useProductEditContext();
  const timerRef = React.useRef<number | null>(null);
  const isVisible = !!contentUpdates;

  const clearTimer = () => {
    if (timerRef.current !== null) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  };

  const startTimer = () => {
    clearTimer();
    timerRef.current = window.setTimeout(() => {
      close();
    }, 10_000);
  };

  const close = () => {
    clearTimer();
    setContentUpdates(null);
  };

  React.useEffect(() => {
    if (isVisible) {
      startTimer();
    }

    return clearTimer;
  }, [isVisible]);

  const handleMouseEnter = () => {
    clearTimer();
  };

  const handleMouseLeave = () => {
    startTimer();
  };

  return (
    <div
      className={cx("fixed top-4 right-1/2", isVisible ? "visible" : "invisible")}
      style={{
        transform: `translateX(50%) translateY(${isVisible ? 0 : "calc(-100% - var(--spacer-4))"})`,
        transition: "all 0.3s ease-out 0.5s",
        zIndex: "var(--z-index-tooltip)",
        backgroundColor: "var(--body-bg)",
      }}
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
    >
      <Alert variant="info">
        <div className="flex flex-col gap-4">
          Changes saved! Would you like to notify your customers about those changes?
          <div className="flex gap-2">
            <Button color="primary" outline onClick={() => close()}>
              Skip for now
            </Button>
            <NavigationButton
              color="primary"
              href={Routes.new_email_path({
                template: "content_updates",
                product: uniquePermalink,
                bought: contentUpdates?.uniquePermalinkOrVariantIds ?? [],
              })}
              onClick={() => {
                // NOTE: this is a workaround to make sure the alert closes after the tab is opened
                // with correct URL params. Otherwise `bought` won't be set correctly.
                setTimeout(() => close(), 100);
              }}
              target="_blank"
              rel="noreferrer"
            >
              Send notification
            </NavigationButton>
          </div>
        </div>
      </Alert>
    </div>
  );
};

export const Layout = ({
  children,
  preview,
  isLoading = false,
  headerActions,
  previewScaleFactor = 0.4,
  showBorder = true,
  showNavigationButton = true,
  currentTab,
  props,
}: {
  children: React.ReactNode;
  preview?: React.ReactNode;
  isLoading?: boolean;
  headerActions?: React.ReactNode;
  previewScaleFactor?: number;
  showBorder?: boolean;
  showNavigationButton?: boolean;
  currentTab: TabType;
  props: ProductEditProps;
}) => {
  const [imagesUploading, setImagesUploading] = React.useState<Set<File>>(new Set());
  const rootPath = `/products/${props.unique_permalink}/edit`;
  const [currencyType, setCurrencyType] = React.useState<CurrencyCode>(props.currency_type);
  const [product, setProduct] = React.useState(props.product);

  const [saving, setSaving] = React.useState(false);
  const currentSeller = useCurrentSeller();
  const { appDomain } = useDomains();

  const url =
    product.native_type === "coffee" && currentSeller
      ? Routes.custom_domain_coffee_url({ host: currentSeller.subdomain })
      : Routes.short_link_url(product.custom_permalink ?? props.unique_permalink, {
          host: currentSeller?.subdomain ?? appDomain,
        });
  const checkoutUrl =
    product.native_type === "coffee" && currentSeller
      ? Routes.custom_domain_coffee_url({ host: currentSeller.subdomain, wanted: true })
      : Routes.short_link_url(product.custom_permalink ?? props.unique_permalink, {
          host: currentSeller?.subdomain ?? appDomain,
          wanted: true,
        });

  const [isPublishing, setIsPublishing] = React.useState(false);
  const setPublished = async (published: boolean) => {
    try {
      setIsPublishing(true);
      await saveProduct(props.unique_permalink, props.id, product, currencyType);
      await setProductPublished(props.unique_permalink, published);
      updateProduct({ is_published: published });
      showAlert(published ? "Published!" : "Unpublished!", "success");
      if (currentTab === "share") {
        if (product.native_type === "coffee") router.visit(rootPath);
        else router.visit(`${rootPath}/content`);
      } else if (published) {
        router.visit(`${rootPath}/share`);
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error", { html: true });
    }
    setIsPublishing(false);
  };

  const isUploadingFile = (file: FileEntry | SubtitleFile) =>
    file.status.type === "unsaved" && file.status.uploadStatus.type === "uploading";
  const isUploadingFiles =
    product.public_files.some((f) => f.status?.type === "unsaved" && f.status.uploadStatus.type === "uploading") ||
    product.files.some((file) => isUploadingFile(file) || file.subtitle_files.some(isUploadingFile));
  const imageSettings = React.useMemo(
    () => ({
      isUploading: imagesUploading.size > 0,
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
    [imagesUploading.size],
  );
  const isUploadingFilesOrImages = isLoading || isUploadingFiles || !!imageSettings.isUploading;
  const isBusy = isUploadingFilesOrImages || saving || isPublishing;
  const saveButtonTooltip = isUploadingFiles
    ? "Files are still uploading..."
    : isUploadingFilesOrImages
      ? "Images are still uploading..."
      : isBusy
        ? "Please wait..."
        : undefined;

  React.useEffect(() => {
    if (!isUploadingFilesOrImages) return;

    const beforeUnload = (e: BeforeUnloadEvent) => e.preventDefault();

    window.addEventListener("beforeunload", beforeUnload);

    return () => window.removeEventListener("beforeunload", beforeUnload);
  }, [isUploadingFilesOrImages]);

  const saveButton = (
    <WithTooltip tip={saveButtonTooltip}>
      <Button color="primary" disabled={isBusy} onClick={() => void save()}>
        {saving ? "Saving changes..." : "Save changes"}
      </Button>
    </WithTooltip>
  );

  const onTabClick = (targetTab: "product" | "content" | "receipt" | "share") => {
    const message = isUploadingFiles
      ? "Some files are still uploading, please wait..."
      : isUploadingFilesOrImages
        ? "Some images are still uploading, please wait..."
        : undefined;

    if (message) {
      showAlert(message, "warning");
      return;
    }

    if (targetTab === "share" && !product.is_published) {
      showAlert(
        "Not yet! You've got to publish your awesome product before you can share it with your audience and the world.",
        "warning",
      );
      return;
    }

    const routes = {
      product: Routes.edit_link_path(props.unique_permalink),
      content: Routes.edit_link_content_path(props.unique_permalink),
      receipt: Routes.edit_link_receipt_path(props.unique_permalink),
      share: Routes.edit_link_share_path(props.unique_permalink),
    };

    router.visit(routes[targetTab], {
      preserveState: true,
      preserveScroll: true,
    });
  };

  const isCoffee = product.native_type === "coffee";

  const [contentUpdates, setContentUpdates] = React.useState<ContentUpdates>(null);
  const lastSavedProductRef = React.useRef<Product>(structuredClone(product));

  const updateProduct = (update: Partial<Product> | ((product: Product) => void)) =>
    setProduct((prevProduct) => {
      const updated = { ...prevProduct };
      if (typeof update === "function") update(updated);
      else Object.assign(updated, update);
      return updated;
    });
  const [existingFiles, setExistingFiles] = React.useState(props.existing_files);

  const save = async () => {
    try {
      setSaving(true);
      const response = await saveProduct(props.unique_permalink, props.id, product, currencyType);
      if (response.warning_message) showAlert(response.warning_message, "warning");
      else {
        const { contentUpdatedVariantIds, sharedContentUpdated } = findUpdatedContent(
          product,
          lastSavedProductRef.current,
        );
        const contentUpdated = sharedContentUpdated || contentUpdatedVariantIds.length > 0;

        if (props.successful_sales_count > 0 && contentUpdated) {
          const uniquePermalinkOrVariantIds = product.has_same_rich_content_for_all_variants
            ? [props.unique_permalink]
            : contentUpdatedVariantIds;

          setContentUpdates({
            uniquePermalinkOrVariantIds,
          });
        } else {
          showAlert("Changes saved!", "success");
        }
        lastSavedProductRef.current = structuredClone(product);
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setSaving(false);
  };

  const contextValue = React.useMemo(
    () => ({
      ...createContextValue({ ...props, product }),
      setCurrencyType,
      currencyType,
      existingFiles,
      setExistingFiles,
      updateProduct,
      save,
      saving,
      contentUpdates,
      setContentUpdates,
    }),
    [product, updateProduct, existingFiles, setExistingFiles],
  );

  return (
    <ProductEditContext.Provider value={contextValue}>
      <ImageUploadSettingsContext.Provider value={imageSettings}>
        <NotifyAboutProductUpdatesAlert />
        {/* TODO: remove this legacy uploader stuff */}
        <form hidden data-id={props.unique_permalink} id="edit-link-basic-form" />
        <PageHeader
          className="sticky-top"
          title={product.name || "Untitled"}
          actions={
            product.is_published ? (
              <>
                <Button disabled={isBusy} onClick={() => void setPublished(false)}>
                  {isPublishing ? "Unpublishing..." : "Unpublish"}
                </Button>
                {saveButton}
                <CopyToClipboard text={url} copyTooltip="Copy product URL">
                  <Button>
                    <Icon name="link" />
                  </Button>
                </CopyToClipboard>
                <CopyToClipboard text={checkoutUrl} copyTooltip="Copy checkout URL" tooltipPosition="left">
                  <Button>
                    <Icon name="cart-plus" />
                  </Button>
                </CopyToClipboard>
              </>
            ) : currentTab === "product" && !isCoffee ? (
              <Button
                color="primary"
                disabled={isBusy}
                onClick={() => void save().then(() => router.visit(`${rootPath}/content`))}
              >
                {saving ? "Saving changes..." : "Save and continue"}
              </Button>
            ) : (
              <>
                {saveButton}
                <WithTooltip tip={saveButtonTooltip}>
                  <Button color="accent" disabled={isBusy} onClick={() => void setPublished(true)}>
                    {isPublishing ? "Publishing..." : "Publish and continue"}
                  </Button>
                </WithTooltip>
              </>
            )
          }
        >
          <div
            className={classNames(
              "flex flex-col gap-2 lg:flex-row lg:items-center lg:justify-between",
              headerActions && "mt-2",
            )}
          >
            <Tabs style={{ gridColumn: 1 }}>
              <Tab isSelected={currentTab === "product"} onClick={() => onTabClick("product")}>
                Product
              </Tab>
              {!isCoffee ? (
                <Tab isSelected={currentTab === "content"} onClick={() => onTabClick("content")}>
                  Content
                </Tab>
              ) : null}
              <Tab isSelected={currentTab === "receipt"} onClick={() => onTabClick("receipt")}>
                Receipt
              </Tab>
              <Tab isSelected={currentTab === "share"} onClick={() => onTabClick("share")}>
                Share
              </Tab>
            </Tabs>
            {headerActions}
          </div>
        </PageHeader>
        {preview ? (
          <WithPreviewSidebar className="flex-1">
            {children}
            <PreviewSidebar
              {...(showNavigationButton && {
                previewLink: (props) => (
                  <NavigationButton
                    {...props}
                    disabled={isBusy}
                    href={url}
                    onClick={(evt) => {
                      evt.preventDefault();
                      void save().then(() => window.open(url, "_blank"));
                    }}
                  />
                ),
              })}
            >
              <Preview
                scaleFactor={previewScaleFactor}
                style={
                  showBorder
                    ? {
                        border: "var(--border)",
                        backgroundColor: "rgb(var(--filled))",
                        borderRadius: "var(--border-radius-2)",
                      }
                    : {}
                }
              >
                {preview}
              </Preview>
            </PreviewSidebar>
          </WithPreviewSidebar>
        ) : (
          <div className="flex-1">{children}</div>
        )}
      </ImageUploadSettingsContext.Provider>
    </ProductEditContext.Provider>
  );
};
