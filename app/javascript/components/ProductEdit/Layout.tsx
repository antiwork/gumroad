import { Link, router } from "@inertiajs/react";
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
import { useImageUploadSettings } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { SubtitleFile } from "$app/components/SubtitleList/Row";
import { Alert } from "$app/components/ui/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { WithTooltip } from "$app/components/WithTooltip";

import { FileEntry, useProductEditContext } from "./state";

export type ProductEditTab = "product" | "content" | "receipt" | "share";

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
  currentTab,
  isLoading = false,
  headerActions,
  previewScaleFactor = 0.4,
  showBorder = true,
  showNavigationButton = true,
}: {
  children: React.ReactNode;
  preview?: React.ReactNode;
  currentTab: ProductEditTab;
  isLoading?: boolean;
  headerActions?: React.ReactNode;
  previewScaleFactor?: number;
  showBorder?: boolean;
  showNavigationButton?: boolean;
}) => {
  const { product, uniquePermalink, saving, save, publishing, publish, unpublish } = useProductEditContext();

  const url = useProductUrl();
  const checkoutUrl = useProductUrl({ wanted: true });

  const isUploadingFile = (file: FileEntry | SubtitleFile) =>
    file.status.type === "unsaved" && file.status.uploadStatus.type === "uploading";
  const isUploadingFiles =
    product.public_files.some((f) => f.status?.type === "unsaved" && f.status.uploadStatus.type === "uploading") ||
    product.files.some((file) => isUploadingFile(file) || file.subtitle_files.some(isUploadingFile));
  const imageSettings = useImageUploadSettings();
  const isUploadingFilesOrImages = isLoading || isUploadingFiles || !!imageSettings?.isUploading;
  const isBusy = isUploadingFilesOrImages || saving || publishing;
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

  const onTabClick = (e: React.MouseEvent, callback?: () => void) => {
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

    callback?.();
  };

  const isCoffee = product.native_type === "coffee";

  return (
    <>
      <NotifyAboutProductUpdatesAlert />
      {/* TODO: remove this legacy uploader stuff */}
      <form hidden data-id={uniquePermalink} id="edit-link-basic-form" />
      <PageHeader
        className="sticky-top"
        title={product.name || "Untitled"}
        actions={
          product.is_published ? (
            <>
              <Button disabled={isBusy} onClick={unpublish}>
                {publishing ? "Unpublishing..." : "Unpublish"}
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
              onClick={() =>
                void save().then(() =>
                  router.visit(`${Routes.edit_link_path(uniquePermalink)}/content`, { preserveScroll: true }),
                )
              }
            >
              {saving ? "Saving changes..." : "Save and continue"}
            </Button>
          ) : (
            <>
              {saveButton}
              <WithTooltip tip={saveButtonTooltip}>
                <Button color="accent" disabled={isBusy} onClick={publish}>
                  {publishing ? "Publishing..." : "Publish and continue"}
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
              <Link href={Routes.edit_link_path(uniquePermalink)} preserveScroll onClick={onTabClick}>
                Product
              </Link>
            </Tab>
            {!isCoffee ? (
              <Tab asChild isSelected={currentTab === "content"}>
                <Link
                  href={`${Routes.edit_link_path(uniquePermalink)}/content`}
                  preserveScroll
                  onClick={onTabClick}
                >
                  Content
                </Link>
              </Tab>
            ) : null}
            <Tab asChild isSelected={currentTab === "receipt"}>
              <Link href={`${Routes.edit_link_path(uniquePermalink)}/receipt`} preserveScroll onClick={onTabClick}>
                Receipt
              </Link>
            </Tab>
            <Tab asChild isSelected={currentTab === "share"}>
              <Link
                href={`${Routes.edit_link_path(uniquePermalink)}/share`}
                preserveScroll
                onClick={(evt) => {
                  onTabClick(evt, () => {
                    if (!product.is_published) {
                      evt.preventDefault();
                      showAlert(
                        "Not yet! You've got to publish your awesome product before you can share it with your audience and the world.",
                        "warning",
                      );
                    }
                  });
                }}
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
    </>
  );
};
