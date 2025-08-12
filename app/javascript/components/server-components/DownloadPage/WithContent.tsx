import * as React from "react";
import { cast, createCast } from "ts-safe-cast";

import { getFolderArchiveDownloadUrl, getProductFileDownloadInfos } from "$app/data/products";
import { RichContent, RichContentPage } from "$app/parsers/richContent";
import { assertDefined } from "$app/utils/assert";
import FileUtils from "$app/utils/file";
import { request } from "$app/utils/request";
import { generatePageIcon } from "$app/utils/rich_content_page";
import { register } from "$app/utils/serverComponentUtil";

import { Button } from "$app/components/Button";
import { DiscordButton } from "$app/components/DiscordButton";
import { DownloadAllButton } from "$app/components/Download/DownloadAllButton";
import { FileItem, FileList as DownloadFileList, FolderItem } from "$app/components/Download/FileList";
import { OpenInAppButton } from "$app/components/Download/OpenInAppButton";
import { DownloadPagePostList, Post } from "$app/components/Download/PostList";
import {
  FileDownloadInfo,
  FilesAndFoldersDownloadInfoProvider,
  RichContentView,
} from "$app/components/Download/RichContent";
import { TranscodingNoticeModal } from "$app/components/Download/TranscodingNoticeModal";
import { Icon } from "$app/components/Icons";
import { Popover } from "$app/components/Popover";
import { FileEmbed } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { showAlert } from "$app/components/server-components/Alert";
import { LicenseKey } from "$app/components/TiptapExtensions/LicenseKey";
import { PostsProvider } from "$app/components/TiptapExtensions/Posts";
import { useAddThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRunOnce } from "$app/components/useRunOnce";
import { WithTooltip } from "$app/components/WithTooltip";

import { Layout, LayoutProps } from "./Layout";

const LATEST_MEDIA_LOCATIONS_FETCH_INTERVAL_IN_MS = 10_000;
const MISSING_AUDIO_DURATIONS_FETCH_INTERVAL_IN_MS = 5_000;
const MAX_AUDIO_IDS_PER_FETCH = 25;
const PAGE_ICON_LABEL: Record<string, string> = {
  "file-arrow-down": "Page has various types of files",
  "file-music": "Page has audio files",
  "file-play": "Page has videos",
  "file-text": "Page has no files",
  "outline-key": "Page has license key",
};

const ContentFilesContext = React.createContext<FileItem[] | null>(null);
const ContentFilesProvider = ContentFilesContext.Provider;
export const useContentFiles = () =>
  assertDefined(React.useContext(ContentFilesContext), "ContentFilesProvider is missing");

const IsMobileAppViewContext = React.createContext<boolean | null>(null);
export const IsMobileAppViewProvider = IsMobileAppViewContext.Provider;
export const useIsMobileAppView = () =>
  assertDefined(React.useContext(IsMobileAppViewContext), "IsMobileAppViewProvider is missing");

const PurchaseInfoContext = React.createContext<{
  purchaseId: string | null;
  redirectId: string;
  token: string;
} | null>(null);
export const PurchaseInfoProvider = PurchaseInfoContext.Provider;
export const usePurchaseInfo = () =>
  assertDefined(React.useContext(PurchaseInfoContext), "PurchaseInfoProvider is missing");

const MediaUrlsContext = React.createContext<
  [Record<string, string[]>, React.Dispatch<React.SetStateAction<Record<string, string[]>>>] | null
>(null);
export const MediaUrlsProvider = MediaUrlsContext.Provider;
export const useMediaUrls = () => assertDefined(React.useContext(MediaUrlsContext), "MediaUrlsProvider is missing");

export type PurchaseCustomField = {
  custom_field_id: string;
} & (
  | { type: "shortAnswer" | "longAnswer"; value: string }
  | { type: "fileUpload"; files: { name: string; size: number; extension: string }[] }
);
const PurchaseCustomFieldsContext = React.createContext<PurchaseCustomField[]>([]);
export const PurchaseCustomFieldsProvider = PurchaseCustomFieldsContext.Provider;
export const usePurchaseCustomFields = () =>
  assertDefined(React.useContext(PurchaseCustomFieldsContext), "PurchaseCustomFieldsProvider is missing");

