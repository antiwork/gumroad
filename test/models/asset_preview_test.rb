# frozen_string_literal: true

require "test_helper"

# Ported from spec/models/asset_preview_spec.rb. AssetPreview attaches image/video
# covers or embeds oembed players. Objects are built with the shared
# ModelFactories helpers (create_asset_preview[_mov/_jpg/_gif]); dimension
# metadata is injected by AssetPreviewAnalysisStub instead of shelling out to the
# analyzer on every create.
#
# Storage: the RSpec suite runs every example against MinIO (S3), so several of
# its assertions match the S3 public-URL shape (AWS_S3_ENDPOINT/S3_BUCKET/<key>).
# Here the default service is a local Disk one — attaching a file shouldn't cost
# a network round-trip in the ~2,600-test suite — where file.url is a signed URL
# that base64-encodes the key. Those URL-shape assertions are rewritten to
# service-agnostic checks of the same behavior (a file/variant is attached; url
# picks the retina variant for images, the original for gifs/videos).
#
# The two `#url=` download tests are the exception: their subject IS the S3
# round-trip, so they opt into the MinIO-backed service with `with_real_s3` (the
# CI job runs MinIO as of #6205). The only test here that still skips is the MOV
# metadata canary, and it skips on the ffprobe binary being absent rather than on
# anything about this suite — so it runs locally and anywhere ffmpeg is installed.
#
# oembed lookups replay the RSpec cassettes via the VCR bridge (test/support/vcr.rb).
class AssetPreviewTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # --- Attachment ------------------------------------------------------------

  test "scales down a big image and keeps the original" do
    asset_preview = create_asset_preview
    assert asset_preview.file.attached?
    assert asset_preview.retina_variant.key.present?
    assert_equal 1633, asset_preview.width
    assert_equal 512, asset_preview.height
    assert_equal 670, asset_preview.display_width
    assert_equal 210, asset_preview.display_height
    assert_equal 1005, asset_preview.retina_width
  end

  test "does not scale up a smaller image" do
    asset_preview = create_asset_preview_jpg
    assert_equal 25, asset_preview.width
    assert_equal 25, asset_preview.height
    assert_equal 25, asset_preview.display_width
    assert_equal 25, asset_preview.display_height
  end

  test "succeeds with video" do
    asset_preview = create_asset_preview_mov
    assert asset_preview.file.attached?
    assert_equal "video", asset_preview.display_type
    assert asset_preview.url.present?
  end

  test "doesn't post-process GIFs and keeps the original" do
    asset_preview = create_asset_preview_gif
    assert_not asset_preview.should_post_process?
    assert_equal 670, asset_preview.display_width
    assert_equal 500, asset_preview.display_height
    assert_equal 670, asset_preview.retina_width
  end

  test "fails with an arbitrary filetype" do
    asset_preview = create_asset_preview
    asset_preview.file.attach(Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures/test.zip"), "application/octet-stream"))
    assert_equal false, asset_preview.save
    assert_equal ["Cover must be an image (JPEG, PNG, GIF) or a video."], asset_preview.errors.full_messages
  end

  test "does not allow unsupported image formats" do
    asset_preview = create_asset_preview
    asset_preview.file.attach(Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures/webp_image.webp"), "image/webp"))
    assert_equal false, asset_preview.save
    assert_equal ["Cover must be an image (JPEG, PNG, GIF) or a video."], asset_preview.errors.full_messages
  end

  test "allows marking deleted existing records with unsupported image formats" do
    asset_preview = create_asset_preview
    asset_preview.file.attach(Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures/webp_image.webp"), "image/webp"))
    asset_preview.save(validate: false)
    asset_preview.reload
    asset_preview.mark_deleted!
    assert asset_preview.reload.deleted?
  end

  # --- #analyze_file ---------------------------------------------------------

  test "fails with a video which cannot be analyzed" do
    asset_preview = create_asset_preview
    asset_preview.file.attach(analyzed_blob("invalid_asset_preview_video.MOV", "video/quicktime"))
    assert_equal false, asset_preview.save
    assert_includes asset_preview.errors.full_messages, "Could not analyze cover. Please check the uploaded file."
  end

  test "fails with a script disguised as an image" do
    asset_preview = create_asset_preview
    asset_preview.file.attach(analyzed_blob("disguised_html_script.png", "image/png"))
    assert_equal false, asset_preview.save
    assert_includes asset_preview.errors.full_messages, "Cover must be an image (JPEG, PNG, GIF) or a video."
  end

  test "fails with an image which cannot be analyzed" do
    asset_preview = create_asset_preview
    asset_preview.file.attach(analyzed_blob("invalid_asset_preview_image.jpeg", "image/jpeg"))
    assert_equal false, asset_preview.save
    assert_includes asset_preview.errors.full_messages, "Could not analyze cover. Please check the uploaded file."
  end

  # --- real analyzer (fast-factory canary) -----------------------------------
  # These attach the same fixtures the factories use but run the REAL analyzer,
  # proving AssetPreviewAnalysisStub's hardcoded metadata still matches what the
  # analyzer extracts. If a fixture or the analyzer changes, these fail, flagging
  # that the stub needs regenerating.

  test "extracts PNG dimensions matching the stubbed metadata" do
    asset_preview = analyze_fixture("kFDzu.png", "image/png")
    expected = AssetPreviewAnalysisStub::KNOWN_METADATA["kFDzu.png"]
    assert_equal expected["width"], asset_preview.width
    assert_equal expected["height"], asset_preview.height
  end

  test "extracts JPG dimensions matching the stubbed metadata" do
    asset_preview = analyze_fixture("test-small.jpg", "image/jpeg")
    expected = AssetPreviewAnalysisStub::KNOWN_METADATA["test-small.jpg"]
    assert_equal expected["width"], asset_preview.width
    assert_equal expected["height"], asset_preview.height
  end

  test "extracts GIF dimensions matching the stubbed metadata" do
    asset_preview = analyze_fixture("sample.gif", "image/gif")
    expected = AssetPreviewAnalysisStub::KNOWN_METADATA["sample.gif"]
    assert_equal expected["width"], asset_preview.width
    assert_equal expected["height"], asset_preview.height
  end

  test "extracts MOV dimensions and duration matching the stubbed metadata" do
    # The image canaries above only need ImageMagick; extracting video metadata
    # needs ffprobe, which the lightweight Minitest CI runner doesn't provide.
    # Runs wherever ffprobe is available (locally, or a CI job with ffmpeg).
    skip "video analysis requires ffprobe, which isn't available in this environment" unless ffprobe_available?
    asset_preview = analyze_fixture("thing.mov", "video/quicktime")
    expected = AssetPreviewAnalysisStub::KNOWN_METADATA["thing.mov"]
    metadata = asset_preview.file.blob.metadata
    assert_equal expected["width"], metadata[:width]
    assert_equal expected["height"], metadata[:height]
    assert_in_delta expected["duration"], metadata[:duration], 0.01
  end

  # --- Embeddable link (oembed) ----------------------------------------------

  test "succeeds with a video URL" do
    asset_preview = VCR.use_cassette("AssetPreview/Embeddable_link/succeeds_with_a_video_URL") do
      AssetPreview.create!(link: create_product, url: "https://www.youtube.com/watch?v=huKYieB4evw")
    end
    assert_equal "oembed", asset_preview.display_type
    assert_equal "https://www.youtube.com/embed/huKYieB4evw?feature=oembed&showinfo=0&controls=0&rel=0&enablejsapi=1", asset_preview.url
    assert_equal "https://i.ytimg.com/vi/huKYieB4evw/hqdefault.jpg", asset_preview.oembed_thumbnail_url
  end

  test "succeeds with a sound URL" do
    asset_preview = VCR.use_cassette("AssetPreview/Embeddable_link/succeeds_with_a_sound_URL") do
      AssetPreview.create!(link: create_product, url: "https://soundcloud.com/user-656397481/tbl31-here-comes-the-new-year")
    end
    assert_equal "oembed", asset_preview.display_type
    assert_equal "https://w.soundcloud.com/player/?visual=true&url=https%3A%2F%2Fapi.soundcloud.com%2Ftracks%2F376574774&auto_play=false&show_artwork=false&show_comments=false&buying=false&sharing=false&download=false&show_playcount=false&show_user=false&liking=false&maxwidth=670", asset_preview.oembed_url
    assert_match "https://i1.sndcdn.com/artworks-000278260091-nbg7dg-t500x500.jpg", asset_preview.oembed_thumbnail_url
  end

  test "fails with a dodgy URL and keeps attachment" do
    assert_no_difference -> { AssetPreview.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        with_ssrf_passthrough do
          VCR.use_cassette("AssetPreview/Embeddable_link/fails_with_a_dodgy_URL_and_keeps_attachment") do
            asset_preview = AssetPreview.new(link: create_product)
            asset_preview.url = "https://www.nsa.gov"
            asset_preview.save!
          end
        end
      end
    end
  end

  test "fails when oembed has no width or height" do
    OEmbedFinder.stubs(:embeddable_from_url).returns(
      html: "<iframe src=\"https://madeup.url\"></iframe>", info: { "thumbnail_url" => "https://madeup.thumbnail.url" }
    )
    ActiveStorage::Blob.any_instance.stubs(:purge).returns(nil)
    asset_preview = create_asset_preview
    error = assert_raises(ActiveRecord::RecordInvalid) do
      asset_preview.url = "https://madeup.url"
      asset_preview.save!
    end
    assert_equal "Validation failed: Could not analyze cover. Please check the uploaded file.", error.message
  end

  test "fails if the URL is not from a supported provider" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      VCR.use_cassette("AssetPreview/Embeddable_link/fails_if_URL_is_not_of_a_supported_provider") do
        AssetPreview.create!(link: create_product, url: "https://www.tiktok.com/@soflofooodie/video/7164885074863787307")
      end
    end
    assert_equal "Validation failed: A URL from an unsupported platform was provided. Please try again.", error.message
  end

  # --- #url= -----------------------------------------------------------------

  test "url= prevents non-http urls from being downloaded" do
    asset_preview = create_asset_preview
    error = assert_raises(URI::InvalidURIError) { asset_preview.url = "/etc/sudoers" }
    assert_match(/not a web url/, error.message)
  end

  test "url= rejects URLs without a host" do
    asset_preview = create_asset_preview
    error = assert_raises(URI::InvalidURIError) { asset_preview.url = "https:///path" }
    assert_match(/valid host/, error.message)
  end

  test "url= blocks SSRF attempts to localhost" do
    asset_preview = create_asset_preview
    assert_raises(SsrfFilter::PrivateIPAddress) do
      asset_preview.url = "http://127.0.0.1:6379/"
      asset_preview.save!
    end
  end

  test "url= blocks SSRF attempts to the cloud metadata endpoint" do
    asset_preview = create_asset_preview
    assert_raises(SsrfFilter::PrivateIPAddress) do
      asset_preview.url = "http://169.254.169.254/latest/meta-data/"
      asset_preview.save!
    end
  end

  test "url= blocks SSRF attempts to private IP ranges" do
    asset_preview = create_asset_preview
    assert_raises(SsrfFilter::PrivateIPAddress) do
      asset_preview.url = "http://192.168.1.1/"
      asset_preview.save!
    end
  end

  # These two cover `url=`'s download-and-attach path against real object
  # storage, which is what a seller pasting an image URL into the editor does.
  # The CI job runs MinIO as of #6205, so both cases run for real: the source
  # object is uploaded to the bucket first, then handed to the model as a URL.
  test "url= downloads a public URL and attaches it to the S3 service" do
    with_real_s3 do
      asset_preview = create_asset_preview
      source_url = upload_public_fixture("test.png", key: "specs/test-#{unique_suffix}.png", content_type: "image/png")

      with_downloadable_url(source_url) do
        asset_preview.url = source_url
        asset_preview.analyze_file
        asset_preview.save!
      end

      assert_match "#{AWS_S3_ENDPOINT}/#{PUBLIC_STORAGE_S3_BUCKET}/#{asset_preview.file.key}", asset_preview.file.url
      assert_match "#{AWS_S3_ENDPOINT}/#{PUBLIC_STORAGE_S3_BUCKET}/#{asset_preview.retina_variant.key}", asset_preview.retina_variant.url
    end
  end

  # Square brackets are legal in an S3 key but not in a URI, so the editor sends
  # them percent-encoded. `url=` has to parse that without raising and still
  # download the object — an unescaped bracket used to blow up URI.parse.
  test "url= downloads a public URL whose key contains encoded square brackets" do
    with_real_s3 do
      asset_preview = create_asset_preview
      key = "specs/test-small+with+[square+brackets]-#{unique_suffix}.jpg"
      source_url = upload_public_fixture("test-small+with+[square+brackets].jpg", key:, content_type: "image/jpeg")
      encoded_url = source_url.sub("[", "%5B").sub("]", "%5D")

      with_downloadable_url(encoded_url) do
        asset_preview.url = encoded_url
        asset_preview.analyze_file
        asset_preview.save!
      end

      assert_match "#{AWS_S3_ENDPOINT}/#{PUBLIC_STORAGE_S3_BUCKET}/#{asset_preview.file.key}", asset_preview.file.url
      assert_match "#{AWS_S3_ENDPOINT}/#{PUBLIC_STORAGE_S3_BUCKET}/#{asset_preview.retina_variant.key}", asset_preview.retina_variant.url
    end
  end

  # --- guid ------------------------------------------------------------------

  test "auto-generates a GUID on creation" do
    assert create_asset_preview.guid.present?
  end

  test "does not auto-generate a GUID on creation if one is supplied" do
    guid = "a" * 32
    asset_preview = create_asset_preview(guid:)
    assert_equal guid, asset_preview.guid
  end

  # --- product update on save ------------------------------------------------

  test "creating an asset_preview touches the product's updated_at" do
    product = create_product(updated_at: 1.month.ago)
    travel_to(Time.current) do
      assert_changes -> { product.updated_at }, to: Time.current do
        create_asset_preview(link: product)
      end
    end
  end

  # --- position --------------------------------------------------------------

  test "auto-increments position on creation" do
    product = create_product
    assert_equal 0, create_asset_preview(link: product).position
    assert_equal 1, create_asset_preview(link: product).position
    third = create_asset_preview(link: product)
    assert_equal 2, third.position
    third.mark_deleted!
    assert_equal 3, create_asset_preview(link: product).position
  end

  test "sets position on creation when the previous preview is missing its position" do
    product = create_product
    pre_existing = create_asset_preview(link: product)
    pre_existing.update!(position: nil)
    assert_equal 1, create_asset_preview(link: product).position
    assert_equal 2, create_asset_preview(link: product).position
  end

  # --- file attachment -------------------------------------------------------

  test "returns proper width for an attached file" do
    asset_preview = create_asset_preview
    assert_equal 1633, asset_preview.width
    assert_equal 670, asset_preview.display_width
    assert_equal 1005, asset_preview.retina_width
  end

  test "returns proper height for an attached file" do
    asset_preview = create_asset_preview
    assert_equal 512, asset_preview.height
    assert_equal 210, asset_preview.display_height
  end

  test "url_from_file serves the original and enqueues processing when the retina variant is not ready" do
    asset_preview = create_asset_preview
    ProcessAssetPreviewRetinaWorker.jobs.clear

    assert_equal asset_preview.file.url, asset_preview.url_from_file(style: :retina)
    assert_includes ProcessAssetPreviewRetinaWorker.jobs.map { _1["args"] }, [asset_preview.id]
  end

  test "url_from_file serves the processed retina variant once it exists" do
    asset_preview = create_asset_preview
    asset_preview.generate_retina_variant!

    assert_equal asset_preview.retina_variant.url, asset_preview.url_from_file(style: :retina)
  end

  test "creating an image cover enqueues retina variant processing" do
    ProcessAssetPreviewRetinaWorker.jobs.clear
    preview = create_asset_preview

    assert_includes ProcessAssetPreviewRetinaWorker.jobs.map { _1["args"] }, [preview.id]
  end

  test "creating a gif cover does not enqueue retina variant processing" do
    ProcessAssetPreviewRetinaWorker.jobs.clear
    create_asset_preview_gif

    assert_equal 0, ProcessAssetPreviewRetinaWorker.jobs.size
  end

  test "url returns the retina variant for image covers" do
    asset_preview = create_asset_preview
    assert_equal asset_preview.url_from_file(style: :retina), asset_preview.url
  end

  test "url returns the original file for gif covers" do
    asset_preview = create_asset_preview_gif
    assert_equal asset_preview.url_from_file(style: :original), asset_preview.url
  end

  test "url returns the original file for video covers" do
    asset_preview = create_asset_preview_mov
    assert_equal asset_preview.url_from_file(style: :original), asset_preview.url
  end

  # --- #image_url? -----------------------------------------------------------

  test "image_url? is true for images and false for videos" do
    assert_equal true, create_asset_preview_jpg.image_url?
    assert_equal false, create_asset_preview_mov.image_url?
  end

  # --- #oembed_thumbnail_url -------------------------------------------------

  test "oembed_thumbnail_url returns nil when oembed is not present" do
    assert_nil build_unsaved_asset_preview.oembed_thumbnail_url
  end

  test "oembed_thumbnail_url returns nil for blank thumbnail URLs" do
    asset_preview = build_unsaved_asset_preview
    ["", " "].each do |blank_url|
      asset_preview.oembed = { "info" => { "thumbnail_url" => blank_url } }
      assert_nil asset_preview.oembed_thumbnail_url
    end
  end

  test "oembed_thumbnail_url returns nil for dangerous URLs" do
    asset_preview = build_unsaved_asset_preview
    DANGEROUS_URLS.each do |url|
      asset_preview.oembed = { "info" => { "thumbnail_url" => url } }
      assert_nil asset_preview.oembed_thumbnail_url, "expected #{url} to be rejected"
    end
  end

  test "oembed_thumbnail_url returns safe thumbnail URLs unchanged" do
    asset_preview = build_unsaved_asset_preview
    asset_preview.oembed = { "info" => { "thumbnail_url" => "https://example.com/thumb.jpg" } }
    assert_equal "https://example.com/thumb.jpg", asset_preview.oembed_thumbnail_url
  end

  # --- #thumbnail_url --------------------------------------------------------

  test "thumbnail_url returns the oembed thumbnail when the cover is an embedded player" do
    asset_preview = build_unsaved_asset_preview
    asset_preview.oembed = { "info" => { "thumbnail_url" => "https://example.com/thumb.jpg" } }
    assert_equal "https://example.com/thumb.jpg", asset_preview.thumbnail_url
  end

  test "thumbnail_url returns nil for image covers" do
    assert_nil create_asset_preview_jpg.thumbnail_url
  end

  test "thumbnail_url returns the cached poster frame URL for uploaded video covers" do
    asset_preview = create_asset_preview_mov
    asset_preview.file.stubs(:previewable?).returns(true)
    Rails.cache.write("attachment_#{asset_preview.file.id}_poster_url", "https://files.example.com/poster.jpg")
    assert_equal "https://files.example.com/poster.jpg", asset_preview.thumbnail_url
  end

  test "thumbnail_url returns nil and enqueues generation when no poster exists yet" do
    asset_preview = create_asset_preview_mov
    asset_preview.file.stubs(:previewable?).returns(true)
    assert_nil asset_preview.thumbnail_url
    assert GenerateVideoPosterWorker.jobs.any? { |job| job["args"] == [asset_preview.id] }
  end

  test "thumbnail_url returns nil without re-enqueueing when generation previously failed" do
    asset_preview = create_asset_preview_mov
    asset_preview.file.stubs(:previewable?).returns(true)
    Rails.cache.write("attachment_#{asset_preview.file.id}_poster_url", AssetPreview::FAILED_POSTER_SENTINEL)
    GenerateVideoPosterWorker.jobs.clear
    assert_nil asset_preview.thumbnail_url
    assert_empty GenerateVideoPosterWorker.jobs
  end

  test "thumbnail_url is exposed as the thumbnail in as_json" do
    asset_preview = create_asset_preview_mov
    asset_preview.stubs(:video_poster_url).returns("https://files.example.com/poster.jpg")
    assert_equal "https://files.example.com/poster.jpg", asset_preview.as_json[:thumbnail]
  end

  # --- #generate_video_poster! -----------------------------------------------

  test "generate_video_poster! extracts a poster frame and caches its URL" do
    asset_preview = create_asset_preview_mov
    preview = mock("preview")
    preview.stubs(:url).returns("https://files.example.com/poster.jpg")
    asset_preview.file.stubs(:previewable?).returns(true)
    processable = mock("processable")
    processable.stubs(:processed).returns(preview)
    asset_preview.file.stubs(:preview).returns(processable)

    assert_equal "https://files.example.com/poster.jpg", asset_preview.generate_video_poster!
    assert_equal "https://files.example.com/poster.jpg", Rails.cache.read("attachment_#{asset_preview.file.id}_poster_url")
  end

  test "generate_video_poster! returns nil instead of raising when poster generation fails" do
    asset_preview = create_asset_preview_mov
    asset_preview.file.stubs(:previewable?).returns(true)
    asset_preview.file.stubs(:preview).raises(ActiveStorage::UnpreviewableError)
    assert_nil asset_preview.generate_video_poster!
  end

  test "generate_video_poster! remembers failed generation and does not retry on the next call" do
    asset_preview = create_asset_preview_mov
    asset_preview.file.stubs(:previewable?).returns(true)
    asset_preview.file.expects(:preview).once.raises(ActiveStorage::UnpreviewableError)

    assert_nil asset_preview.generate_video_poster!
    assert_nil asset_preview.generate_video_poster!
  end

  test "generate_video_poster! gives up and returns nil when generation exceeds the timeout" do
    asset_preview = create_asset_preview_mov
    asset_preview.file.stubs(:previewable?).returns(true)
    Timeout.stubs(:timeout).with(AssetPreview::IMAGE_PROCESSING_TIMEOUT_SECONDS).raises(Timeout::Error)
    assert_nil asset_preview.generate_video_poster!
  end

  # --- poster generation enqueueing on create --------------------------------

  test "enqueues poster generation when a video cover is created" do
    asset_preview = create_asset_preview_mov
    assert GenerateVideoPosterWorker.jobs.any? { |job| job["args"] == [asset_preview.id] }
  end

  test "does not enqueue poster generation for image covers" do
    create_asset_preview_jpg
    assert_empty GenerateVideoPosterWorker.jobs
  end

  # --- #oembed_url -----------------------------------------------------------

  test "oembed_url returns nil when oembed is not present or has no iframe" do
    asset_preview = build_unsaved_asset_preview
    assert_nil asset_preview.oembed_url
    asset_preview.oembed = { "html" => "<div>No iframe here</div>" }
    assert_nil asset_preview.oembed_url
  end

  test "oembed_url returns nil for dangerous URLs" do
    asset_preview = build_unsaved_asset_preview
    DANGEROUS_URLS.each do |url|
      asset_preview.oembed = { "html" => "<iframe src=\"#{url}\"></iframe>" }
      assert_nil asset_preview.oembed_url, "expected #{url} to be rejected"
    end
  end

  test "oembed_url handles protocol-relative and absolute URLs" do
    asset_preview = build_unsaved_asset_preview
    {
      "//example.com/embed" => "https://example.com/embed",
      "https://example.com/embed" => "https://example.com/embed",
    }.each do |input, expected|
      asset_preview.oembed = { "html" => "<iframe src=\"#{input}\"></iframe>" }
      assert_equal expected, asset_preview.oembed_url
    end
  end

  test "oembed_url adds platform-specific parameters" do
    asset_preview = build_unsaved_asset_preview
    {
      "https://youtube.com/embed/123?feature=oembed" => "&enablejsapi=1",
      "https://vimeo.com/video/123" => "?api=1",
    }.each do |url, param|
      asset_preview.oembed = { "html" => "<iframe src=\"#{url}\"></iframe>" }
      assert_equal url + param, asset_preview.oembed_url
    end
  end

  # --- #display_height / #display_width --------------------------------------

  test "display_height computes the height scaled to the display width" do
    # Factory oembed info: 356x200. Display width caps at 356 (< 670).
    assert_equal 200, build_asset_preview_youtube.display_height
  end

  test "display_height returns nil when the width is zero instead of raising FloatDomainError" do
    # Some oEmbed providers report non-numeric widths (e.g. "auto"), which
    # to_i to 0. Dividing by 0.0 produces NaN and NaN.to_i raises
    # FloatDomainError, which crashed API product serialization (Sentry
    # GUMROAD-ZV). A zero width must degrade to nil dimensions instead.
    preview = build_asset_preview_youtube
    preview.oembed["info"]["width"] = "auto"

    assert_nil preview.display_height
  end

  test "display_width returns nil when the width is zero, matching display_height's contract" do
    preview = build_asset_preview_youtube
    preview.oembed["info"]["width"] = "auto"

    assert_nil preview.display_width
  end

  # --- #as_json --------------------------------------------------------------

  test "as_json serializes without raising when the oembed width is unusable" do
    preview = create_asset_preview_youtube
    preview.oembed["info"]["width"] = "auto"

    assert_nil preview.as_json[:height]
    assert_nil preview.as_json[:width]
  end

  test "as_json serializes without raising for an existing file cover analyzed as 0x0" do
    # The production trigger for Sentry GUMROAD-ZV: a video file that ffprobe
    # identifies but can't decode gets analyzed as width/height 0.0. New uploads
    # like this are now rejected by validation, but records created before that
    # validation still exist and must serialize.
    preview = create_asset_preview_mov
    preview.file.blob.update!(metadata: preview.file.blob.metadata.merge("width" => 0.0, "height" => 0.0))

    assert_nil preview.as_json[:width]
    assert_nil preview.as_json[:height]
  end

  # --- dimension validation --------------------------------------------------

  test "a file whose analyzed dimensions are zero is rejected" do
    # A 0x0 "video" (e.g. a truncated or mislabeled file that ffprobe identifies
    # but can't decode) must be rejected at upload time, the same as a file that
    # couldn't be analyzed at all. The record is deliberately unsaved: these are
    # upload-time validations, and a persisted cover has already passed them.
    preview = build_unsaved_asset_preview
    preview.file.attach(uploaded_fixture("thing.mov", "video/quicktime"))
    preview.file.blob.update!(metadata: { "identified" => true, "width" => 0.0, "height" => 0.0, "duration" => 0.04, "video" => true, "analyzed" => true })

    assert_not preview.valid?
    assert_includes preview.errors[:base], "Could not analyze cover. Please check the uploaded file."
  end

  # --- image file size validation --------------------------------------------

  test "an image cover larger than the size limit is rejected" do
    preview = build_unsaved_asset_preview
    preview.file.attach(uploaded_fixture("kFDzu.png", "image/png"))
    preview.file.blob.update!(byte_size: AssetPreview::MAX_IMAGE_FILE_SIZE + 1)

    assert_not preview.valid?
    assert_includes preview.errors[:base],
                    "Cover images must be smaller than 50 MB. Please resize or compress the image and try again."
  end

  test "an image cover at the size limit is accepted" do
    preview = build_unsaved_asset_preview
    preview.file.attach(uploaded_fixture("kFDzu.png", "image/png"))
    preview.file.blob.update!(byte_size: AssetPreview::MAX_IMAGE_FILE_SIZE)
    AssetPreviewAnalysisStub.analyze(preview.file)

    assert preview.valid?
  end

  test "the image size limit does not apply to video covers" do
    preview = build_unsaved_asset_preview
    preview.file.attach(uploaded_fixture("thing.mov", "video/quicktime"))
    preview.file.blob.update!(byte_size: AssetPreview::MAX_IMAGE_FILE_SIZE + 1)
    AssetPreviewAnalysisStub.analyze(preview.file)

    assert preview.valid?
  end

  # --- #oversized_image? -----------------------------------------------------

  test "oversized_image? is true when either dimension exceeds the maximum" do
    preview = create_asset_preview
    preview.file.blob.update!(metadata: preview.file.blob.metadata.merge("width" => AssetPreview::MAX_IMAGE_DIMENSION + 1, "height" => 500))

    assert preview.oversized_image?
  end

  test "oversized_image? is false for an image within the limit" do
    assert_not create_asset_preview.oversized_image?
  end

  test "oversized_image? is false for GIFs, which skip post-processing to preserve animation" do
    preview = create_asset_preview_gif
    preview.file.blob.update!(metadata: preview.file.blob.metadata.merge("width" => AssetPreview::MAX_IMAGE_DIMENSION + 1))

    assert_not preview.oversized_image?
  end

  test "oversized_image? is false for video covers" do
    preview = create_asset_preview_mov
    preview.file.blob.update!(metadata: preview.file.blob.metadata.merge("width" => AssetPreview::MAX_IMAGE_DIMENSION + 1))

    assert_not preview.oversized_image?
  end

  # --- oversized image resize enqueueing -------------------------------------

  test "creating an oversized image cover enqueues a resize" do
    preview = build_unsaved_asset_preview
    preview.file.attach(uploaded_fixture("kFDzu.png", "image/png"))
    preview.file.blob.update!(metadata: { "identified" => true, "width" => AssetPreview::MAX_IMAGE_DIMENSION + 1, "height" => 500, "analyzed" => true })
    ResizeOversizedAssetPreviewWorker.jobs.clear
    preview.save!

    assert_includes ResizeOversizedAssetPreviewWorker.jobs.map { _1["args"] }, [preview.id]
  end

  test "creating a normal-size cover does not enqueue a resize" do
    ResizeOversizedAssetPreviewWorker.jobs.clear
    create_asset_preview

    assert_equal 0, ResizeOversizedAssetPreviewWorker.jobs.size
  end

  # --- #resize_oversized_image! ----------------------------------------------

  test "resize_oversized_image! replaces the file with a copy resized within the dimension limit" do
    preview = create_asset_preview
    # The fixture is 1633x512; pretend analysis found it oversized so the resize
    # path runs, then let the real variant processing + re-analysis restore
    # truthful metadata for the replacement file.
    preview.file.blob.update!(metadata: preview.file.blob.metadata.merge("width" => AssetPreview::MAX_IMAGE_DIMENSION + 1))
    original_blob_id = preview.file.blob.id

    preview.resize_oversized_image!
    preview.reload

    assert_not_equal original_blob_id, preview.file.blob.id
    assert_operator preview.width, :<=, AssetPreview::MAX_IMAGE_DIMENSION
    assert_operator preview.height, :<=, AssetPreview::MAX_IMAGE_DIMENSION
  end

  test "resize_oversized_image! does nothing when the image is not oversized" do
    preview = create_asset_preview
    original_blob_id = preview.file.blob.id

    preview.resize_oversized_image!

    assert_equal original_blob_id, preview.reload.file.blob.id
  end

  test "resize_oversized_image! does not overwrite a cover that was replaced while it ran" do
    preview = create_asset_preview
    preview.file.blob.update!(metadata: preview.file.blob.metadata.merge("width" => AssetPreview::MAX_IMAGE_DIMENSION + 1))

    replacement_blob_id = nil
    # Simulate the seller replacing the cover in the window between the slow
    # variant processing and the attach of the resized copy.
    around_variant(preview) do
      AssetPreview.find(preview.id).file.attach(uploaded_fixture("kFDzu.png", "image/png"))
      replacement_blob_id = AssetPreview.find(preview.id).file.blob.id
    end

    preview.resize_oversized_image!

    assert_equal replacement_blob_id, preview.reload.file.blob.id
  end

  test "resize_oversized_image! does not attach the resized copy when the preview was deleted while it ran" do
    preview = create_asset_preview
    preview.file.blob.update!(metadata: preview.file.blob.metadata.merge("width" => AssetPreview::MAX_IMAGE_DIMENSION + 1))
    original_blob_id = preview.file.blob.id

    around_variant(preview) { AssetPreview.find(preview.id).mark_deleted! }

    preview.resize_oversized_image!

    assert_equal original_blob_id, preview.reload.file.blob.id
  end

  test "resize_oversized_image! cleans up the uploaded resized copy when the attach raises" do
    preview = create_asset_preview
    preview.file.blob.update!(metadata: preview.file.blob.metadata.merge("width" => AssetPreview::MAX_IMAGE_DIMENSION + 1))
    original_blob_id = preview.file.blob.id

    preview.file.stubs(:attach).raises(ActiveRecord::ConnectionTimeoutError)

    uploaded_blob = capturing_uploaded_blob do
      assert_raises(ActiveRecord::ConnectionTimeoutError) { preview.resize_oversized_image! }
    end

    # The worker retry will re-upload, so the copy from this failed attempt must
    # not be left orphaned in storage.
    purged_gids = ActiveJob::Base.queue_adapter.enqueued_jobs.filter_map do |job|
      job["arguments"].first["_aj_globalid"] if job["job_class"] == "ActiveStorage::PurgeJob"
    end
    assert_includes purged_gids, uploaded_blob.to_global_id.to_s
    assert_equal original_blob_id, preview.reload.file.blob.id
  end

  private
    DANGEROUS_URLS = [
      "javascript:alert('xss')",
      "data:text/html,<script>alert('xss')</script>",
      "vbscript:msgbox('xss')",
      "file:///etc/passwd",
      " javascript:alert('xss')",
      "JavaScript:alert('xss')",
      "\njavascript:alert('xss')",
    ].freeze

    # A blob uploaded from a fixture and run through the real analyzer — used for
    # the negative-path tests that attach a corrupt/disguised file.
    def analyzed_blob(filename, content_type)
      blob = ActiveStorage::Blob.create_and_upload!(
        io: Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures", filename), content_type),
        filename:, content_type:
      )
      blob.analyze
      blob
    end

    # The RSpec suite stubs SsrfFilter.get to delegate to HTTParty (so recorded
    # cassettes replay) for every example except the SSRF-protection ones. Only
    # the download path needs it here, so scope it to the block and restore after.
    def with_ssrf_passthrough
      original = SsrfFilter.method(:get)
      SsrfFilter.define_singleton_method(:get) { |url, **_opts| HTTParty.get(url) }
      yield
    ensure
      SsrfFilter.singleton_class.send(:define_method, :get, original)
    end

    def ffprobe_available?
      system("ffprobe", "-version", out: File::NULL, err: File::NULL)
    end

    # Runs the real analyzer (bypassing the factory stub) on a fixture file, the
    # way AssetPreview would for a genuine upload.
    def analyze_fixture(filename, content_type)
      blob = ActiveStorage::Blob.create_and_upload!(
        io: File.open(Rails.root.join("spec/support/fixtures", filename)), filename:, content_type:
      )
      blob.analyze
      asset_preview = AssetPreview.new(link: create_product)
      asset_preview.file.attach(blob)
      asset_preview.save!
      asset_preview
    end

    # The RSpec `build(:asset_preview)` returns an unsaved record with no file
    # attached (the factory attaches only in before(:create)); the oembed-parsing
    # tests set the oembed hash on it directly.
    def build_unsaved_asset_preview
      AssetPreview.new(link: create_product)
    end

    # Puts a fixture file in the storage bucket under a key we choose and returns
    # its public URL, which is what `url=` is then given.
    #
    # The RSpec lane gets these objects from the `copyfixturefiles` container in
    # docker-compose-test-and-ci.yml; the Minitest job provisions empty buckets,
    # so the test supplies its own object. Choosing the key is the point for the
    # square-bracket case — ActiveStorage's own keys are random alphanumerics and
    # could never reproduce it. Only call this inside `with_real_s3`, where
    # ActiveStorage::Blob.service is the S3 service.
    def upload_public_fixture(filename, key:, content_type:)
      File.open(Rails.root.join("spec/support/fixtures", filename)) do |file|
        ActiveStorage::Blob.service.upload(key, file, content_type:)
      end
      "#{AWS_S3_ENDPOINT}/#{PUBLIC_STORAGE_S3_BUCKET}/#{key}"
    end

    # Lets `url=` download from MinIO, which lives on localhost in test.
    #
    # SsrfFilter refuses loopback and private addresses, which is exactly what the
    # SSRF tests above assert it still does — so rather than disabling the filter
    # for the whole suite (spec_helper.rb stubs it globally for every example),
    # fetch the object here and hand the response to the one call under test. The
    # code path being exercised is everything `url=` does around the fetch:
    # escaping, parsing, attaching and analyzing.
    def with_downloadable_url(url)
      response = HTTParty.get(url)
      assert_equal 200, response.code, "fixture object should be publicly readable at #{url}"
      SsrfFilter.stubs(:get).returns(response)
      yield
    end

    # Records the blob ActiveStorage uploads inside the block and returns it, while
    # still performing the real upload — mocha has no `and_call_original`.
    #
    # `create_and_upload!` is defined on ActiveStorage::Blob's own singleton class,
    # so the usual override-then-remove_method trick would delete the real method
    # for the rest of the process (every later test that attaches a file then
    # fails). Rebind the original instead.
    def capturing_uploaded_blob
      uploaded = nil
      original = ActiveStorage::Blob.method(:create_and_upload!)
      ActiveStorage::Blob.singleton_class.send(:define_method, :create_and_upload!) do |**kwargs|
        uploaded = original.call(**kwargs)
      end
      yield
      uploaded
    ensure
      ActiveStorage::Blob.singleton_class.send(:define_method, :create_and_upload!, original)
    end

    def uploaded_fixture(filename, content_type)
      Rack::Test::UploadedFile.new(Rails.root.join("spec/support/fixtures", filename), content_type)
    end

    # Runs `block` the next time the preview's variant is requested, then lets the
    # real variant call proceed — the RSpec original used `and_wrap_original`,
    # which mocha has no equivalent for. Used to simulate a seller replacing or
    # deleting the cover during the slow variant processing inside
    # resize_oversized_image!.
    def around_variant(preview, &block)
      attachment = preview.file
      original = attachment.method(:variant)
      attachment.define_singleton_method(:variant) do |*args, **kwargs|
        block.call
        original.call(*args, **kwargs)
      end
    end
end
