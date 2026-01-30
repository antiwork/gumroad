import { Link } from "@inertiajs/react";
import * as React from "react";

import { classNames } from "$app/utils/classNames";

import { Button, NavigationButton } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Preview } from "$app/components/Preview";
import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { showAlert } from "$app/components/server-components/Alert";
import { Alert } from "$app/components/ui/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { WithTooltip } from "$app/components/WithTooltip";

import { Product } from "./state";

export type ProductEditLayoutProps = {
  id: string;
  name: string;
  customPermalink: string | null;
  uniquePermalink: string;
  isPublished: boolean;
  nativeType: Product["native_type"];
  currentTab: "product" | "content" | "receipt" | "share";
  children: React.ReactNode;
  preview?: React.ReactNode;
  isLoading?: boolean;
  isProcessing?: boolean;
  headerActions?: React.ReactNode;
  previewScaleFactor?: number;
  showBorder?: boolean;
  showNavigationButton?: boolean;
  onSave?: () => void;
  onSaveAndContinue?: () => void;
  onUnpublish?: () => void;
  onPublish?: () => void;
  onPreview?: () => void;
  onBeforeNavigate?: (targetPath: string) => boolean;
};

export const useProductUrl = (
  uniquePermalink: string,
  customPermalink: string | null,
  nativeType: Product["native_type"],
  params: Record<string, unknown> = {},
) => {
  const currentSeller = useCurrentSeller();
  const { appDomain } = useDomains();
  return nativeType === "coffee" && currentSeller
    ? Routes.custom_domain_coffee_url({ host: currentSeller.subdomain, ...params })
    : Routes.short_link_url(customPermalink ?? uniquePermalink, {
        host: currentSeller?.subdomain ?? appDomain,
        ...params,
      });
};

export const ProductEditLayout = ({
  id,
  name,
  customPermalink,
  uniquePermalink,
  isPublished,
  nativeType,
  currentTab,
  children,
  preview,
  isLoading = false,
  isProcessing = false,
  headerActions,
  previewScaleFactor = 0.4,
  showBorder = true,
  showNavigationButton = true,
  onSave,
  onSaveAndContinue,
  onUnpublish,
  onPublish,
  onPreview,
  onBeforeNavigate,
}: ProductEditLayoutProps) => {
  const rootPath = `/products/${uniquePermalink}/edit`;

  const url = useProductUrl(uniquePermalink, customPermalink, nativeType);
  const checkoutUrl = useProductUrl(uniquePermalink, customPermalink, nativeType, { wanted: true });

  const isBusy = isLoading || isProcessing;
  const saveButtonTooltip = isLoading ? "Files are still uploading..." : isBusy ? "Please wait..." : undefined;

  const saveButton = onSave ? (
    <WithTooltip tip={saveButtonTooltip}>
      <Button color="primary" disabled={isBusy} onClick={onSave}>
        {isProcessing ? "Saving changes..." : "Save changes"}
      </Button>
    </WithTooltip>
  ) : null;

  const handleTabClick = (e: React.MouseEvent<HTMLAnchorElement>, targetPath: string) => {
    if (isLoading) {
      e.preventDefault();
      showAlert("Files are still uploading, please wait...", "warning");
      return;
    }

    if (onBeforeNavigate?.(targetPath)) {
      e.preventDefault();
    }
  };

  const isCoffee = nativeType === "coffee";

  return (
    <>
      <form hidden data-id={uniquePermalink} id="edit-link-basic-form" />
      <PageHeader
        className="sticky-top"
        title={name || "Untitled"}
        actions={
          isPublished ? (
            <>
              {onUnpublish ? (
                <Button disabled={isBusy} onClick={onUnpublish}>
                  {isProcessing ? "Unpublishing..." : "Unpublish"}
                </Button>
              ) : null}
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
            onSaveAndContinue ? (
              <Button color="primary" disabled={isBusy} onClick={onSaveAndContinue}>
                {isProcessing ? "Saving changes..." : "Save and continue"}
              </Button>
            ) : null
          ) : (
            <>
              {saveButton}
              {onPublish ? (
                <WithTooltip tip={saveButtonTooltip}>
                  <Button color="accent" disabled={isBusy} onClick={onPublish}>
                    {isProcessing ? "Publishing..." : "Publish and continue"}
                  </Button>
                </WithTooltip>
              ) : null}
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
              <Link href={rootPath} onClick={(e) => handleTabClick(e, rootPath)}>
                Product
              </Link>
            </Tab>
            {!isCoffee ? (
              <Tab asChild isSelected={currentTab === "content"}>
                <Link href={`${rootPath}/content`} onClick={(e) => handleTabClick(e, `${rootPath}/content`)}>
                  Content
                </Link>
              </Tab>
            ) : null}
            <Tab asChild isSelected={currentTab === "receipt"}>
              <Link href={`${rootPath}/receipt`} onClick={(e) => handleTabClick(e, `${rootPath}/receipt`)}>
                Receipt
              </Link>
            </Tab>
            <Tab asChild isSelected={currentTab === "share"}>
              <Link
                href={`${rootPath}/share`}
                onClick={(e) => {
                  if (!isPublished) {
                    e.preventDefault();
                    showAlert(
                      "Not yet! You've got to publish your awesome product before you can share it with your audience and the world.",
                      "warning",
                    );
                    return;
                  }
                  handleTabClick(e, `${rootPath}/share`);
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
            {...(showNavigationButton &&
              onPreview && {
                previewLink: (props) => (
                  <NavigationButton {...props} disabled={isBusy} href={url} onClick={onPreview} />
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
