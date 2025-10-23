import cx from "classnames";
import throttle from "lodash/throttle";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { createConsumptionEvent } from "$app/data/consumption_analytics";
import { trackMediaLocationChanged } from "$app/data/media_location";
import { humanizedDuration } from "$app/utils/duration";
import FileUtils from "$app/utils/file";
import { createJWPlayer } from "$app/utils/jwPlayer";
import { asyncVoid } from "$app/utils/promise";
import { assertResponseError, request, ResponseError } from "$app/utils/request";

import { Button, NavigationButton } from "$app/components/Button";
import { FileRowContent } from "$app/components/FileRowContent";
import { Icon } from "$app/components/Icons";
import { LoadingSpinner } from "$app/components/LoadingSpinner";
import { PlayVideoIcon } from "$app/components/PlayVideoIcon";
import { ProgressPie } from "$app/components/ProgressPie";
import { showAlert } from "$app/components/server-components/Alert";
import { AudioPlayerContainer } from "$app/components/server-components/DownloadPage/AudioPlayerContainer";
import {
  useIsMobileAppView,
  useMediaUrls,
  usePurchaseInfo,
} from "$app/components/server-components/DownloadPage/WithContent";
import { useOnOutsideClick } from "$app/components/useOnOutsideClick";
import { useRefToLatest } from "$app/components/useRefToLatest";
import { WithTooltip } from "$app/components/WithTooltip";

import { NativeAppLink, TrackClick } from "./Interactions";

import thumbnailPlaceholder from "$assets/images/placeholders/product-cover.png";

export type SubtitleFile = {
  url: string;
  file_name: string;
  extension: string;
  language: string;
  file_size: number | null;
  download_url: string;
  signed_url: string;
};

type LatestMediaLocation = { location: number; timestamp: string };
export type FileItem = {
  type: "file";
  id: string;
  file_name: string;
  description: string | null;
  extension: string;
  file_size: number | null;
  pagelength: number | null;
  duration: number | null;
  content_length: number | null;
  download_url: string | null;
  latest_media_location: LatestMediaLocation | null;
  stream_url: string | null;
  external_link_url: string | null;
  kindle_data: { email: string | null; icon_url: string } | null;
  read_url: string | null;
  subtitle_files?: SubtitleFile[];
  pdf_stamp_enabled: boolean;
  processing: boolean;
  thumbnail_url: string | null;
  isbn?: string | null;
};
export type FolderItem = {
  type: "folder";
  id: string;
  name: string;
  children: FileItem[];
};

type Props = { content_items: (FileItem | FolderItem)[] };
export const FileList = ({ content_items }: Props) => {
  const [playingAudioForId, setPlayingAudioForId] = React.useState<null | string>(null);

  const getFileRow = (file: FileItem) => (
    <FileRow
      key={file.id}
      file={file}
      playingAudioForId={playingAudioForId}
      setPlayingAudioForId={setPlayingAudioForId}
    />
  );

  return (
    <div role="tree" aria-label="Files">
      {content_items.map((item) =>
        item.type === "folder" ? (
          <FolderRow key={`folder${item.id}`} folder={item}>
            {item.children.map((file) => getFileRow(file))}
          </FolderRow>
        ) : (
          getFileRow(item)
        ),
      )}
    </div>
  );
};

const FolderRow = ({ folder, children }: { folder: FolderItem; children: React.ReactNode }) => {
  const [isExpanded, setIsExpanded] = React.useState(false);

  return (
    <div role="treeitem" aria-expanded={isExpanded}>
      <div className="content" onClick={() => setIsExpanded(!isExpanded)}>
        <Icon name="solid-folder-open" className="type-icon" />
        <h4>{folder.name}</h4>
      </div>
      <div role="group">{children}</div>
    </div>
  );
};

export const shouldShowSubtitlesForFile = (file: FileItem) =>
  file.stream_url != null && file.download_url != null && file.subtitle_files != null && file.subtitle_files.length > 0;

