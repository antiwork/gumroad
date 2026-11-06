import { DotsHorizontalRounded } from "@boxicons/react";
import * as React from "react";

import { createProductBuild, getProductBuilds, promoteProductBuild, ProductBuild } from "$app/data/product_builds";
import { deployedAgo } from "$app/utils/date";
import FileUtils from "$app/utils/file";
import GuidGenerator from "$app/utils/guid_generator";
import { ResponseError } from "$app/utils/request";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { useEvaporateUploader } from "$app/components/EvaporateUploader";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { Popover, PopoverClose, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { filesAreUploading, hasLiveBuildFile, useProductEditContext } from "$app/components/ProductEdit/state";
import { useImageUploadSettings } from "$app/components/RichTextEditor";
import { useS3UploadConfig } from "$app/components/S3UploadConfig";
import { showAlert } from "$app/components/server-components/Alert";
import CodeSnippet from "$app/components/ui/CodeSnippet";
import { InlineList } from "$app/components/ui/InlineList";
import { Input } from "$app/components/ui/Input";
import { LinkButton } from "$app/components/ui/LinkButton";
import { Menu, MenuItem } from "$app/components/ui/Menu";
import { Pill } from "$app/components/ui/Pill";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";

// Earlier versions shown before "Show all"; rollback almost always goes to one of the last few.
const EARLIER_BUILDS_SHOWN = 10;
// ProductBuild::MAX_BYTE_SIZE; the server checks it too, this only saves a doomed upload.
const MAX_WEB_APP_ZIP_BYTES = 2 * 1024 * 1024 * 1024;

// One line for the title and one for the details, cut short when narrow: the upload's row and the version
// that replaces it are then the same height, so the rows below never move.
const VERSION_ROW_CLASS = "grid-cols-[minmax(0,1fr)_auto]";

const VersionRow = ({
  build,
  ready,
  children,
}: {
  build: ProductBuild;
  ready?: boolean;
  children?: React.ReactNode;
}) => {
  const live = build.status === "live";
  return (
    <Row role="listitem" aria-label={`Version ${build.number}`} className={VERSION_ROW_CLASS}>
      <RowContent>
        <div className="min-w-0">
          <h4 className="flex items-center gap-2">
            Version {build.number}
            {live ? (
              <Pill size="small" color="primary">
                Live
              </Pill>
            ) : null}
          </h4>
          {/* The status comes first, so a narrow row cuts off the date, never the status. */}
          <InlineList className="truncate">
            {live ? <li>Buyers get this version</li> : ready ? <li>Not live yet</li> : null}
            <li>Added {deployedAgo(build.created_at)}</li>
            {build.unpack_error ? <li className="text-danger">{build.unpack_error}</li> : null}
            {live ? <li>{FileUtils.getFullFileSizeString(build.byte_size)}</li> : null}
          </InlineList>
        </div>
      </RowContent>
      {children ? <RowActions>{children}</RowActions> : null}
    </Row>
  );
};

// Builds are called versions for sellers. Making one live saves the editor first: promoting rewrites the
// product's content on the server, and the page reloads to show it.
export const VersionHistoryButton = () => {
  const [open, setOpen] = React.useState(false);
  return (
    <>
      <Button onClick={() => setOpen(true)}>History</Button>
      <VersionHistory open={open} onOpenChange={setOpen} />
    </>
  );
};

export const VersionHistory = ({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) => {
  const { uniquePermalink, save, product, setWebAppUploading } = useProductEditContext();
  // The save before promoting would send files whose upload has not finished, and the reload after it
  // would cut the upload off.
  const imageSettings = useImageUploadSettings();
  // null while no zip is uploading; percent is null once the upload is done and the server records the version.
  const [zipUpload, setZipUpload] = React.useState<{ key: string; name: string; percent: number | null } | null>(null);
  const uploading = filesAreUploading(product) || !!imageSettings?.isUploading || zipUpload !== null;
  const [builds, setBuilds] = React.useState<ProductBuild[] | null>(null);
  const [showAll, setShowAll] = React.useState(false);
  const [confirming, setConfirming] = React.useState<ProductBuild | null>(null);
  const [promoting, setPromoting] = React.useState(false);
  // The new version replaces the upload's row in place; this tells screen readers what that row now is.
  const [addedNumber, setAddedNumber] = React.useState<number | null>(null);
  const zipInputRef = React.useRef<HTMLInputElement>(null);
  const uploader = useEvaporateUploader();
  const s3UploadConfig = useS3UploadConfig();

  React.useEffect(() => {
    if (!open) return;
    let cancelled = false;
    setBuilds(null);
    setShowAll(false);
    setAddedNumber(null);
    getProductBuilds(uniquePermalink).then(
      (loaded) => {
        if (!cancelled) setBuilds(loaded);
      },
      () => {
        if (cancelled) return;
        onOpenChange(false);
        showAlert("Sorry, the version history could not be loaded. Please try again.", "error");
      },
    );
    return () => {
      cancelled = true;
    };
  }, [open, uniquePermalink]);

  // The layout keeps the seller on the page while this is set: leaving cuts the upload off, and leaving
  // the Content tab unmounts its progress and Cancel.
  React.useEffect(() => {
    if (!zipUpload) return;
    setWebAppUploading(true);
    return () => setWebAppUploading(false);
  }, [zipUpload !== null]);

  // The picked file stays in the input until its upload ends: Chromium can drop a file's data once the
  // input that picked it is reset.
  const finishZipUpload = () => {
    setZipUpload(null);
    if (zipInputRef.current) zipInputRef.current.value = "";
  };

  const uploadZip = (file: File) => {
    if (!uploader) return;
    if (!file.name.toLowerCase().endsWith(".zip")) {
      finishZipUpload();
      showAlert("Choose a .zip file of your web app.", "error");
      return;
    }
    if (file.size > MAX_WEB_APP_ZIP_BYTES) {
      finishZipUpload();
      showAlert("A web app's zip can be up to 2 GB.", "error");
      return;
    }
    const key = `web_app_${GuidGenerator.generate()}`;
    const { s3key, fileUrl } = s3UploadConfig.generateS3KeyForUpload(key, file.name);
    setZipUpload({ key, name: file.name, percent: 0 });
    setAddedNumber(null);
    uploader.scheduleUpload({
      cancellationKey: key,
      name: s3key,
      file,
      mimeType: "application/zip",
      onProgress: ({ percent }) => setZipUpload({ key, name: file.name, percent }),
      onComplete: () => {
        setZipUpload({ key, name: file.name, percent: null });
        createProductBuild(uniquePermalink, fileUrl).then(
          (added) => {
            // The list is newest first, and adding a version changes no other one. The version takes the
            // upload's row in the same render, so the list does not move.
            setBuilds((current) => current && [added, ...current]);
            setAddedNumber(added.number);
            finishZipUpload();
          },
          (error: unknown) => {
            finishZipUpload();
            showAlert(
              error instanceof ResponseError ? error.message : "Sorry, the version could not be added.",
              "error",
            );
          },
        );
      },
      onError: () => {
        finishZipUpload();
        showAlert("Sorry, the upload failed. Please try again.", "error");
      },
    });
  };

  const makeLive = async (build: ProductBuild) => {
    setPromoting(true);
    try {
      if (!(await save())) {
        setPromoting(false);
        return;
      }
      await promoteProductBuild(uniquePermalink, build.id);
      // Stays locked through the reload: an edit made while the page unloads would be lost.
      window.location.reload();
    } catch {
      setPromoting(false);
      showAlert(`Sorry, version ${build.number} could not be saved. Please try again.`, "error");
    }
  };

  const live = builds?.find((build) => build.status === "live");
  // Added after the live one and never made live: what the seller most likely came here to publish.
  const ready = builds?.filter((build) => build.status === "uploaded" && build.number > (live?.number ?? 0)) ?? [];
  const earlier = builds?.filter((build) => build !== live && !ready.includes(build)) ?? [];
  const shownEarlier = showAll ? earlier : earlier.slice(0, EARLIER_BUILDS_SHOWN);
  // Newest first: versions not live yet, then the live one, then earlier ones.
  const shown = builds?.filter((build) => !earlier.includes(build) || shownEarlier.includes(build)) ?? [];
  const deployCommand = `gumroad builds deploy ./my-web-app --product ${uniquePermalink}`;

  return (
    <>
      <Sheet open={open} onOpenChange={(next) => onOpenChange(next || promoting || zipUpload !== null)} modal>
        <SheetHeader>{builds?.length === 0 ? "Add a web app" : "Version history"}</SheetHeader>
        {builds ? (
          <>
            <section aria-label={builds.length > 0 ? "Add a new version" : "Add a web app"} className="grid gap-3">
              <p>
                Upload a zip of your web app. Put index.html at the top level of the zip, not inside a folder.{" "}
                {live
                  ? "Buyers keep the live version until you make the new one live."
                  : "Buyers get it once you make it live."}
              </p>
              <div>
                {/* Stays in place while uploading, so nothing below it moves: the progress is the new row. */}
                <Button disabled={!uploader || zipUpload !== null} onClick={() => zipInputRef.current?.click()}>
                  Upload a zip
                </Button>
              </div>
              <Input
                ref={zipInputRef}
                type="file"
                accept=".zip,application/zip"
                // Important: Input's padding and width would otherwise win over sr-only.
                className="sr-only!"
                tabIndex={-1}
                aria-label="Web app zip"
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  if (file) uploadZip(file);
                }}
              />
              {/* The upload's row shows its progress; this says the same to screen readers. */}
              <span role="status" className="sr-only">
                {zipUpload
                  ? zipUpload.percent === null
                    ? "Adding the new version..."
                    : `Uploading ${zipUpload.name}: ${Math.round(zipUpload.percent * 100)}%`
                  : addedNumber !== null
                    ? `Version ${addedNumber} is ready to go live.`
                    : null}
              </span>
            </section>
            {zipUpload || builds.length > 0 ? (
              <section aria-label="Versions" className="grid gap-2">
                <Rows role="list">
                  {zipUpload ? (
                    <Row role="listitem" className={VERSION_ROW_CLASS}>
                      <RowContent>
                        <div className="min-w-0">
                          <h4 className="truncate">Uploading {zipUpload.name}</h4>
                          <InlineList className="truncate">
                            <li>
                              {zipUpload.percent === null
                                ? "Adding the new version..."
                                : `${Math.round(zipUpload.percent * 100)}%`}
                            </li>
                          </InlineList>
                        </div>
                      </RowContent>
                      <RowActions>
                        <Button
                          size="sm"
                          disabled={zipUpload.percent === null}
                          onClick={() => {
                            uploader?.cancelUpload(zipUpload.key);
                            finishZipUpload();
                          }}
                        >
                          Cancel
                        </Button>
                      </RowActions>
                    </Row>
                  ) : null}
                  {shown.map((build) =>
                    build === live ? (
                      <VersionRow key={build.id} build={build}>
                        {/* Making the live version live again puts its row back in the content. */}
                        {hasLiveBuildFile(product) ? null : (
                          <Button size="sm" onClick={() => setConfirming(build)}>
                            Add to content
                          </Button>
                        )}
                      </VersionRow>
                    ) : ready.includes(build) ? (
                      <VersionRow key={build.id} build={build} ready>
                        {/* Only the newest is filled: it is the one the seller most likely came to publish. */}
                        <Button
                          size="sm"
                          color={build === ready[0] ? "primary" : undefined}
                          onClick={() => setConfirming(build)}
                        >
                          Make live
                        </Button>
                      </VersionRow>
                    ) : (
                      <VersionRow key={build.id} build={build}>
                        <Popover>
                          <PopoverTrigger aria-label={`Actions for version ${build.number}`} asChild>
                            <Button size="sm">
                              <DotsHorizontalRounded className="size-4" />
                            </Button>
                          </PopoverTrigger>
                          <PopoverContent sideOffset={4} className="border-0 p-0 shadow-none">
                            <Menu>
                              <PopoverClose asChild>
                                <MenuItem onClick={() => setConfirming(build)}>Make live</MenuItem>
                              </PopoverClose>
                            </Menu>
                          </PopoverContent>
                        </Popover>
                      </VersionRow>
                    ),
                  )}
                </Rows>
                {shown.length < builds.length ? (
                  <LinkButton onClick={() => setShowAll(true)}>Show all {builds.length} versions</LinkButton>
                ) : null}
              </section>
            ) : null}
            <section aria-label="Deploy from the command line" className="grid gap-2 text-muted">
              <p>
                Or deploy it with the{" "}
                <a href={`${Routes.api_path()}#api-cli`} target="_blank" rel="noopener noreferrer">
                  Gumroad CLI
                </a>
                , or ask your AI coding assistant to do it:
              </p>
              <div className="flex items-center gap-2">
                <div className="min-w-0 grow">
                  <CodeSnippet>{deployCommand}</CodeSnippet>
                </div>
                <div className="shrink-0">
                  <CopyToClipboard text={deployCommand} copyTooltip="Copy command">
                    <Button size="sm">Copy</Button>
                  </CopyToClipboard>
                </div>
              </div>
            </section>
          </>
        ) : (
          <div className="flex justify-center">
            <LoadingSpinner className="size-8" />
          </div>
        )}
      </Sheet>
      {confirming ? (
        <Modal
          open
          onClose={() => {
            if (!promoting) setConfirming(null);
          }}
          allowClose={!promoting}
          title={
            confirming.status === "live"
              ? `Add version ${confirming.number} back to the content?`
              : `Make version ${confirming.number} live?`
          }
          footer={
            <>
              <Button disabled={promoting} onClick={() => setConfirming(null)}>
                Cancel
              </Button>
              <Button color="primary" disabled={promoting || uploading} onClick={() => void makeLive(confirming)}>
                {promoting
                  ? "Saving..."
                  : confirming.status === "live"
                    ? "Add to content"
                    : `Make version ${confirming.number} live`}
              </Button>
            </>
          }
        >
          <p>
            {confirming.status === "live"
              ? "Buyers get it again the next time they open this product."
              : `Buyers get version ${confirming.number} the next time they open it. You can switch back at any time.`}{" "}
            Your unsaved edits are saved first.
          </p>
          {uploading ? <p>Wait for your files to finish uploading.</p> : null}
        </Modal>
      ) : null}
    </>
  );
};
