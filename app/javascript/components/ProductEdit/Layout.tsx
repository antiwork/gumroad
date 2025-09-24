import cx from "classnames";
import * as React from "react";
import { Link, useMatches, useNavigate } from "react-router-dom";

import { saveProduct } from "$app/data/product_edit";
import { setProductPublished } from "$app/data/publish_product";
import { classNames } from "$app/utils/classNames";
import { assertResponseError } from "$app/utils/request";
import { paramsToQueryString } from "$app/utils/url";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Preview } from "$app/components/Preview";
import { useImageUploadSettings } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import { newEmailPath } from "$app/components/server-components/EmailsPage";
import { SubtitleFile } from "$app/components/SubtitleList/Row";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useRefToLatest } from "$app/components/useRefToLatest";
import { WithTooltip } from "$app/components/WithTooltip";

import { FileEntry, useProductEditContext } from "./state";

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
      className={cx("fixed right-1/2 top-4", isVisible ? "visible" : "invisible")}
      style={{
        transform: `translateX(50%) translateY(${isVisible ? 0 : "calc(-100% - var(--spacer-4))"})`,
        transition: "all 0.3s ease-out 0.5s",
        zIndex: "var(--z-index-tooltip)",
        backgroundColor: "var(--body-bg)",
      }}
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
    >
      <div role="alert" className="info">
        <div className="paragraphs">
          Changes saved! Would you like to notify your customers about those changes?
          <div className="flex gap-2">
            <Button color="primary" outline onClick={() => close()}>
              Skip for now
            </Button>
            <NavigationButton
              color="primary"
              href={`${newEmailPath}?${paramsToQueryString({
                template: "content_updates",
                product: uniquePermalink,
                bought: contentUpdates?.uniquePermalinkOrVariantIds ?? [],
              })}`}
              onClick={() => {
                // NOTE: this is a workaround to make sure the alert closes after the tab is opened
                // with correct URL params. Otherwise `bought` won't be set correctly.
                setTimeout(() => close(), 100);
              }}
              target="_blank"
            >
              Send notification
            </NavigationButton>
          </div>
        </div>
      </div>
    </div>
  );
};

export const Layout = ({
  children,
  preview,
  isLoading = false,
  headerActions,
}: {
  children: React.ReactNode;
  preview?: React.ReactNode;
  isLoading?: boolean;
  headerActions?: React.ReactNode;
}) => {
  const { id, product, updateProduct, uniquePermalink, saving, save, currencyType } = useProductEditContext();
  const rootPath = `/products/${uniquePermalink}/edit`;

  const url = useProductUrl();
  const checkoutUrl = useProductUrl({ wanted: true });

  const [match] = useMatches();
  const tab = match?.handle ?? "product";

  const navigate = useRefToLatest(useNavigate());

  const [isPublishing, setIsPublishing] = React.useState(false);
  const setPublished = async (published: boolean) => {
    try {
      setIsPublishing(true);
      await saveProduct(uniquePermalink, id, product, currencyType);
      await setProductPublished(uniquePermalink, published);
      updateProduct({ is_published: published });
      showAlert(published ? "Published!" : "Unpublished!", "success");
      if (tab === "share") {
        if (product.native_type === "coffee") navigate.current(rootPath);
        else navigate.current(`${rootPath}/content`);
      } else if (published) {
        navigate.current(`${rootPath}/share`);
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
  const imageSettings = useImageUploadSettings();
  const isUploadingFilesOrImages = isLoading || isUploadingFiles || !!imageSettings?.isUploading;
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

  const onTabClick = (e: React.MouseEvent<HTMLAnchorElement>, callback?: () => void) => {
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
              <Button disabled={isBusy} onClick={() => void setPublished(false)}>
                {isPublishing ? "Unpublishing..." : "Unpublish"}
              </Button>
              {saveButton}
              <CopyToClipboard text={url} copyTooltip="Copy product URL">
                <Button>
                  <Icon name="link" />
                </Button>
              </CopyToClipboard>
              <CopyToClipboard text={checkoutUrl} copyTooltip="Copy checkout URL">
                <Button>
                  <Icon name="cart-plus" />
                </Button>
              </CopyToClipboard>
            </>
          ) : tab === "product" && !isCoffee ? (
            <Button
              color="primary"
              disabled={isBusy}
              onClick={() => void save().then(() => navigate.current(`${rootPath}/content`))}
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
            <Tab asChild isSelected={tab === "product"}>
              <Link to={rootPath} onClick={onTabClick}>
                Product
              </Link>
            </Tab>
            {!isCoffee ? (
              <Tab asChild isSelected={tab === "content"}>
                <Link to={`${rootPath}/content`} onClick={onTabClick}>
                  Content
                </Link>
              </Tab>
            ) : null}
            <Tab asChild isSelected={tab === "share"}>
              <Link
                to={`${rootPath}/share`}
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
      <div className={preview ? "squished fixed-aside flex-1 lg:grid lg:grid-cols-[1fr_30vw]" : "flex-1"}>
        {children}
        {preview ? (
          <aside aria-label="Preview" className="!sticky top-0 min-h-screen self-start overflow-y-auto">
            <header>
              <h2>Preview</h2>
              <WithTooltip tip="Preview">
                <NavigationButton
                  aria-label="Preview"
                  disabled={isBusy}
                  href={url}
                  onClick={(evt) => {
                    evt.preventDefault();
                    void save().then(() => window.open(url, "_blank"));
                  }}
                >
                  <Icon name="arrow-diagonal-up-right" />
                </NavigationButton>
              </WithTooltip>
            </header>
            <Preview
              scaleFactor={0.4}
              style={{
                border: "var(--border)",
                backgroundColor: "rgb(var(--filled))",
                borderRadius: "var(--border-radius-2)",
              }}
            >
              {preview}
            </Preview>
          </aside>
        ) : null}
      </div>
    </>
  );
};