export type License = {
  license_key: string;
  is_multiseat_license: boolean;
  seats: number;
};

const WithContent = ({
  content,
  product_has_third_party_analytics,
  ...props
}: LayoutProps & {
  content: {
    rich_content_pages: RichContentPage[] | null;
    license: License | null;
    content_items: (FileItem | FolderItem)[];
    posts: Post[];
    video_transcoding_info: { transcode_on_first_sale: boolean } | null;
    custom_receipt: string | null;
    discord: { connected: boolean } | null;
    ios_app_url: string;
    android_app_url: string;
    download_all_button: { files: { url: string; filename: string | null }[] } | null;
    community_chat_url: string | null;
  };
  product_has_third_party_analytics: boolean | null;
}) => {
  const url = new URL(useOriginalLocation());
  const addThirdPartyAnalytics = useAddThirdPartyAnalytics();
  const [contentFiles, setContentFiles] = React.useState(
    content.content_items.filter((item): item is FileItem => item.type === "file"),
  );
  const mediaUrlsValue = React.useState<Record<string, string[]>>({});
  const unprocessedAudioIds =
    content.rich_content_pages !== null && props.is_mobile_app_web_view
      ? contentFiles.flatMap((file) =>
          FileUtils.isAudioExtension(file.extension) && file.duration === null ? [file.id] : [],
        )
      : [];
  const missingAudioDurationsFetchIntevalRef = React.useRef<ReturnType<typeof setInterval>>();
  React.useEffect(() => {
    const fetchMissingAudioDurations = async () => {
      try {
        if (unprocessedAudioIds.length === 0) {
          clearInterval(missingAudioDurationsFetchIntevalRef.current);
          return;
        }

        const response = await request({
          url: Routes.url_redirect_audio_durations_path(props.token, {
            params: { file_ids: unprocessedAudioIds.slice(0, MAX_AUDIO_IDS_PER_FETCH) },
          }),
          method: "GET",
          accept: "json",
        });
        if (!response.ok) return;
        const durations = cast<Record<string, FileItem["duration"]>>(await response.json());
        if (Object.keys(durations).length === 0) return;
        setContentFiles((files) =>
          files.map((file) => {
            const duration = durations[file.id];
            return duration !== null && duration !== undefined ? { ...file, duration, content_length: duration } : file;
          }),
        );
      } catch (e) {
        // eslint-disable-next-line no-console
        console.error(e);
      }
    };

    missingAudioDurationsFetchIntevalRef.current = setInterval(() => {
      void fetchMissingAudioDurations();
    }, MISSING_AUDIO_DURATIONS_FETCH_INTERVAL_IN_MS);

    return () => {
      clearInterval(missingAudioDurationsFetchIntevalRef.current);
    };
  }, [unprocessedAudioIds.length]);

  const isFetchingLatestMediaLocationsRef = React.useRef(false);
  useRunOnce(() => {
    if (url.searchParams.get("receipt") === "true" && props.purchase?.email) {
      showAlert(`Your purchase was successful! We sent a receipt to ${props.purchase.email}.`, "success");
      url.searchParams.delete("receipt");
      window.history.replaceState(window.history.state, "", url.toString());

      if (product_has_third_party_analytics && props.purchase.product_permalink)
        addThirdPartyAnalytics({
          permalink: props.purchase.product_permalink,
          location: "receipt",
          purchaseId: props.purchase.id,
        });
    }

    const fetchLatestMediaLocations = async () => {
      if (isFetchingLatestMediaLocationsRef.current) return;

      isFetchingLatestMediaLocationsRef.current = true;
      try {
        const response = await request({
          url: Routes.url_redirect_latest_media_locations_path(props.token),
          method: "GET",
          accept: "json",
        });
        if (!response.ok) return;
        const latestMediaLocations = cast<Record<string, FileItem["latest_media_location"]>>(await response.json());
        if (Object.keys(latestMediaLocations).length === 0) return;
        setContentFiles((files) =>
          files.map((file) => ({ ...file, latest_media_location: latestMediaLocations[file.id] ?? null })),
        );
      } catch (e) {
        // eslint-disable-next-line no-console
        console.error(e);
      } finally {
        isFetchingLatestMediaLocationsRef.current = false;
      }
    };

    if (content.rich_content_pages != null && contentFiles.length > 0) {
      setInterval(() => {
        void fetchLatestMediaLocations();
      }, LATEST_MEDIA_LOCATIONS_FETCH_INTERVAL_IN_MS);
    }
  });
  const isDesktop = useIsAboveBreakpoint("lg");
  const pages = content.rich_content_pages ?? [];
  const [activePageIndex, setActivePageIndex] = React.useState(0);
  const activePage = pages[activePageIndex];
  const showPageList = pages.length > 1 || (pages.length === 1 && (pages[0]?.title ?? "").trim() !== "");
  const hasPreviousPage = activePageIndex > 0;
  const hasNextPage = activePageIndex < pages.length - 1;
  const downloadableFiles: FileDownloadInfo[] = [];
  for (const f of contentFiles) {
    if (f.download_url && !f.external_link_url)
      downloadableFiles.push({ id: f.id, url: f.download_url, size: f.file_size || 0 });
  }
  const downloadInfo = {
    downloadableFiles,
    pdfStampingEnabled: contentFiles.some((f) => f.pdf_stamp_enabled),
    isMobileAppWebView: props.is_mobile_app_web_view,
    getFolderArchive: (folderId: string) =>
      getFolderArchiveDownloadUrl(Routes.url_redirect_download_archive_path(props.token, { folder_id: folderId })),
    getDownloadUrlsForFiles: async (ids: string[]) =>
      getProductFileDownloadInfos(
        Routes.url_redirect_download_product_files_path(props.token, { product_file_ids: ids }),
      ),
    hasStreamable: (ids: string[]) =>
      contentFiles.some((f) => ids.includes(f.id) && FileUtils.isFileExtensionStreamable(f.extension)),
  };
  const postsContext = {
    posts: content.rich_content_pages
      ? content.posts.map((post) => ({
          id: post.id,
          name: post.name,
          date: { type: "date" as const, value: post.action_at },
          url: post.view_url,
        }))
      : [],
    total: content.rich_content_pages ? content.posts.length : 0,
  };

  const pageIcons = React.useMemo(
    () =>
      pages.map(({ description }) =>
        generatePageIcon({
          hasLicense: description ? nodeHasLicense(description) : false,
          fileIds: description ? findFileEmbeds(description) : [],
          allFiles: contentFiles,
        }),
      ),
    [pages],
  );
  const purchaseInfo = { purchaseId: props.purchase?.id ?? null, redirectId: props.redirect_id, token: props.token };

  return (
    <Layout
      {...props}
      headerActions={
        <>
          {props.purchase && content.discord ? (
            <DiscordButton purchaseId={props.purchase.id} connected={content.discord.connected} />
          ) : null}
          {content.community_chat_url ? (
            <a className="button accent" href={content.community_chat_url}>
              Community
            </a>
          ) : null}
          <OpenInAppButton iosAppUrl={content.ios_app_url} androidAppUrl={content.android_app_url} />
          {content.download_all_button ? (
            <DownloadAllButton
              zip_path={Routes.url_redirect_download_archive_path(props.token)}
              files={content.download_all_button.files}
            />
          ) : null}
        </>
      }
      pageList={
        showPageList && isDesktop ? (
          <div role="tablist" className="pagelist" aria-label="Table of Contents">
            {pages.map((page, index) => (
              <div
                key={page.page_id}
                role="tab"
                aria-selected={index === activePageIndex}
                onClick={() => setActivePageIndex(index)}
              >
                <Icon
                  name={pageIcons[index] ?? "file-text"}
                  aria-label={pageIcons[index] ? PAGE_ICON_LABEL[pageIcons[index]] : "file-text"}
                />
                <span className="content">{page.title ?? "Untitled"}</span>
              </div>
            ))}
          </div>
        ) : null
      }
    >
      {content.custom_receipt ? (
        <div className="rich-text" dangerouslySetInnerHTML={{ __html: content.custom_receipt }} />
      ) : null}
      <PurchaseInfoProvider value={purchaseInfo}>
        <MediaUrlsProvider value={mediaUrlsValue}>
          <IsMobileAppViewProvider value={props.is_mobile_app_web_view}>
            {content.rich_content_pages !== null ? (
              activePage ? (
                <ContentFilesProvider value={contentFiles}>
                  <FilesAndFoldersDownloadInfoProvider value={downloadInfo}>
                    <PostsProvider value={postsContext}>
                      <PurchaseCustomFieldsProvider value={props.purchase?.purchase_custom_fields ?? []}>
                        <RichContentView
                          key={activePage.page_id}
                          richContent={activePage.description}
                          saleInfo={
                            props.purchase
                              ? {
                                  sale_id: props.purchase.id,
                                  product_id: props.purchase.product_id,
                                  product_permalink: props.purchase.product_permalink,
                                }
                              : null
                          }
                          license={content.license}
                        />
                      </PurchaseCustomFieldsProvider>
                    </PostsProvider>
                  </FilesAndFoldersDownloadInfoProvider>
                </ContentFilesProvider>
              ) : null
            ) : content.content_items.length > 0 ? (
              <DownloadFileList content_items={content.content_items} />
            ) : null}
          </IsMobileAppViewProvider>
        </MediaUrlsProvider>
      </PurchaseInfoProvider>

      {showPageList ? (
        <div role="navigation" style={{ marginTop: "auto" }}>
          {isDesktop ? null : (
            <Popover
              aria-label="Table of Contents"
              position="top"
              trigger={
                <div className="button">
                  <Icon name="unordered-list" />
                </div>
              }
            >
              {(close) => (
                <div role="menu">
                  {pages.map((page, index) => (
                    <div
                      key={page.page_id}
                      role="menuitemradio"
                      aria-checked={index === activePageIndex}
                      onClick={() => {
                        setActivePageIndex(index);
                        close();
                      }}
                    >
                      <Icon
                        name={pageIcons[index] ?? "file-text"}
                        aria-label={pageIcons[index] ? PAGE_ICON_LABEL[pageIcons[index]] : "file-text"}
                      />
                      &ensp;
                      {page.title ?? "Untitled"}
                    </div>
                  ))}
                </div>
              )}
            </Popover>
          )}
          <WithTooltip position="top" tip={hasPreviousPage ? null : "No more pages"}>
            <Button disabled={!hasPreviousPage} onClick={() => setActivePageIndex(activePageIndex - 1)}>
              <Icon name="arrow-left" />
              Previous
            </Button>
          </WithTooltip>
          <WithTooltip position="top" tip={hasNextPage ? null : "No more pages"}>
            <Button disabled={!hasNextPage} onClick={() => setActivePageIndex(activePageIndex + 1)}>
              Next
              <Icon name="arrow-right" />
            </Button>
          </WithTooltip>
        </div>
      ) : null}

      {content.video_transcoding_info ? (
        <TranscodingNoticeModal transcodeOnFirstSale={content.video_transcoding_info.transcode_on_first_sale} />
      ) : null}

      {content.rich_content_pages === null && content.posts.length > 0 ? (
        <div className="paragraphs">
          <DownloadPagePostList posts={content.posts} />
        </div>
      ) : null}
    </Layout>
  );
};

const findFileEmbeds = (node: RichContent): string[] =>
  node.content?.flatMap((child) => {
    if (child.type === FileEmbed.name && child.attrs?.id) return cast(child.attrs.id);
    return findFileEmbeds(child);
  }) ?? [];

const COMMON_CONTAINER_NODE_TYPES = ["doc", "orderedList", "bulletList", "listItem", "blockquote"];
const nodeHasLicense = (node: RichContent) =>
  node.type === LicenseKey.name ||
  ((COMMON_CONTAINER_NODE_TYPES.includes(node.type ?? "") && node.content?.some(nodeHasLicense)) ?? false);

export default register({ component: WithContent, propParser: createCast() });
