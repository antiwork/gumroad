import { DotsHorizontalRounded } from "@boxicons/react";
import * as React from "react";

import { getProductBuilds, promoteProductBuild, ProductBuild } from "$app/data/product_builds";
import { deployedAgo } from "$app/utils/date";
import FileUtils from "$app/utils/file";

import { Button } from "$app/components/Button";
import { CopyToClipboard } from "$app/components/CopyToClipboard";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Modal } from "$app/components/Modal";
import { Popover, PopoverClose, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { filesAreUploading, useProductEditContext } from "$app/components/ProductEdit/state";
import { useImageUploadSettings } from "$app/components/RichTextEditor";
import { showAlert } from "$app/components/server-components/Alert";
import CodeSnippet from "$app/components/ui/CodeSnippet";
import { InlineList } from "$app/components/ui/InlineList";
import { LinkButton } from "$app/components/ui/LinkButton";
import { Menu, MenuItem } from "$app/components/ui/Menu";
import { Pill } from "$app/components/ui/Pill";
import { Row, RowActions, RowContent, Rows } from "$app/components/ui/Rows";
import { Sheet, SheetHeader } from "$app/components/ui/Sheet";

// Earlier versions shown before "Show all"; rollback almost always goes to one of the last few.
const EARLIER_BUILDS_SHOWN = 10;

const VersionRow = ({ build, children }: { build: ProductBuild; children?: React.ReactNode }) => {
  const live = build.status === "live";
  return (
    <Row role="listitem" className="grid-cols-[1fr_auto]">
      <RowContent>
        <div>
          <h4 className="flex items-center gap-2">
            Version {build.number}
            {live ? (
              <Pill size="small" color="primary">
                Live
              </Pill>
            ) : null}
          </h4>
          <InlineList>
            <li>Deployed {deployedAgo(build.created_at)}</li>
            {live ? <li>{FileUtils.getFullFileSizeString(build.byte_size)}</li> : null}
            {live ? <li>Buyers get this version</li> : null}
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
  const { uniquePermalink, save, product } = useProductEditContext();
  // The save before promoting would send files whose upload has not finished, and the reload after it
  // would cut the upload off.
  const imageSettings = useImageUploadSettings();
  const uploading = filesAreUploading(product) || !!imageSettings?.isUploading;
  const [open, setOpen] = React.useState(false);
  const [builds, setBuilds] = React.useState<ProductBuild[] | null>(null);
  const [showAll, setShowAll] = React.useState(false);
  const [confirming, setConfirming] = React.useState<ProductBuild | null>(null);
  const [promoting, setPromoting] = React.useState(false);
  const uid = React.useId();

  const show = async () => {
    setOpen(true);
    setBuilds(null);
    setShowAll(false);
    try {
      setBuilds(await getProductBuilds(uniquePermalink));
    } catch {
      setOpen(false);
      showAlert("Sorry, the version history could not be loaded. Please try again.", "error");
    }
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
      showAlert(`Sorry, version ${build.number} could not be made live. Please try again.`, "error");
    }
  };

  const live = builds?.find((build) => build.status === "live");
  // Deployed after the live one and never made live: what the seller most likely came here to publish.
  const ready = builds?.filter((build) => build.status === "uploaded" && build.number > (live?.number ?? 0)) ?? [];
  const earlier = builds?.filter((build) => build !== live && !ready.includes(build)) ?? [];
  const shownEarlier = showAll ? earlier : earlier.slice(0, EARLIER_BUILDS_SHOWN);
  const deployCommand = `gumroad builds deploy ./my-game --product ${uniquePermalink}`;

  return (
    <>
      <Button onClick={() => void show()}>History</Button>
      <Sheet open={open} onOpenChange={(next) => setOpen(next || promoting)} modal>
        <SheetHeader>Version history</SheetHeader>
        {builds ? (
          <>
            {live ? (
              <section aria-label="Live version">
                <Rows role="list">
                  <VersionRow build={live} />
                </Rows>
              </section>
            ) : null}
            {ready.length > 0 ? (
              <section aria-labelledby={`${uid}-ready`} className="grid gap-2">
                <h3 id={`${uid}-ready`}>Ready to go live</h3>
                <Rows role="list">
                  {ready.map((build) => (
                    <VersionRow key={build.id} build={build}>
                      <Button size="sm" color="primary" onClick={() => setConfirming(build)}>
                        Make live
                      </Button>
                    </VersionRow>
                  ))}
                </Rows>
              </section>
            ) : null}
            {earlier.length > 0 ? (
              <section aria-labelledby={`${uid}-earlier`} className="grid gap-2">
                <h3 id={`${uid}-earlier`}>Earlier versions</h3>
                <Rows role="list">
                  {shownEarlier.map((build) => (
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
                  ))}
                </Rows>
                {shownEarlier.length < earlier.length ? (
                  <LinkButton onClick={() => setShowAll(true)}>Show all {earlier.length} earlier versions</LinkButton>
                ) : null}
              </section>
            ) : null}
            <section aria-labelledby={`${uid}-add`} className="grid gap-2">
              <h3 id={`${uid}-add`}>Add a new version</h3>
              <p>Deploy it with the Gumroad CLI, or ask your AI coding assistant to do it:</p>
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
              <p>
                Buyers keep the live version until you make the new one live.{" "}
                <a href={`${Routes.api_path()}#api-cli`} target="_blank" rel="noopener noreferrer">
                  Get the Gumroad CLI
                </a>
              </p>
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
          title={`Make version ${confirming.number} live?`}
          footer={
            <>
              <Button disabled={promoting} onClick={() => setConfirming(null)}>
                Cancel
              </Button>
              <Button color="primary" disabled={promoting || uploading} onClick={() => void makeLive(confirming)}>
                {promoting ? "Making live..." : `Make version ${confirming.number} live`}
              </Button>
            </>
          }
        >
          <p>
            Buyers get version {confirming.number} the next time they open it. You can switch back at any time. Your
            unsaved edits are saved first.
          </p>
          {uploading ? <p>Wait for your files to finish uploading to make another version live.</p> : null}
        </Modal>
      ) : null}
    </>
  );
};
