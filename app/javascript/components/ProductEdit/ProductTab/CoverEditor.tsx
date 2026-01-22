import { DirectUpload } from "@rails/activestorage";
import classNames from "classnames";
import * as React from "react";
import { ReactSortable as Sortable } from "react-sortablejs";

import { CoverPayload, createCover, deleteCover } from "$app/data/covers";
import { AssetPreview } from "$app/parsers/product";
import FileUtils from "$app/utils/file";
import { between } from "$app/utils/math";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError } from "$app/utils/request";

import { Button, buttonVariants } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { Popover } from "$app/components/Popover";
import { Covers } from "$app/components/Product/Covers";
import { RemoveButton } from "$app/components/RemoveButton";
import { showAlert } from "$app/components/server-components/Alert";
import { Placeholder } from "$app/components/ui/Placeholder";
import { Tab, TabIcon, Tabs } from "$app/components/ui/Tabs";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { WithTooltip } from "$app/components/WithTooltip";
const MAX_PREVIEW_COUNT = 8;

const ALLOWED_EXTENSIONS = ["jpeg", "jpg", "png", "gif", "mov", "m4v", "mpeg", "mpg", "mp4", "wmv"];

export const CoverEditor = ({
  covers,
  setCovers,
  permalink,
}: {
  covers: AssetPreview[];
  setCovers: (covers: AssetPreview[]) => void;
  permalink: string;
}) => {
  const [activeCoverId, setActiveCoverId] = React.useState(covers[0]?.id ?? null);
  const [isUploaderOpen, setIsUploaderOpen] = React.useState(false);
  const [isUploading, setIsUploading] = React.useState(false);

  const canAddPreview = covers.length < MAX_PREVIEW_COUNT;

  const removeCover = async (id: string) => {
    try {
      const covers = await deleteCover(permalink, id);
      setCovers(covers);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    }
  };

  return (
    <section className="p-4! md:p-8!">
      <header>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          <h2>Ảnh bìa</h2>
          <a href="/help/article/60-adding-a-cover-image" target="_blank" rel="noreferrer">
            Tìm hiểu thêm
          </a>
        </div>
      </header>
      {covers.length === 0 ? (
        <Placeholder>
          <CoverUploader
            permalink={permalink}
            setCovers={setCovers}
            isUploading={isUploading}
            setIsUploading={setIsUploading}
          />
        </Placeholder>
      ) : (
        <div>
          <div
            style={{ display: "grid", gridTemplateColumns: "1fr auto", alignItems: "start", gap: "var(--spacer-4)" }}
          >
            <Sortable animation={150} tag={CoversTabList} list={covers} setList={setCovers}>
              {covers.map((cover) => (
                <CoverTab
                  key={cover.id}
                  cover={cover}
                  selected={activeCoverId === cover.id}
                  onClick={() => setActiveCoverId(cover.id)}
                  onRemove={() => void removeCover(cover.id)}
                />
              ))}
            </Sortable>

            <WithTooltip tip={canAddPreview ? null : "Đã tải lên số lượng ảnh xem trước tối đa"}>
              <Popover
                disabled={!canAddPreview || isUploading}
                aria-label="Thêm ảnh bìa"
                trigger={
                  <div className={buttonVariants({ size: "default" })}>
                    <Icon name="plus" />
                  </div>
                }
                open={isUploaderOpen}
                onToggle={(value) => {
                  if (canAddPreview && !isUploading) setIsUploaderOpen(value);
                }}
              >
                <div className="flex flex-col gap-4">
                  <CoverUploader
                    permalink={permalink}
                    setCovers={(covers) => {
                      setCovers(covers);
                      setIsUploaderOpen(false);
                    }}
                    isUploading={isUploading}
                    setIsUploading={setIsUploading}
                  />
                </div>
              </Popover>
            </WithTooltip>
          </div>
          <Covers covers={covers} activeCoverId={activeCoverId} setActiveCoverId={setActiveCoverId} />
        </div>
      )}
    </section>
  );
};