export const FileRow = ({
  file,
  playingAudioForId,
  setPlayingAudioForId,
  isEmbed = false,
  isTreeItem = true,
  collapsed: initialCollapsed = false,
}: {
  file: FileItem;
  playingAudioForId: null | string;
  setPlayingAudioForId: (id: null | string) => void;
  isEmbed?: boolean;
  isTreeItem?: boolean;
  collapsed?: boolean;
}) => {
  const isMobileAppWebView = useIsMobileAppView();
  const purchaseInfo = usePurchaseInfo();
  const [allMediaUrls, setAllMediaUrls] = useMediaUrls();
  const [isFetchingMediaUrls, setIsFetchingMediaUrls] = React.useState(false);
  const [isShowingKindleDrawer, setIsShowingKindleDrawer] = React.useState(false);
  const toggleKindleDrawer = () => setIsShowingKindleDrawer((current) => !current);
  const closeKindleDrawer = () => setIsShowingKindleDrawer(false);
  const [isShowingAudioDrawer, setIsShowingAudioDrawer] = React.useState(false);
  const toggleAudioDrawer = () => setIsShowingAudioDrawer((current) => !current);
  const [resumeLocation, setResumeLocation] = React.useState(
    file.latest_media_location == null || file.latest_media_location.location === file.content_length
      ? 0
      : file.latest_media_location.location,
  );
  const [isExpanded, setIsExpanded] = React.useState(false);
  const [isCollapsed, setIsCollapsed] = React.useState(initialCollapsed);
  const downloadUrl = file.download_url;
  const downloadButton = downloadUrl ? (
    <TrackClick eventName="download_click" resourceId={file.id}>
      <NavigationButton href={downloadUrl}>Download</NavigationButton>
    </TrackClick>
  ) : null;
  const streamUrl = file.stream_url;
  const externalLinkUrl = file.external_link_url;
  const mediaUrls = allMediaUrls[file.id] ?? [];
  const fetchMediaUrls = async () => {
    try {
      if (isFetchingMediaUrls) return;
      setIsFetchingMediaUrls(true);
      const response = await request({
        url: Routes.url_redirect_media_urls_path(purchaseInfo.token, {
          params: { file_ids: [file.id] },
        }),
        method: "GET",
        accept: "json",
      });
      if (!response.ok) throw new ResponseError();
      const urls = cast<Record<string, string[]>>(await response.json());
      if (!urls[file.id]?.length) throw new ResponseError();
      setAllMediaUrls((prev) => ({ ...prev, ...urls }));
    } finally {
      setIsFetchingMediaUrls(false);
    }
  };

  const playAudio = () => {
    if (!isShowingAudioDrawer) setPlayingAudioForId(file.id);
    if (isShowingAudioDrawer && playingAudioForId === file.id) setPlayingAudioForId(null);
    toggleAudioDrawer();
  };

  if (isMobileAppWebView && isEmbed && FileUtils.isAudioExtension(file.extension)) {
    return <MobileAppAudioFileRow file={file} />;
  }

  const isEmbeddedVideo = isEmbed && !!streamUrl;

  return (
    <div
      className={cx({ embed: isEmbed })}
      role={isTreeItem || shouldShowSubtitlesForFile(file) ? "treeitem" : undefined}
      aria-expanded={shouldShowSubtitlesForFile(file) ? isExpanded : undefined}
    >
      {isEmbeddedVideo && !isCollapsed ? (
        <VideoEmbedPreview
          file={file}
          resumeLocation={resumeLocation}
          setResumeLocation={setResumeLocation}
          fetchMediaUrls={fetchMediaUrls}
          isFetchingMediaUrls={isFetchingMediaUrls}
          autoPlay={initialCollapsed}
        />
      ) : null}
      <div className="content" onClick={() => setIsExpanded(!isExpanded)}>
        {isEmbeddedVideo && file.thumbnail_url && isCollapsed ? (
          <div className="thumbnail">
            <img src={file.thumbnail_url} />
          </div>
        ) : null}
        <FileRowContent
          extension={file.extension}
          name={file.file_name}
          externalLinkUrl={externalLinkUrl}
          hideIcon={isEmbeddedVideo}
          details={
            <>
              {file.extension ? <li>{file.extension}</li> : null}

              {externalLinkUrl ? <li>{externalLinkUrl}</li> : null}

              {file.file_size ? <li>{FileUtils.getFullFileSizeString(file.file_size)}</li> : null}

              {file.pagelength ? (
                <li>
                  {file.pagelength} {file.pagelength === 1 ? "page" : "pages"}
                </li>
              ) : null}

              {file.isbn ? <li>ISBN: {file.isbn}</li> : null}

              {file.duration ? <li>{humanizedDuration(file.duration)}</li> : null}
            </>
          }
        />
      </div>

      <div className="actions">
        {file.latest_media_location && file.content_length ? (
          <div>
            <ProgressPie progress={file.latest_media_location.location / file.content_length} />
          </div>
        ) : null}

        {downloadButton}

        {!isEmbed && streamUrl != null ? (
          <TrackClick eventName="stream_click" resourceId={file.id}>
            <NavigationButton color="primary" href={streamUrl} target="_blank">
              {file.latest_media_location != null && file.latest_media_location.location === file.content_length
                ? "Watch again"
                : "Watch"}
            </NavigationButton>
          </TrackClick>
        ) : null}

        {isEmbeddedVideo && isCollapsed ? (
          <Button color="primary" onClick={() => setIsCollapsed(false)}>
            Play
          </Button>
        ) : null}

        {externalLinkUrl !== null ? (
          <TrackClick eventName="external_link_click" resourceId={file.id}>
            <NavigationButton color="primary" href={externalLinkUrl} target="_blank">
              Open
            </NavigationButton>
          </TrackClick>
        ) : null}

        {FileUtils.isAudioExtension(file.extension) ? (
          <TrackClick eventName="play_click" resourceId={file.id}>
            <Button
              color={isShowingAudioDrawer ? undefined : "primary"}
              aria-label="Play Button"
              disabled={isFetchingMediaUrls}
              onClick={asyncVoid(async () => {
                if (mediaUrls.length === 0) {
                  try {
                    await fetchMediaUrls();
                    playAudio();
                  } catch (e) {
                    assertResponseError(e);
                    showAlert("Sorry, something went wrong. Please try again.", "error");
                  }
                } else {
                  playAudio();
                }
              })}
            >
              {isShowingAudioDrawer
                ? "Close"
                : file.latest_media_location != null && file.latest_media_location.location === file.content_length
                  ? "Play again"
                  : "Play"}
            </Button>
          </TrackClick>
        ) : null}

        {!file.processing ? (
          <>
            {file.kindle_data != null ? (
              <TrackClick eventName="send_to_kindle_click" resourceId={file.id}>
                <Button className="button-kindle" onClick={toggleKindleDrawer}>
                  Send to Kindle
                </Button>
              </TrackClick>
            ) : null}

            {file.read_url != null ? (
              <NativeAppLink resourceId={file.id}>
                <NavigationButton color="primary" href={file.read_url}>
                  {file.latest_media_location != null && file.latest_media_location.location === file.content_length
                    ? "Read again"
                    : "Read"}
                </NavigationButton>
              </NativeAppLink>
            ) : null}
          </>
        ) : null}
      </div>

      {FileUtils.isAudioExtension(file.extension) && isShowingAudioDrawer ? (
        <div className="drawer">
          <AudioPlayerContainer
            fileId={file.id}
            playingAudioForId={playingAudioForId}
            setPlayingAudioForId={setPlayingAudioForId}
            resumeLocation={resumeLocation}
            setResumeLocation={setResumeLocation}
            contentLength={file.content_length}
          />
        </div>
      ) : null}

      {file.kindle_data != null && isShowingKindleDrawer ? (
        <SendToKindleContainer
          fileId={file.id}
          email={file.kindle_data.email}
          token={purchaseInfo.token}
          onDone={closeKindleDrawer}
        />
      ) : null}

      {shouldShowSubtitlesForFile(file) ? (
        <div role="group">
          {file.subtitle_files?.map((subtitleFile) => (
            <SubtitleRow key={subtitleFile.url} subtitleFile={subtitleFile} />
          ))}
        </div>
      ) : null}

      {file.description?.trim() ? <p style={{ whiteSpace: "pre-wrap" }}>{file.description}</p> : null}
    </div>
  );
};

