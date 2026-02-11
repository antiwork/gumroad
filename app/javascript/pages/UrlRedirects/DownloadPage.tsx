import { Head, usePage, usePoll } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { getFolderArchiveDownloadUrl, getProductFileDownloadInfos, saveLastContentPage } from "$app/data/products";
import { RichContent, RichContentPage } from "$app/parsers/richContent";
import FileUtils from "$app/utils/file";
import { generatePageIcon } from "$app/utils/rich_content_page";

import { Button } from "$app/components/Button";
import { DiscordButton } from "$app/components/DiscordButton";
import { DownloadAllButton } from "$app/components/Download/DownloadAllButton";
import { FileList as DownloadFileList, FileItem, FolderItem } from "$app/components/Download/FileList";
import { OpenInAppButton } from "$app/components/Download/OpenInAppButton";
import { PageList, PageListItem } from "$app/components/Download/PageListLayout";
import { DownloadPagePostList, Post } from "$app/components/Download/PostList";
import {
  FileDownloadInfo,
  FilesAndFoldersDownloadInfoProvider,
  RichContentView,
} from "$app/components/Download/RichContent";
import { TranscodingNoticeModal } from "$app/components/Download/TranscodingNoticeModal";
import { Icon } from "$app/components/Icons";
import { Popover, PopoverAnchor, PopoverClose, PopoverContent, PopoverTrigger } from "$app/components/Popover";
import { FileEmbed } from "$app/components/ProductEdit/ContentTab/FileEmbed";
import { showAlert } from "$app/components/server-components/Alert";
import {
  ContentFilesProvider,
  IsMobileAppViewProvider,
  License,
  MediaUrlsProvider,
  PurchaseCustomFieldsProvider,
  PurchaseInfoProvider,
} from "$app/components/server-components/DownloadPage/WithContent";
import { Layout, LayoutProps } from "$app/components/server-components/DownloadPage/Layout";
import { LicenseKey } from "$app/components/TiptapExtensions/LicenseKey";
import { PostsProvider } from "$app/components/TiptapExtensions/Posts";
import { useAddThirdPartyAnalytics } from "$app/components/useAddThirdPartyAnalytics";
import { useIsAboveBreakpoint } from "$app/components/useIsAboveBreakpoint";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRunOnce } from "$app/components/useRunOnce";
import { WithTooltip } from "$app/components/WithTooltip";

const DROPBOX_SCRIPT_URL = "https://www.dropbox.com/static/api/2/dropins.js";

const PAGE_ICON_LABEL: Record<string, string> = {
  "file-arrow-down": "Page has various types of files",
  "file-music": "Page has audio files",
  "file-play": "Page has videos",
  "file-text": "Page has no files",
  "outline-key": "Page has license key",
};

