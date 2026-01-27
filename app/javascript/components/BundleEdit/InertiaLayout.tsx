import { Link, router } from "@inertiajs/react";
import * as React from "react";

import { setProductPublished } from "$app/data/publish_product";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Preview } from "$app/components/Preview";
import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { WithTooltip } from "$app/components/WithTooltip";

type BundleEditLayoutProps = {
  children: React.ReactNode;
  preview?: React.ReactNode;
  bundleId: string;
  bundleName: string;
  uniquePermalink: string;
  isPublished: boolean;
  currentTab: "product" | "content" | "share";
  isLoading?: boolean;
  additionalActions?: React.ReactNode;
};

export const BundleEditLayout = ({
  children,
  preview,
  bundleId,
  bundleName,
  uniquePermalink,
  isPublished,
  currentTab,
  isLoading = false,
  additionalActions,
}: BundleEditLayoutProps) => {
  const currentSeller = useCurrentSeller();
  const { appDomain } = useDomains();
  const isDesktop = useIsAboveBreakpoint("lg");

  const url = Routes.short_link_url(uniquePermalink, {
    host: currentSeller?.subdomain ?? appDomain,
  });

  const [isPublishing, setIsPublishing] = React.useState(false);
  const setPublished = async (published: boolean) => {
    try {
      setIsPublishing(true);
      await setProductPublished(uniquePermalink, published);
      showAlert(published ? "Published!" : "Unpublished!", "success");
      
      if (published && currentTab !== "share") {
        router.visit(Routes.edit_bundles_share_path(bundleId));
      } else if (!published && currentTab === "share") {
        router.visit(Routes.edit_bundles_content_path(bundleId));
      } else {
        router.reload();
      }
    } catch (e: any) {
      showAlert(e.message || "An error occurred", "error");
    }
    setIsPublishing(false);
  };

  const isBusy = isLoading || isPublishing;

  const onTabClick = (e: React.MouseEvent<HTMLAnchorElement>, callback?: () => void) => {
    const message = isLoading ? "Some images are still uploading, please wait..." : undefined;

    if (message) {
      e.preventDefault();
      showAlert(message, "warning");
      return;
    }

    callback?.();
  };

  return (
    <>
      <PageHeader
        className="sticky-top"
        title={bundleName || "Untitled"}
        actions={
          isPublished ? (
            <>
              {additionalActions}
              <Button disabled={isBusy} onClick={() => void setPublished(false)}>
                {isPublishing ? "Unpublishing..." : "Unpublish"}
              </Button>
              <CopyToClipboard
                text={url}
                copyTooltip="Copy product URL"
                tooltipPosition={isDesktop ? "left" : "bottom"}
              >
                <Button>
                  <Icon name="link" />
                </Button>
              </CopyToClipboard>
            </>
          ) : currentTab === "product" ? (
            <Button
              color="primary"
              disabled={isBusy}
              onClick={() => router.visit(Routes.edit_bundles_content_path(bundleId))}
            >
              Save and continue
            </Button>
          ) : (
            <>
              {additionalActions}
              <WithTooltip tip={isBusy ? "Please wait..." : undefined}>
                <Button color="accent" disabled={isBusy} onClick={() => void setPublished(true)}>
                  {isPublishing ? "Publishing..." : "Publish and continue"}
                </Button>
              </WithTooltip>
            </>
          )
        }
      >
        <Tabs style={{ gridColumn: 1 }}>
          <Tab
            asChild
            isSelected={currentTab === "product"}
            onClick={onTabClick}
          >
            <Link href={Routes.edit_bundles_product_path(bundleId)}>
              Product
            </Link>
          </Tab>
          <Tab
            asChild
            isSelected={currentTab === "content"}
            onClick={onTabClick}
          >
            <Link href={Routes.edit_bundles_content_path(bundleId)}>
              Content
            </Link>
          </Tab>
          <Tab
            asChild
            isSelected={currentTab === "share"}
            onClick={(evt: React.MouseEvent<HTMLAnchorElement>) => {
              onTabClick(evt, () => {
                if (!isPublished) {
                  evt.preventDefault();
                  showAlert(
                    "Not yet! You've got to publish your awesome product before you can share it with your audience and the world.",
                    "warning"
                  );
                }
              });
            }}
          >
            <Link href={Routes.edit_bundles_share_path(bundleId)}>
              Share
            </Link>
          </Tab>
        </Tabs>
      </PageHeader>
      {preview ? (
        <WithPreviewSidebar className="flex-1">
          {children}
          <PreviewSidebar
            previewLink={(props) => (
              <Button
                {...props}
                onClick={() => window.open(url)}
                disabled={isBusy}
              />
            )}
          >
            <Preview
              scaleFactor={0.4}
              style={{
                border: "var(--border)",
                backgroundColor: "rgb(var(--filled))",
              }}
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