const useGlobalCustomEventListener = (eventName: string, eventHandler: (evt: Event) => void) => {
  // The event handler here is stashed into a reference to allow us to replace the event handler
  // without tearing down & setting up a new event listener when the event handler changes.
  const handlerRef = useRefToLatest(eventHandler);

  React.useEffect(() => {
    const handle = (evt: Event) => {
      const currentHandler = handlerRef.current;
      currentHandler(evt);
    };

    window.addEventListener(eventName, handle);

    return () => window.removeEventListener(eventName, handle);
  }, [eventName]);
};

const TOUCH_AND_HOLD_TIMEOUT_IN_MS = 500;
const useTouchAndHold = ({ onFinish, onCancel }: { onFinish: () => void; onCancel: () => void }) => {
  const [timeoutId, setTimeoutId] = React.useState<null | ReturnType<typeof setTimeout>>(null);

  const onTouchStart = () => {
    if (timeoutId !== null) {
      clearTimeout(timeoutId);
      setTimeoutId(null);
      onCancel();
      return;
    }
    setTimeoutId(
      setTimeout(() => {
        onFinish();
        setTimeoutId(null);
      }, TOUCH_AND_HOLD_TIMEOUT_IN_MS),
    );
  };

  const onTouchEnd = () => {
    if (timeoutId !== null) {
      clearTimeout(timeoutId);
      setTimeoutId(null);
      onCancel();
    }
  };

  return { onTouchStart, onTouchEnd };
};

