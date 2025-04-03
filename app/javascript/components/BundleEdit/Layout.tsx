import * as React from "react";
import { Link, useMatches, useNavigate } from "react-router-dom";

import { saveBundle } from "$app/data/bundle";
import { setProductPublished } from "$app/data/publish_product";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { useBundleEditContext } from "$app/components/BundleEdit/state";
import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useCurrentSeller } from "$app/components/CurrentSeller";
import { useDomains } from "$app/components/DomainSettings";
import { Icon } from "$app/components/Icons";
import { Preview } from "$app/components/Preview";
import { showAlert } from "$app/components/server-components/Alert";
import { WithTooltip } from "$app/components/WithTooltip";

export const useProductUrl = (params = {}) => {
  const { bundle, uniquePermalink } = useBundleEditContext();
  const currentSeller = useCurrentSeller();
  const { appDomain } = useDomains();
  return Routes.short_link_url(bundle.custom_permalink ?? uniquePermalink, {
    host: currentSeller?.subdomain ?? appDomain,
    ...params,
  });
};

export const Layout = ({
  children,
  preview,
  isLoading = false,
}: {
  children: React.ReactNode;
  preview: React.ReactNode;
  isLoading?: boolean;
}) => {
  const { bundle, updateBundle, id, uniquePermalink } = useBundleEditContext();

  const url = useProductUrl();

  const [match] = useMatches();
  const tab = match?.handle ?? "product";

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
      updateBundle({ is_published: published });
      showAlert(published ? "Published!" : "Unpublished!", "success");
      if (tab === "share") navigate(`/bundles/${id}/content`);
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

  const navigate = useNavigate();

  const saveButton = (
    <Button color="primary" disabled={isBusy} onClick={asyncVoid(handleSave)}>
      {isSaving ? "Saving changes..." : "Save changes"}
    </Button>
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

  return (
    <>
      <header className="sticky-top">
        <h1>{bundle.name}</h1>
        <div className="actions">
          {bundle.is_published ? (
            <>
              <Button disabled={isBusy} onClick={() => void setPublished(false)}>
                {isPublishing ? "Unpublishing..." : "Unpublish"}
              </Button>
              {saveButton}
              <CopyToClipboard text={url}>
                <Button>
                  <Icon name="link" />
                </Button>
              </CopyToClipboard>
            </>
          ) : tab === "product" ? (
            <Button
              color="primary"
              disabled={isBusy}
              onClick={() => void handleSave().then(() => navigate(`/bundles/${id}/content`))}
            >
              {isSaving ? "Saving changes..." : "Save and continue"}
            </Button>
          ) : (
            <>
              {saveButton}
              <Button
                color="accent"
                disabled={isBusy}
                onClick={() => void setPublished(true).then(() => navigate(`/bundles/${id}/share`))}
              >
                {isPublishing ? "Publishing..." : "Publish and continue"}
              </Button>
            </>
          )}
        </div>
        <div role="tablist">
          <Link to={`/bundles/${id}`} role="tab" aria-selected={tab === "product"} onClick={onTabClick}>
            Product
          </Link>
          <Link to={`/bundles/${id}/content`} role="tab" aria-selected={tab === "content"} onClick={onTabClick}>
            Content
          </Link>
          <Link
            to={`/bundles/${id}/share`}
            role="tab"
            aria-selected={tab === "share"}
            onClick={(evt) => {
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
        </div>
      </header>
      <main className="squished">{children}</main>
      <aside aria-label="Preview">
        <header>
          <h2>Preview</h2>
          <WithTooltip tip="Preview">
            <Button
              onClick={() => void handleSave().then(() => window.open(url))}
              disabled={isBusy}
              aria-label="Preview"
            >
              <Icon name="arrow-diagonal-up-right" />
            </Button>
          </WithTooltip>
        </header>
        <Preview
          scaleFactor={0.4}
          style={{ border: "var(--border)", backgroundColor: "var(--body-bg)", borderRadius: "var(--border-radius-2)" }}
        >
          {preview}
        </Preview>
      </aside>
    </>
  );
};
