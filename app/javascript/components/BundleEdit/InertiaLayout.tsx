import { Link, router } from "@inertiajs/react";
import * as React from "react";

import { saveBundle } from "$app/data/bundle";
import { setProductPublished } from "$app/data/publish_product";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Bundle } from "$app/components/BundleEdit/state";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Preview } from "$app/components/Preview";
import { PreviewSidebar, WithPreviewSidebar } from "$app/components/PreviewSidebar";
import { showAlert } from "$app/components/server-components/Alert";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tab, Tabs } from "$app/components/ui/Tabs";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { WithTooltip } from "$app/components/WithTooltip";

export type BundleTab = "product" | "content" | "share";

type Props = {
  children: React.ReactNode;
  preview: React.ReactNode;
  currentTab: BundleTab;
  bundle: Bundle;
  id: string;
  uniquePermalink: string;
  onBundleChange: (update: Partial<Bundle>) => void;
  isLoading?: boolean;
};

export const useProductUrl = (bundle: Bundle, uniquePermalink: string, params = {}) => {
  const currentSeller = useCurrentSeller();
  const { appDomain } = useDomains();
  return Routes.short_link_url(bundle.custom_permalink ?? uniquePermalink, {
    host: currentSeller?.subdomain ?? appDomain,
    ...params,
  });
};

export const InertiaLayout = ({
  children,
  preview,
  currentTab,
  bundle,
  id,
  uniquePermalink,
  onBundleChange,
  isLoading = false,
}: Props) => {
  const url = useProductUrl(bundle, uniquePermalink);

  const isDesktop = useIsAboveBreakpoint("lg");

  const [isSaving, setIsSaving] = React.useState(false);
  const handleSave = async () => {
    try {
      setIsSaving(true);
      await saveBundle(id, bundle);
      showAlert("Changes saved!", "success");
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsSaving(false);
  };

  const [isPublishing, setIsPublishing] = React.useState(false);
  const setPublished = async (published: boolean) => {
    try {
      setIsPublishing(true);
      await saveBundle(id, bundle);
      await setProductPublished(uniquePermalink, published);
      onBundleChange({ is_published: published });
      showAlert(published ? "Published!" : "Unpublished!", "success");
      if (currentTab === "share") {
        router.visit(Routes.content_bundle_path(id));
      } else if (published) {
        router.visit(Routes.share_bundle_path(id));
      }
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
    setIsPublishing(false);
  };

  const isUploadingFiles = bundle.public_files.some(
    (f) => f.status?.type === "unsaved" && f.status.uploadStatus.type === "uploading",
  );
  const isUploadingFilesOrImages = isLoading || isUploadingFiles;
  const isBusy = isUploadingFilesOrImages || isSaving || isPublishing;
  const saveButtonTooltip = isUploadingFiles
    ? "Files are still uploading..."
    : isUploadingFilesOrImages
      ? "Images are still uploading..."
      : isBusy
        ? "Please wait..."
        : undefined;

  const saveButton = (
    <WithTooltip tip={saveButtonTooltip}>
      <Button color="primary" disabled={isBusy} onClick={asyncVoid(handleSave)}>
        {isSaving ? "Saving changes..." : "Save changes"}
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

  return (
    <>
      <PageHeader
        className="sticky-top"
        title={bundle.name || "Untitled"}
        actions={
          bundle.is_published ? (
            <>
              <Button disabled={isBusy} onClick={() => void setPublished(false)}>
                {isPublishing ? "Unpublishing..." : "Unpublish"}
              </Button>
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
          ) : currentTab === "product" ? (
            <Button
              color="primary"
              disabled={isBusy}
              onClick={() => void handleSave().then(() => router.visit(Routes.content_bundle_path(id)))}
            >
              {isSaving ? "Saving changes..." : "Save and continue"}
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
        <Tabs style={{ gridColumn: 1 }}>
          <Tab asChild isSelected={currentTab === "product"}>
            <Link href={Routes.bundle_path(id)} onClick={onTabClick}>
              Product
            </Link>
          </Tab>
          <Tab asChild isSelected={currentTab === "content"}>
            <Link href={Routes.content_bundle_path(id)} onClick={onTabClick}>
              Content
            </Link>
          </Tab>
          <Tab asChild isSelected={currentTab === "share"}>
            <Link
              href={Routes.share_bundle_path(id)}
              onClick={(evt: React.MouseEvent) => {
                onTabClick(evt, () => {
                  if (!bundle.is_published) {
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
      </PageHeader>
      {preview ? (
        <WithPreviewSidebar className="flex-1">
          {children}
          <PreviewSidebar
            previewLink={(props) => (
              <Button {...props} onClick={() => void handleSave().then(() => window.open(url))} disabled={isBusy} />
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