type MobileAppAudioPlayerInfo = {
  fileId: string;
  isPlaying: boolean;
  latestMediaLocation?: string;
};
const MobileAppAudioFileRow = ({ file }: { file: FileItem }) => {
  const [isPlaying, setIsPlaying] = React.useState(false);
  const [latestMediaLocation, setLatestMediaLocation] = React.useState<number | null>(
    file.latest_media_location?.location ?? null,
  );

  useGlobalCustomEventListener("mobile_app_audio_player_info", (evt) => {
    if (!(evt instanceof CustomEvent)) return;
    const data = cast<MobileAppAudioPlayerInfo | null>(evt.detail);
    if (data?.fileId === file.id) {
      setIsPlaying(data.isPlaying);
      setLatestMediaLocation(parseFloat(data.latestMediaLocation ?? "0"));
    }
  });

  const [showTooltip, setShowTooltip] = React.useState(false);
  const touchAndHoldEventListeners = useTouchAndHold({
    onFinish: () => setShowTooltip(true),
    // Hide the tooltip after a short delay so it doesn't toggle the playback on short-tap which depends on the 'showTooltip' state
    onCancel: () => setTimeout(() => setShowTooltip(false), 100),
  });
  const selfRef = React.useRef<HTMLDivElement>(null);
  useOnOutsideClick([selfRef], () => setShowTooltip(false));

  const isCompleted =
    latestMediaLocation && latestMediaLocation > 0 && file.duration && latestMediaLocation >= file.duration;
  const isProcessing = file.duration === null;

  return (
    <div ref={selfRef} className="embed" {...touchAndHoldEventListeners}>
      <WithTooltip tip={showTooltip ? file.file_name : null} position="top">
        <TrackClick
          eventName="play_click"
          resourceId={isProcessing || showTooltip ? null : file.id} // Prevent playback when processing or showing tooltip
          type="audio"
          isPlaying={isPlaying}
          resumeAt={latestMediaLocation || 0}
          contentLength={file.duration || 0}
        >
          <button
            className={cx("content", { "text-muted": isProcessing })}
            style={{
              gridColumn: "3 span",
              userSelect: "none",
              WebkitUserSelect: "none",
              WebkitTouchCallout: "none",
              outline: "none",
            }}
            disabled={isProcessing}
          >
            <FileRowContent
              hideIcon
              extension={file.extension}
              name={file.file_name}
              externalLinkUrl={file.external_link_url}
              details={
                isProcessing ? (
                  <li>Processing...</li>
                ) : (
                  <>
                    {file.extension ? <li>{file.extension}</li> : null}
                    {file.file_size ? <li>{FileUtils.getFullFileSizeString(file.file_size)}</li> : null}
                    {file.duration ? <li>{humanizedDuration(file.duration)}</li> : null}
                  </>
                )
              }
            />
          </button>
        </TrackClick>
      </WithTooltip>
      <div
        className={cx("actions", { "text-muted": isProcessing })}
        style={{ gridColumn: "4", gap: "var(--spacer-4)", flexWrap: "nowrap" }}
      >
        {file.download_url ? (
          <TrackClick eventName="download_click" resourceId={file.id}>
            <button aria-label="Download">
              <Icon name="download" className="type-icon" />
            </button>
          </TrackClick>
        ) : null}
        <TrackClick
          eventName="play_click"
          resourceId={isProcessing ? null : file.id}
          type="audio"
          isPlaying={isPlaying}
          resumeAt={latestMediaLocation || 0}
          contentLength={file.duration || 0}
        >
          {isPlaying ? (
            <button aria-label="Pause" disabled={isProcessing}>
              <Icon
                className="type-icon"
                name="circle-pause"
                style={{ width: "var(--big-icon-size)", height: "var(--big-icon-size)" }}
              />
            </button>
          ) : isCompleted ? (
            <button aria-label="Play" disabled={isProcessing}>
              <Icon
                className="type-icon text-muted"
                name="outline-check-circle"
                style={{ width: "var(--big-icon-size)", height: "var(--big-icon-size)" }}
              />
            </button>
          ) : (
            <button aria-label="Play" disabled={isProcessing}>
              <Icon
                className="type-icon"
                name={latestMediaLocation && latestMediaLocation > 0 ? "outline-circle-play" : "circle-play"}
                style={{ width: "var(--big-icon-size)", height: "var(--big-icon-size)" }}
              />
            </button>
          )}
        </TrackClick>
      </div>
      {!isCompleted &&
      latestMediaLocation !== null &&
      (isPlaying || latestMediaLocation > 0) &&
      file.duration &&
      file.duration > 0 ? (
        <div style={{ display: "grid", gridColumn: "4 span", gap: "var(--spacer-1)" }}>
          <meter
            value={latestMediaLocation / file.duration}
            className="border-0"
            style={{
              ...{
                background: "var(--active-bg)",
                height: "var(--spacer-1)",
              },
              ...(isPlaying ? {} : { "--optimum-value-background": "currentColor" }),
            }}
          />
          <small>{humanizedDuration(file.duration - latestMediaLocation)} left</small>
        </div>
      ) : null}
      {file.description?.trim() ? (
        <p style={{ gridColumn: "4 span", whiteSpace: "pre-wrap" }}>{file.description}</p>
      ) : null}
    </div>
  );
};

