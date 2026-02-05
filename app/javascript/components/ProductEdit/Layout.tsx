import { Link, usePage, router } from "@inertiajs/react";
import cx from "classnames";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Preview } from "$app/components/Preview";
import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { type Product } from "$app/components/ProductEdit/state";
import { useImageUploadSettings } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { SubtitleFile } from "$app/components/SubtitleList/Row";
import { Alert } from "$app/components/ui/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { WithTooltip } from "$app/components/WithTooltip";

import { type FileEntry } from "./state";

type ContentUpdate = {
  uniquePermalinkOrVariantIds: string[];
};

type InertiaLayoutProps = {
  children: React.ReactNode;
  preview?: React.ReactNode;
  isLoading?: boolean;
  headerActions?: React.ReactNode;
  previewScaleFactor?: number;
  showBorder?: boolean;
  showNavigationButton?: boolean;
  currentTab: "product" | "content" | "receipt" | "share";
  onSave: () => void;
  isSaving?: boolean;
  contentUpdates?: ContentUpdate | null | undefined;
  setContentUpdates?: ((updates: ContentUpdate | null) => void) | undefined;
  onBeforeNavigate?: ((targetUrl: string) => boolean) | undefined;
};

type Props = {
  product: Product;
  unique_permalink: string;
};

export const useProductUrl = (params = {}) => {
  const { product, unique_permalink: uniquePermalink } = usePage<Props>().props;
  const currentSeller = useCurrentSeller();
  const { appDomain } = useDomains();

  const isCoffee = product.native_type === "coffee";

  return isCoffee && currentSeller
    ? Routes.custom_domain_coffee_url({ host: currentSeller.subdomain, ...params })
    : Routes.short_link_url(product.custom_permalink ?? uniquePermalink, {
        host: currentSeller?.subdomain ?? appDomain,
        ...params,
      });
};

const NotifyAboutProductUpdatesAlert = ({
  contentUpdates,
  setContentUpdates,
  uniquePermalink,
}: {
  contentUpdates: ContentUpdate | null;
  setContentUpdates: (updates: ContentUpdate | null) => void;
  uniquePermalink: string;
}) => {
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
  onSave,
  isSaving = false,
  contentUpdates = null,
  setContentUpdates = (_: ContentUpdate | null) => {},
  onBeforeNavigate,
}: InertiaLayoutProps) => {
  const { product, unique_permalink: uniquePermalink } = usePage<Props>().props;
  const currentSeller = useCurrentSeller();
  const { appDomain } = useDomains();

  const productUrl = useProductUrl();

  const isCoffee = product.native_type === "coffee";
  const checkoutUrl =
    isCoffee && currentSeller
      ? Routes.custom_domain_coffee_url({ host: currentSeller.subdomain, wanted: true })
      : Routes.short_link_url(product.custom_permalink ?? uniquePermalink, {
          host: currentSeller?.subdomain ?? appDomain,
          wanted: true,
        });

  const [isPublishing, setIsPublishing] = React.useState(false);

  const setPublished = (published: boolean) => {
    setIsPublishing(true);

    router.post(
      published ? Routes.publish_link_path(uniquePermalink) : Routes.unpublish_link_path(uniquePermalink),
      { current_tab: currentTab },
      {
        onFinish: () => {
          setIsPublishing(false);
        },
      },
    );
  };

  const isUploadingFile = (file: FileEntry | SubtitleFile) =>
    file.status.type === "unsaved" && file.status.uploadStatus.type === "uploading";
  const isUploadingFiles =
    product.public_files.some((f) => f.status?.type === "unsaved" && f.status.uploadStatus.type === "uploading") ||
    product.files.some((file) => isUploadingFile(file) || file.subtitle_files.some(isUploadingFile));
  const imageSettings = useImageUploadSettings();
  const isUploadingFilesOrImages = isLoading || isUploadingFiles || !!imageSettings?.isUploading;
  const isBusy = isUploadingFilesOrImages || isSaving || isPublishing;
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
      <Button color="primary" disabled={isBusy} onClick={onSave}>
        {isSaving ? "Saving changes..." : "Save changes"}
      </Button>
    </WithTooltip>
  );

  const handleTabClick = (e: React.MouseEvent, targetUrl: string) => {
    const message = isUploadingFiles
      ? "Some files are still uploading, please wait..."
      : isUploadingFilesOrImages
        ? "Some images are still uploading, please wait..."
        : undefined;

    if (message) {
      e.preventDefault();
      showAlert(message, "warning");
      return;
    }

    if (onBeforeNavigate?.(targetUrl)) {
      e.preventDefault();
    }
  };

  return (
    <>
      <NotifyAboutProductUpdatesAlert
        contentUpdates={contentUpdates}
        setContentUpdates={setContentUpdates}
        uniquePermalink={uniquePermalink}
      />
      <PageHeader
        className="sticky-top"
        title={product.name || "Untitled"}
        actions={
          product.is_published ? (
            <>
              <Button disabled={isBusy} onClick={() => setPublished(false)}>
                {isPublishing ? "Unpublishing..." : "Unpublish"}
              </Button>
              {saveButton}
              <CopyToClipboard text={productUrl} copyTooltip="Copy product URL">
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
              onClick={() => {
                onSave();
                setTimeout(() => router.visit(Routes.products_edit_content_path(uniquePermalink)), 0);
              }}
            >
              {isSaving ? "Saving changes..." : "Save and continue"}
            </Button>
          ) : (
            <>
              {saveButton}
              <WithTooltip tip={saveButtonTooltip}>
                <Button color="accent" disabled={isBusy} onClick={() => setPublished(true)}>
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
            <Tab asChild isSelected={currentTab === "product"}>
              <Link
                href={Routes.products_edit_product_path(uniquePermalink)}
                onClick={(e) => handleTabClick(e, Routes.products_edit_product_path(uniquePermalink))}
              >
                Product
              </Link>
            </Tab>
            {!isCoffee && (
              <Tab asChild isSelected={currentTab === "content"}>
                <Link
                  href={Routes.products_edit_content_path(uniquePermalink)}
                  onClick={(e) => handleTabClick(e, Routes.products_edit_content_path(uniquePermalink))}
                >
                  Content
                </Link>
              </Tab>
            )}
            <Tab asChild isSelected={currentTab === "receipt"}>
              <Link
                href={Routes.products_edit_receipt_path(uniquePermalink)}
                onClick={(e) => handleTabClick(e, Routes.products_edit_receipt_path(uniquePermalink))}
              >
                Receipt
              </Link>
            </Tab>
            <Tab asChild isSelected={currentTab === "share"}>
              <Link
                href={Routes.products_edit_share_path(uniquePermalink)}
                onClick={(e) => handleTabClick(e, Routes.products_edit_share_path(uniquePermalink))}
              >
                Share
              </Link>
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
                  href={productUrl}
                  onClick={(evt) => {
                    evt.preventDefault();
                    onSave();
                    setTimeout(() => router.visit(productUrl), 100);
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
    </>
  );
};
