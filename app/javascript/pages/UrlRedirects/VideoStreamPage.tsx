import * as React from "react";
import { usePage } from "@inertiajs/react";
import { cast } from "ts-safe-cast";

import { VideoStreamPlayer } from "$app/components/server-components/VideoStreamPlayer";

type Video = {
    sources: string[];
    guid: string;
    title: string;
    tracks: { file: string; label: string; kind: "captions" }[];
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

function VideoStreamPage() {
    const { playlist, index_to_play, url_redirect_id, purchase_id, should_show_transcoding_notice, transcode_on_first_sale } =
        cast<PageProps>(usePage().props);

    return (
        <div id="stream_page" className="download-page responsive responsive-nav" style={{ position: "relative", width: "100%", height: "100vh" }}>
            <VideoStreamPlayer
                playlist={playlist}
                index_to_play={index_to_play}
                url_redirect_id={url_redirect_id}
                purchase_id={purchase_id}
                should_show_transcoding_notice={should_show_transcoding_notice}
                transcode_on_first_sale={transcode_on_first_sale}
            />
        </div>
    );
}

export default VideoStreamPage;