type PageProps = LayoutProps & {
  content: {
    rich_content_pages: RichContentPage[] | null;
    last_content_page_id: string | null;
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
  dropbox_app_key: string;
  ios_app_id: string;
  download_page_url: string;
  audio_durations: Record<string, number | null> | null;
  latest_media_locations: Record<string, FileItem["latest_media_location"]> | null;
};

const useDropboxScript = (appKey: string) => {
  React.useEffect(() => {
    if (document.getElementById("dropboxjs")) return;

    const script = document.createElement("script");
    script.id = "dropboxjs";
    script.src = DROPBOX_SCRIPT_URL;
    script.setAttribute("data-app-key", appKey);
    script.async = true;
    document.body.appendChild(script);
  }, [appKey]);
};

function DownloadPage() {
  const {
    content,
    product_has_third_party_analytics,
    dropbox_app_key,
    ios_app_id,
    download_page_url,
    audio_durations,
    latest_media_locations,
    ...layoutProps
  } = cast<PageProps>(usePage().props);

  useDropboxScript(dropbox_app_key);

  const contentFiles = React.useMemo(() => {
    const files = content.content_items.filter((item): item is FileItem => item.type === "file");
    return files.map((file) => ({
      ...file,
      ...(audio_durations?.[file.id] != null
        ? { duration: audio_durations[file.id], content_length: audio_durations[file.id] }
        : {}),
      ...(latest_media_locations?.[file.id] !== undefined
        ? { latest_media_location: latest_media_locations[file.id] }
        : {}),
    }));
  }, [content.content_items, audio_durations, latest_media_locations]);

  const mediaUrlsValue = React.useState<Record<string, string[]>>({});

  const hasRichContent = content.rich_content_pages !== null;
  const hasUnprocessedAudio =
    hasRichContent &&
    layoutProps.is_mobile_app_web_view &&
    contentFiles.some((f) => FileUtils.isAudioExtension(f.extension) && f.duration === null);

  const audioPoll = usePoll(5_000, { only: ["audio_durations"] }, { autoStart: false });
  const mediaPoll = usePoll(10_000, { only: ["latest_media_locations"] }, { autoStart: false });

  React.useEffect(() => {
    if (hasUnprocessedAudio) audioPoll.start();
    else audioPoll.stop();
  }, [hasUnprocessedAudio]);

  React.useEffect(() => {
    if (hasRichContent && contentFiles.length > 0) mediaPoll.start();
  }, []);

  const url = new URL(useOriginalLocation());
  const addThirdPartyAnalytics = useAddThirdPartyAnalytics();

  useRunOnce(() => {
    if (url.searchParams.get("receipt") === "true" && layoutProps.purchase?.email) {
      showAlert(`Your purchase was successful! We sent a receipt to ${layoutProps.purchase.email}.`, "success");
      url.searchParams.delete("receipt");
      window.history.replaceState(window.history.state, "", url.toString());

      if (product_has_third_party_analytics && layoutProps.purchase.product_permalink)
        addThirdPartyAnalytics({
          permalink: layoutProps.purchase.product_permalink,
          location: "receipt",
          purchaseId: layoutProps.purchase.id,
        });
    }
  });

  const isDesktop = useIsAboveBreakpoint("lg");
  const pages = content.rich_content_pages ?? [];
  const getInitialPageIndex = () => {
    if (!content.last_content_page_id) return 0;
    const index = pages.findIndex((page) => page.page_id === content.last_content_page_id);
    return index >= 0 ? index : 0;
  };
  const [activePageIndex, setActivePageIndex] = React.useState(getInitialPageIndex());
  const activePage = pages[activePageIndex];

  const handlePageChange = React.useCallback(
    (newIndex: number) => {
      setActivePageIndex(newIndex);
      const newPage = pages[newIndex];
      if (newPage && layoutProps.purchase) {
        void saveLastContentPage(layoutProps.token, newPage.page_id);
      }
    },
    [pages, layoutProps.token, layoutProps.purchase],
  );
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
    isMobileAppWebView: layoutProps.is_mobile_app_web_view,
    getFolderArchive: (folderId: string) =>
      getFolderArchiveDownloadUrl(Routes.url_redirect_download_archive_path(layoutProps.token, { folder_id: folderId })),
    getDownloadUrlsForFiles: async (ids: string[]) =>
      getProductFileDownloadInfos(
        Routes.url_redirect_download_product_files_path(layoutProps.token, { product_file_ids: ids }),
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
  const purchaseInfo = {
    purchaseId: layoutProps.purchase?.id ?? null,
    redirectId: layoutProps.redirect_id,
    token: layoutProps.token,
  };

  return (
    <div className="flex min-h-screen flex-col">
      <Head>
        <meta name="apple-itunes-app" content={`app-id=${ios_app_id}, app-argument=${download_page_url}`} />
      </Head>
      <Layout
        {...layoutProps}
        headerActions={
          <>
            {layoutProps.purchase && content.discord ? (
              <DiscordButton purchaseId={layoutProps.purchase.id} connected={content.discord.connected} />
            ) : null}
            {content.community_chat_url ? (
              <Button asChild color="accent">
                <a href={content.community_chat_url}>Community</a>
              </Button>
            ) : null}
            <OpenInAppButton iosAppUrl={content.ios_app_url} androidAppUrl={content.android_app_url} />
            {content.download_all_button ? (
              <DownloadAllButton
                zip_path={Routes.url_redirect_download_archive_path(layoutProps.token)}
                files={content.download_all_button.files}
              />
            ) : null}
          </>
        }
        pageList={
          showPageList && isDesktop ? (
            <PageList aria-label="Table of Contents">
              {pages.map((page, index) => (
                <PageListItem
                  key={page.page_id}
                  isSelected={index === activePageIndex}
                  onClick={() => handlePageChange(index)}
                  role="tab"
                >
                  <Icon
                    name={pageIcons[index] ?? "file-text"}
                    aria-label={pageIcons[index] ? PAGE_ICON_LABEL[pageIcons[index]] : "file-text"}
                  />
                  <span className="flex-1">{page.title ?? "Untitled"}</span>
                </PageListItem>
              ))}
            </PageList>
          ) : null
        }
      >
        <PurchaseInfoProvider value={purchaseInfo}>
          <MediaUrlsProvider value={mediaUrlsValue}>
            <IsMobileAppViewProvider value={layoutProps.is_mobile_app_web_view}>
              {content.rich_content_pages !== null ? (
                activePage ? (
                  <ContentFilesProvider value={contentFiles}>
                    <FilesAndFoldersDownloadInfoProvider value={downloadInfo}>
                      <PostsProvider value={postsContext}>
                        <PurchaseCustomFieldsProvider
                          value={layoutProps.purchase?.purchase_custom_fields ?? []}
                        >
                          <RichContentView
                            key={activePage.page_id}
                            richContent={activePage.description}
                            saleInfo={
                              layoutProps.purchase
                                ? {
                                    sale_id: layoutProps.purchase.id,
                                    product_id: layoutProps.purchase.product_id,
                                    product_permalink: layoutProps.purchase.product_permalink,
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
          <div role="navigation" className="mt-auto flex gap-4 border-t border-border pt-4 lg:justify-end lg:pb-4">
            {isDesktop ? null : (
              <Popover>
                <PopoverAnchor>
                  <PopoverTrigger aria-label="Table of Contents" asChild>
                    <Button>
                      <Icon name="unordered-list" />
                    </Button>
                  </PopoverTrigger>
                </PopoverAnchor>
                <PopoverContent sideOffset={4} className="border-0 p-0 shadow-none">
                  <div role="menu">
                    {pages.map((page, index) => (
                      <PopoverClose key={page.page_id} asChild>
                        <div
                          role="menuitemradio"
                          aria-checked={index === activePageIndex}
                          onClick={() => {
                            handlePageChange(index);
                          }}
                        >
                          <Icon
                            name={pageIcons[index] ?? "file-text"}
                            aria-label={pageIcons[index] ? PAGE_ICON_LABEL[pageIcons[index]] : "file-text"}
                          />
                          &ensp;
                          {page.title ?? "Untitled"}
                        </div>
                      </PopoverClose>
                    ))}
                  </div>
                </PopoverContent>
              </Popover>
            )}
            <WithTooltip position="top" tip={hasPreviousPage ? null : "No more pages"}>
              <Button
                disabled={!hasPreviousPage}
                onClick={() => handlePageChange(activePageIndex - 1)}
                className="flex-1 lg:flex-none"
              >
                <Icon name="arrow-left" />
                Previous
              </Button>
            </WithTooltip>
            <WithTooltip position="top" tip={hasNextPage ? null : "No more pages"}>
              <Button
                disabled={!hasNextPage}
                onClick={() => handlePageChange(activePageIndex + 1)}
                className="flex-1 lg:flex-none"
              >
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
          <div className="flex flex-col gap-4">
            <DownloadPagePostList posts={content.posts} />
          </div>
        ) : null}
      </Layout>
    </div>
  );
}

const findFileEmbeds = (node: RichContent): string[] =>
  node.content?.flatMap((child) => {
    if (child.type === FileEmbed.name && child.attrs?.id) return cast(child.attrs.id);
    return findFileEmbeds(child);
  }) ?? [];

const COMMON_CONTAINER_NODE_TYPES = ["doc", "orderedList", "bulletList", "listItem", "blockquote"];
const nodeHasLicense = (node: RichContent) =>
  node.type === LicenseKey.name ||
  ((COMMON_CONTAINER_NODE_TYPES.includes(node.type ?? "") && node.content?.some(nodeHasLicense)) ?? false);

DownloadPage.loggedInUserLayout = true;
export default DownloadPage;