const LOCATION_TRACK_EVENT_DELAY = 10000;

type VideoEmbedPreviewProps = {
  file: FileItem;
  resumeLocation: number;
  setResumeLocation: (location: number) => void;
  fetchMediaUrls: () => Promise<void>;
  isFetchingMediaUrls: boolean;
  autoPlay?: boolean;
};
const VideoEmbedPreview = ({
  file,
  resumeLocation,
  setResumeLocation,
  fetchMediaUrls,
  isFetchingMediaUrls,
  autoPlay = false,
}: VideoEmbedPreviewProps) => {
  const [isVideoPlayerShowing, setIsVideoPlayerShowing] = React.useState(false);
  const [duration, setDuration] = React.useState(0);
  const videoPlayerId = `jwplayer-${file.id}`;
  const { purchaseId, redirectId } = usePurchaseInfo();
  const [allMediaUrls] = useMediaUrls();
  const mediaUrls = allMediaUrls[file.id] ?? [];
  const trackMediaLocation = React.useCallback((position: number) => {
    if (purchaseId === null) return;
    setResumeLocation(position >= (file.content_length ?? duration) ? 0 : position);
    void trackMediaLocationChanged({
      urlRedirectId: redirectId,
      productFileId: file.id,
      purchaseId,
      location: file.content_length !== null && position > file.content_length ? file.content_length : position,
    });
  }, []);
  const throttledTrackMediaLocation = React.useCallback(throttle(trackMediaLocation, LOCATION_TRACK_EVENT_DELAY), []);
  React.useEffect(() => {
    if (!mediaUrls.length || !isVideoPlayerShowing) return;
    void createJWPlayer(videoPlayerId, {
      playlist: [
        {
          sources: mediaUrls.map((url) => ({ file: url })),
          tracks: file.subtitle_files?.map((subtitleFile) => ({
            file: subtitleFile.signed_url,
            label: subtitleFile.language,
            kind: "captions",
          })),
        },
      ],
    }).then((player) => {
      let initialSeekDone = false;
      player
        .on("ready", () => player.play())
        .on("play", () => {
          if (initialSeekDone) return;

          void createConsumptionEvent({
            eventType: "watch",
            urlRedirectId: redirectId,
            productFileId: file.id,
            purchaseId,
          });
          setDuration(player.getDuration());
          player.seek(resumeLocation);
          initialSeekDone = true;
        })
        .on("seek", (event) => trackMediaLocation(event.offset))
        .on("time", (event) => throttledTrackMediaLocation(event.position))
        .on("complete", () => {
          throttledTrackMediaLocation.cancel();
          trackMediaLocation(file.content_length ?? duration);
          setIsVideoPlayerShowing(false);
        });
    });
  }, [isVideoPlayerShowing]);

  const startPlaying = async () => {
    if (isFetchingMediaUrls) return;
    if (mediaUrls.length === 0) {
      try {
        await fetchMediaUrls();
        setIsVideoPlayerShowing(true);
      } catch (e) {
        assertResponseError(e);
        showAlert("Sorry, something went wrong. Please try again.", "error");
      }
    } else {
      setIsVideoPlayerShowing(true);
    }
  };

  React.useEffect(() => {
    if (autoPlay) {
      void startPlaying();
    }
  }, [autoPlay]);

  return isVideoPlayerShowing ? (
    <div className="preview">
      <div id={videoPlayerId}></div>
    </div>
  ) : (
    <figure className="preview">
      <img
        src={file.thumbnail_url ?? thumbnailPlaceholder}
        style={{
          position: "absolute",
          height: "100%",
          objectFit: "cover",
          borderRadius: "var(--border-radius-1) var(--border-radius-1) 0 0",
        }}
      />
      <TrackClick eventName="watch" resourceId={file.id}>
        <button
          className="underline"
          style={{
            position: "absolute",
            top: "50%",
            left: "50%",
            transform: "translate(-50%, -50%)",
          }}
          disabled={isFetchingMediaUrls}
          onClick={() => void startPlaying()}
          aria-label="Watch"
        >
          {isFetchingMediaUrls ? <LoadingSpinner width="4em" /> : <PlayVideoIcon />}
        </button>
      </TrackClick>
    </figure>
  );
};

