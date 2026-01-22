import cx from "classnames";
import * as React from "react";
import { Link, useMatches, useNavigate } from "react-router-dom";

import { saveProduct } from "$app/data/product_edit";
import { setProductPublished } from "$app/data/publish_product";
import { classNames } from "$app/utils/classNames";
import { assertResponseError } from "$app/utils/request";

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
          Đã lưu thay đổi! Bạn có muốn thông báo cho khách hàng về những thay đổi này không?
          <div className="flex gap-2">
            <Button color="primary" outline onClick={() => close()}>
              Bỏ qua lúc này
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
              Gửi thông báo
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
}: {
  children: React.ReactNode;
  preview?: React.ReactNode;
  isLoading?: boolean;
  headerActions?: React.ReactNode;
  previewScaleFactor?: number;
  showBorder?: boolean;
  showNavigationButton?: boolean;
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
      showAlert(published ? "Đã xuất bản!" : "Đã hủy xuất bản!", "success");
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
    ? "Các tệp vẫn đang tải lên..."
    : isUploadingFilesOrImages
      ? "Hình ảnh vẫn đang tải lên..."
      : isBusy
        ? "Vui lòng đợi..."
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
        {saving ? "Đang lưu thay đổi..." : "Lưu thay đổi"}
      </Button>
    </WithTooltip>
  );

  const onTabClick = (e: React.MouseEvent<HTMLAnchorElement>, callback?: () => void) => {
    const message = isUploadingFiles
      ? "Một số tệp vẫn đang tải lên, vui lòng đợi..."
      : isUploadingFilesOrImages
        ? "Một số hình ảnh vẫn đang tải lên, vui lòng đợi..."
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
        title={product.name || "Không có tiêu đề"}
        actions={
          product.is_published ? (
            <>
              <Button disabled={isBusy} onClick={() => void setPublished(false)}>
                {isPublishing ? "Đang hủy xuất bản..." : "Hủy xuất bản"}
              </Button>
              {saveButton}
              <CopyToClipboard text={url} copyTooltip="Sao chép URL sản phẩm">
                <Button>
                  <Icon name="link" />
                </Button>
              </CopyToClipboard>
              <CopyToClipboard text={checkoutUrl} copyTooltip="Sao chép URL thanh toán" tooltipPosition="left">
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
              {saving ? "Đang lưu..." : "Lưu và tiếp tục"}
            </Button>
          ) : (
            <>
              {saveButton}
              <WithTooltip tip={saveButtonTooltip}>
                <Button color="accent" disabled={isBusy} onClick={() => void setPublished(true)}>
                  {isPublishing ? "Đang xuất bản..." : "Xuất bản và tiếp tục"}
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
                Sản phẩm
              </Link>
            </Tab>
            {!isCoffee ? (
              <Tab asChild isSelected={tab === "content"}>
                <Link to={`${rootPath}/content`} onClick={onTabClick}>
                  Nội dung
                </Link>
              </Tab>
            ) : null}
            <Tab asChild isSelected={tab === "receipt"}>
              <Link to={`${rootPath}/receipt`} onClick={onTabClick}>
                Biên lai
              </Link>
            </Tab>
            <Tab asChild isSelected={tab === "share"}>
              <Link
                to={`${rootPath}/share`}
                onClick={(evt) => {
                  onTabClick(evt, () => {
                    if (!product.is_published) {
                      evt.preventDefault();
                      showAlert(
                        "Chưa được đâu! Bạn phải xuất bản sản phẩm tuyệt vời của mình trước khi có thể chia sẻ nó với khán giả và thế giới.",
                        "warning",
                      );
                    }
                  });
                }}
              >
                Chia sẻ
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
