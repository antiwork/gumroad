# frozen_string_literal: true

require "test_helper"

class StreamableHlsPlaylistTest < ActiveSupport::TestCase
  PLAYLIST = <<~M3U8
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=782831,RESOLUTION=640x480
    index_480p.m3u8
  M3U8

  class FakeS3
    class Body
      def initialize(content)
        @content = content
      end

      def read
        @content
      end
    end

    class S3Object
      def initialize(content)
        @content = content
      end

      def get
        Struct.new(:body).new(Body.new(@content))
      end
    end

    class Bucket
      def initialize(content)
        @content = content
      end

      def object(_key)
        S3Object.new(@content)
      end
    end

    def initialize(content)
      @content = content
    end

    def bucket(_name)
      Bucket.new(@content)
    end
  end

  test "hls_playlist returns the playlist for a transcoded key that carries no original file name" do
    product_file = create_streamable_video(link: create_product)
    create_transcoded_video(
      streamable: product_file,
      is_hls: true,
      original_video_key: "i170probe/arb-1793917407.mp4",
      transcoded_video_key: "i170probe/arb-1793917407/hls/index.m3u8"
    )

    product_file.expects(:signed_cloudfront_url)
                .with("#{HLS_DISTRIBUTION_URL}i170probe/arb-1793917407/hls/index_480p.m3u8", is_video: true)
                .returns("SIGNED")

    Aws::S3::Resource.stub(:new, FakeS3.new(PLAYLIST)) do
      assert_equal "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=782831,RESOLUTION=640x480\nSIGNED\n", product_file.hls_playlist
    end
  end

  test "hls_playlist escapes an original file name taken from the transcoded key" do
    product_file = create_streamable_video(link: create_product)
    create_transcoded_video(
      streamable: product_file,
      is_hls: true,
      original_video_key: "attachments/abc123/original/My Video.mp4",
      transcoded_video_key: "attachments/abc123/original/My Video/hls/index.m3u8"
    )

    product_file.expects(:signed_cloudfront_url)
                .with("#{HLS_DISTRIBUTION_URL}attachments/abc123/original/My+Video/hls/index_480p.m3u8", is_video: true)
                .returns("SIGNED")

    Aws::S3::Resource.stub(:new, FakeS3.new(PLAYLIST)) do
      assert_equal "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=782831,RESOLUTION=640x480\nSIGNED\n", product_file.hls_playlist
    end
  end
end