const SendToKindleContainer = ({
  token,
  fileId,
  email,
  onDone,
}: {
  token: string;
  fileId: string;
  email: null | string;
  onDone: () => void;
}) => {
  const [emailEntry, setEmailEntry] = React.useState<string>(email || "");
  const [hasError, setHasError] = React.useState(false);

  const sendToKindle = async () => {
    try {
      const response = await request({
        url: Routes.send_to_kindle_path(token),
        method: "POST",
        accept: "json",
        data: { email: emailEntry, file_external_id: fileId },
      });

      const json = cast<{ success: boolean }>(await response.json());
      if (!json.success) throw new ResponseError("Please enter a valid Kindle email address.");

      showAlert("It's been sent to your Kindle.", "success");
      onDone();
    } catch (e) {
      assertResponseError(e);
      showAlert(e.message, "error");
      setHasError(true);
    }
  };

  return (
    <div>
      <div className="input-with-button">
        <fieldset className={cx({ danger: hasError })}>
          <input
            type="text"
            value={emailEntry}
            onChange={(evt) => {
              setEmailEntry(evt.target.value);
              setHasError(false);
            }}
            placeholder="e7@kindle.com"
            autoFocus
          />
          <small>
            You'll need to add noreply@customers.gumroad.com to your{" "}
            <a href="https://www.amazon.com/gp/help/customer/display.html?nodeId=GX9XLEVV8G4DB28H">
              list of approved personal document emails
            </a>
            .
          </small>
        </fieldset>
        <Button color="primary" onClick={() => void sendToKindle()} style={{ alignSelf: "flex-start" }}>
          Send
        </Button>
      </div>
    </div>
  );
};

const SubtitleRow = ({ subtitleFile }: { subtitleFile: SubtitleFile }) => (
  <div role="treeitem">
    <div className="content">
      <FileRowContent
        extension={subtitleFile.extension}
        name={`${subtitleFile.file_name} (${subtitleFile.language})`}
        externalLinkUrl={null}
        details={subtitleFile.file_size ? <li>{FileUtils.getFullFileSizeString(subtitleFile.file_size)}</li> : null}
      />
    </div>

    <div className="actions">
      <NavigationButton href={subtitleFile.download_url}>Download</NavigationButton>
    </div>
  </div>
);