const CoverUploader = ({
  permalink,
  setCovers,
  isUploading,
  setIsUploading,
}: {
  permalink: string;
  setCovers: (covers: AssetPreview[]) => void;
  isUploading: boolean;
  setIsUploading: (isUploading: boolean) => void;
}) => {
  const [isSelecting, setIsSelecting] = React.useState(false);

  const [uploader, setUploader] = React.useState<{ type: "url"; value: string } | null>(null);

  const uid = React.useId();

  const saveCover = async (coverPayload: CoverPayload) => {
    try {
      setIsUploading(true);
      const covers = await createCover(permalink, coverPayload);
      setCovers(covers);
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
    } finally {
      setIsUploading(false);
    }
  };

  return isSelecting ? (
    isUploading ? (
      <LoadingSpinner className="size-20" />
    ) : (
      <div style={{ width: "100%" }}>
        <Tabs variant="buttons">
          <Tab isSelected={false} asChild className="items-center">
            <label>
              <input
                type="file"
                multiple
                accept={ALLOWED_EXTENSIONS.map((ext) => `.${ext}`).join(",")}
                disabled={isUploading}
                onChange={asyncVoid(async (event) => {
                  if (!event.target.files?.length) return;

                  for (const file of event.target.files) {
                    if (!FileUtils.isFileNameExtensionAllowed(file.name, ALLOWED_EXTENSIONS)) {
                      showAlert("Loại file không hợp lệ.", "error");
                      continue;
                    }
                    // TODO change the relevant endpoint(s) to allow uploading multiple files at once
                    await new Promise<void>((resolve) => {
                      new DirectUpload(file, Routes.rails_direct_uploads_path()).create((error, blob) => {
                        if (error) {
                          showAlert(error.message, "error");
                        } else {
                          void saveCover({ type: "file", signedBlobId: blob.signed_id }).finally(resolve);
                        }
                      });
                    });
                  }
                  setIsSelecting(false);
                })}
              />
              <TabIcon name="upload-fill" />
              File từ máy tính
            </label>
          </Tab>
          <Tab
            className="items-center"
            onClick={() =>
              setUploader((prevUploader) => (prevUploader?.type === "url" ? null : { type: "url", value: "" }))
            }
            isSelected={uploader?.type === "url"}
            aria-controls={`${uid}-url`}
          >
            <TabIcon name="link" />
            Liên kết ngoài
          </Tab>
        </Tabs>
        <fieldset
          role="tabpanel"
          className="mt-4 rounded-sm border border-border p-4"
          id={`${uid}-url`}
          hidden={uploader?.type !== "url"}
        >
          {uploader?.type === "url" ? (
            <div className="flex gap-2">
              <input
                type="url"
                placeholder="https://"
                value={uploader.value}
                onChange={(evt) => setUploader({ ...uploader, value: evt.target.value })}
              />
              <Button
                color="primary"
                onClick={() => {
                  void saveCover({ type: "url", url: uploader.value }).then(() => {
                    setIsSelecting(false);
                    setUploader(null);
                  });
                }}
                aria-label="Tải lên"
              >
                <Icon name="upload-fill" />
              </Button>
            </div>
          ) : null}
          <small>Chúng tôi hỗ trợ media từ các trang như YouTube, Vimeo và Soundcloud.</small>
        </fieldset>
      </div>
    )
  ) : (
    <>
      <Button color="primary" onClick={() => setIsSelecting(true)}>
        <Icon name="upload-fill" /> Tải ảnh hoặc video lên
      </Button>
      Ảnh nên là ảnh ngang, ít nhất 1280x720px và 72 DPI (chấm mỗi inch).
    </>
  );
};

const CoversTabList = React.forwardRef<HTMLDivElement, React.HTMLProps<HTMLDivElement>>((props, ref) => (
  <Tabs
    variant="buttons"
    aria-label="Ảnh bìa sản phẩm"
    {...props}
    className="-mt-3 !auto-cols-max grid-flow-col overflow-x-auto pt-3 pb-4 pl-1"
    ref={ref}
  >
    {props.children}
  </Tabs>
));
CoversTabList.displayName = "CoversTabList";

const CoverTab = ({
  cover,
  selected,
  onClick,
  onRemove,
}: {
  cover: AssetPreview;
  selected: boolean;
  onClick: () => void;
  onRemove: () => void;
}) => {
  const isDesktop = useIsAboveBreakpoint("lg");
  const [showDelete, setShowDelete] = React.useState(false);

  const hasThumbnail = cover.type !== "video" && (cover.type !== "oembed" || cover.thumbnail != null);

  return (
    <Tab
      isSelected={selected}
      onClick={onClick}
      className={classNames("relative cursor-move", { "p-0": hasThumbnail })}
      onMouseEnter={() => setShowDelete(true)}
      onMouseLeave={() => setShowDelete(false)}
    >
      {hasThumbnail ? (
        <img
          src={cover.thumbnail || cover.url}
          width={
            cover.width !== null && cover.height !== null
              ? calculateMiniatureWidth(cover.width, cover.height)
              : undefined
          }
        />
      ) : (
        <span>{cover.type === "oembed" ? "📺" : cover.type === "video" ? "📼" : "📦"}</span>
      )}

      {showDelete || !isDesktop ? (
        <RemoveButton
          onClick={(evt) => {
            evt.stopPropagation();
            onRemove();
          }}
          style={{ position: "absolute", top: 0, right: 0, transform: "translate(50%, -50%)" }}
          aria-label="Xóa ảnh bìa"
        />
      ) : null}
    </Tab>
  );
};

const MIN_ITEM_WIDTH = 60;
const MAX_ITEM_WIDTH = 76;
const ITEM_HEIGHT = 50;
const calculateMiniatureWidth = (contentWidth: number, contentHeight: number) => {
  // To calculate the width of the miniature, we will:
  // - calculate its width based on miniature row height and aspect ratio of the content
  // - multiply that by 1.1 to "widen" the miniature a little
  // - make sure the width is between MIN_ITEM_WIDTH and MAX_ITEM_WIDTH
  const ratio = contentWidth / contentHeight;
  const width = Math.round(ratio * ITEM_HEIGHT);
  return between(width * 1.1, MIN_ITEM_WIDTH, MAX_ITEM_WIDTH);
};
