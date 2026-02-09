import { Link, usePage } from "@inertiajs/react";
import * as React from "react";

import { getContrastColor, hexToRgb } from "$app/utils/color";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Preview } from "$app/components/Preview";
import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { PublicFileWithStatus } from "$app/components/ProductEdit/state";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tabs, Tab } from "$app/components/ui/Tabs";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { WithTooltip } from "$app/components/WithTooltip";

export const useProductUrl = (uniquePermalink: string, customPermalink?: string | null) => {
  const currentSeller = useCurrentSeller();
  const { appDomain, scheme } = useDomains();
  return Routes.short_link_url(customPermalink ?? uniquePermalink, {
    host: currentSeller?.subdomain ?? appDomain,
    protocol: scheme,
  });
};

const useCurrentTab = (): "product" | "content" | "share" => {
  const componentToTab: Record<string, "product" | "content" | "share"> = {
    "Bundles/Product/Edit": "product",
    "Bundles/Content/Edit": "content",
    "Bundles/Share/Edit": "share",
  };
  return componentToTab[usePage().component] ?? "product";
};

type BundleEditLayoutProps = {
  children: React.ReactNode;
  id: string;
  name?: string;
  customPermalink?: string | null;
  uniquePermalink?: string;
  isPublished: boolean;
  publicFiles?: PublicFileWithStatus[];
  preview?: React.ReactNode;
  isLoading?: boolean;
  isProcessing?: boolean;
  onSave?: () => void;
  onPublish?: () => void;
  onUnpublish?: () => void;
  onSaveAndContinue?: () => void;
  onPreview?: () => void;
  onBeforeNavigate?: (targetPath: string) => boolean;
};

export const BundleEditLayout = ({
  children,
  id,
  name = "Untitled",
  customPermalink,
  uniquePermalink = "",
  isPublished,
  publicFiles = [],
  preview,
  isLoading = false,
  isProcessing = false,
  onSave,
  onPublish,
  onUnpublish,
  onSaveAndContinue,
  onPreview,
  onBeforeNavigate,
}: BundleEditLayoutProps) => {
  const tab = useCurrentTab();
  const currentSeller = useCurrentSeller();

  const url = useProductUrl(uniquePermalink, customPermalink);

  const isDesktop = useIsAboveBreakpoint("lg");

  const isUploadingFiles = publicFiles.some(
    (f) => f.status?.type === "unsaved" && f.status.uploadStatus.type === "uploading",
  );
  const isUploadingFilesOrImages = isLoading || isUploadingFiles;
  const isBusy = isUploadingFilesOrImages || isProcessing;
  const saveButtonTooltip = isUploadingFiles
    ? "Files are still uploading..."
    : isUploadingFilesOrImages
      ? "Images are still uploading..."
      : isBusy
        ? "Please wait..."
        : undefined;

  const profileColors = currentSeller
    ? {
        "--accent": hexToRgb(currentSeller.profileHighlightColor),
        "--contrast-accent": hexToRgb(getContrastColor(currentSeller.profileHighlightColor)),
        "--filled": hexToRgb(currentSeller.profileBackgroundColor),
        "--color": hexToRgb(getContrastColor(currentSeller.profileBackgroundColor)),
      }
    : {};

  const fontUrl =
    currentSeller?.profileFont && currentSeller.profileFont !== "ABC Favorit"
      ? `https://fonts.googleapis.com/css2?family=${currentSeller.profileFont}:wght@400;600&display=swap`
      : null;

  const saveButton = onSave ? (
    <WithTooltip tip={saveButtonTooltip}>
      <Button color="primary" disabled={isBusy} onClick={onSave}>
        {isProcessing ? "Saving changes..." : "Save changes"}
      </Button>
    </WithTooltip>
  ) : null;

  const handleTabClick = (e: React.MouseEvent, targetPath: string) => {
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

    if (onBeforeNavigate?.(targetPath)) {
      e.preventDefault();
    }
  };

  return (
    <>
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
          ) : tab === "product" ? (
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
        <Tabs style={{ gridColumn: 1 }}>
          <Tab asChild isSelected={tab === "product"}>
            <Link
              href={Routes.edit_bundle_product_path(id)}
              onClick={(e) => handleTabClick(e, Routes.edit_bundle_product_path(id))}
            >
              Product
            </Link>
          </Tab>
          <Tab asChild isSelected={tab === "content"}>
            <Link
              href={Routes.edit_bundle_content_path(id)}
              onClick={(e) => handleTabClick(e, Routes.edit_bundle_content_path(id))}
            >
              Content
            </Link>
          </Tab>
          <Tab asChild isSelected={tab === "share"}>
            <Link
              href={Routes.edit_bundle_share_path(id)}
              onClick={(e) => handleTabClick(e, Routes.edit_bundle_share_path(id))}
            >
              Share
            </Link>
          </Tab>
        </Tabs>
      </PageHeader>
      {preview ? (
        <WithPreviewSidebar className="flex-1">
          {children}
          <PreviewSidebar previewLink={(props) => <Button {...props} onClick={onPreview} disabled={isBusy} />}>
            <Preview
              scaleFactor={0.4}
              style={{
                border: "var(--border)",
                borderRadius: "var(--border-radius-2)",
                fontFamily: currentSeller?.profileFont === "ABC Favorit" ? undefined : currentSeller?.profileFont,
                ...profileColors,
                "--primary": "var(--color)",
                "--body-bg": "rgb(var(--filled))",
                "--contrast-primary": "var(--filled)",
                "--contrast-filled": "var(--color)",
                "--color-body": "var(--body-bg)",
                "--color-background": "rgb(var(--filled))",
                "--color-foreground": "rgb(var(--color))",
                "--color-border": "rgb(var(--color) / var(--border-alpha))",
                "--color-accent": "rgb(var(--accent))",
                "--color-accent-foreground": "rgb(var(--contrast-accent))",
                "--color-primary": "rgb(var(--primary))",
                "--color-primary-foreground": "rgb(var(--contrast-primary))",
                "--color-active-bg": "rgb(var(--color) / var(--gray-1))",
                "--color-muted": "rgb(var(--color) / var(--gray-3))",
                backgroundColor: "rgb(var(--filled))",
                color: "rgb(var(--color))",
              }}
            >
              {fontUrl ? (
                <>
                  <link rel="preconnect" href="https://fonts.googleapis.com" crossOrigin="anonymous" />
                  <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
                  <link rel="stylesheet" href={fontUrl} />
                </>
              ) : null}
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
