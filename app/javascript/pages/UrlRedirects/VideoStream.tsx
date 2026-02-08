import { Head, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { VideoStreamPlayer } from "$app/components/server-components/VideoStreamPlayer";

type SubtitleFile = {
  file: string;
  label: string;
  kind: "captions";
};

type Video = {
  sources: string[];
  guid: string;
  title: string;
  tracks: SubtitleFile[];
  external_id: string;
  latest_media_location: { location: number } | null;
  content_length: number | null;
};

type PageProps = {
  playlist: Video[];
  index_to_play: number;
  url_redirect_id: string;
  purchase_id: string | null;
  should_show_transcoding_notice: boolean;
  transcode_on_first_sale: boolean;
};

const VideoStreamPage = () => {
  const props = cast<PageProps>(usePage().props);

  return (
    <>
      <Head title="Watch" />
      <div id="stream_page" className="download-page responsive responsive-nav">
        <VideoStreamPlayer
          playlist={props.playlist}
          index_to_play={props.index_to_play}
          url_redirect_id={props.url_redirect_id}
          purchase_id={props.purchase_id}
          should_show_transcoding_notice={props.should_show_transcoding_notice}
          transcode_on_first_sale={props.transcode_on_first_sale}
        />
      </div>
    </>
  );
};

export default VideoStreamPage;
