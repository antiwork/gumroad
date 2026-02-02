import { router } from "@inertiajs/react";
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
import { Alert } from "$app/components/ui/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tab, Tabs } from "$app/components/ui/Tabs";

import type { Product } from "./types";

type TabType = "product" | "content" | "share" | "receipt";

export const useProductUrl = (
  uniquePermalink: string,
  customPermalink: string | null,
  nativeType: string | undefined,
  params = {},
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

type EditLayoutProps = {
  children: React.ReactNode;
  preview?: React.ReactNode;
  headerActions?: React.ReactNode;
  previewScaleFactor?: number;
  showBorder?: boolean;
  showNavigationButton?: boolean;
  productId: string;
  product: Product;
  uniquePermalink: string;
  currentTab: TabType;
  isSaving: boolean;
  onSave: () => void;
  saveDisabled?: boolean;
  saveTooltip?: string;
};

export const EditLayout: React.FC<EditLayoutProps> = ({
  children,
  preview,
  headerActions,
  previewScaleFactor = 0.4,
  showBorder = true,
  showNavigationButton = true,
  productId,
  product,
  uniquePermalink,
  currentTab,
  isSaving,
  onSave,
  saveDisabled = false,
  saveTooltip,
}) => {
  const url = useProductUrl(uniquePermalink, product.custom_permalink ?? null, product.native_type);
  const checkoutUrl = useProductUrl(uniquePermalink, product.custom_permalink ?? null, product.native_type, {
    wanted: true,
  });

  const isCoffee = product.native_type === "coffee";
  const isPublished = product.is_published ?? false;

  const navigateToTab = (tab: TabType) => {
    if (tab === "product") {
      router.get(Routes.edit_product_product_path(productId));
    } else if (tab === "content") {
      router.get(Routes.edit_product_content_path(productId));
    } else if (tab === "share") {
      router.get(Routes.edit_product_share_path(productId));
    } else if (tab === "receipt") {
      router.get(Routes.edit_product_receipt_path(productId));
    }
  };

  const saveButton = (
    <Button color="primary" disabled={saveDisabled || isSaving} onClick={onSave} title={saveTooltip}>
      {isSaving ? "Saving changes..." : "Save changes"}
    </Button>
  );

  return (
    <>
      <PageHeader
        className="sticky-top"
        title={product.name || "Untitled"}
        actions={
          isPublished ? (
            <>
              <Button disabled={isSaving} onClick={() => router.patch(Routes.product_product_path(productId), { unpublish: true })}>
                Unpublish
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
              disabled={saveDisabled || isSaving}
              onClick={() => {
                onSave();
                // Navigate to content after save (will happen on next page load after redirect)
              }}
            >
              {isSaving ? "Saving changes..." : "Save and continue"}
            </Button>
          ) : (
            <>
              {saveButton}
              <Button
                color="accent"
                disabled={saveDisabled || isSaving}
                onClick={() => {
                  // TODO: Implement publish functionality
                  onSave();
                }}
              >
                Publish and continue
              </Button>
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
              <button type="button" onClick={() => navigateToTab("product")}>
                Product
              </button>
            </Tab>
            {!isCoffee ? (
              <Tab asChild isSelected={currentTab === "content"}>
                <button type="button" onClick={() => navigateToTab("content")}>
                  Content
                </button>
              </Tab>
            ) : null}
            <Tab asChild isSelected={currentTab === "receipt"}>
              <button type="button" onClick={() => navigateToTab("receipt")}>
                Receipt
              </button>
            </Tab>
            <Tab asChild isSelected={currentTab === "share"}>
              <button
                type="button"
                onClick={() => {
                  if (!isPublished) {
                    alert(
                      "Not yet! You've got to publish your awesome product before you can share it with your audience and the world.",
                    );
                    return;
                  }
                  navigateToTab("share");
                }}
              >
                Share
              </button>
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
                  disabled={isSaving}
                  href={url}
                  onClick={(evt) => {
                    evt.preventDefault();
                    onSave();
                    setTimeout(() => window.open(url, "_blank"), 500);
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
