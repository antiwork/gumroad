# frozen_string_literal: true

require "test_helper"

# Ported from spec/models/asset_preview_spec.rb. AssetPreview attaches image/video
# covers or embeds oembed players. Objects are built with the shared
# ModelFactories helpers (create_asset_preview[_mov/_jpg/_gif]); dimension
# metadata is injected by AssetPreviewAnalysisStub instead of shelling out to the
# analyzer on every create.
#
# Storage: the RSpec suite runs against MinIO (S3), so several of its assertions
# match the S3 public-URL shape (AWS_S3_ENDPOINT/S3_BUCKET/<key>). The Minitest
# job has no MinIO and uses a local Disk service, where file.url is a signed URL
# that base64-encodes the key. Those URL-shape assertions are rewritten to
# service-agnostic checks of the same behavior (a file/variant is attached; url
# picks the retina variant for images, the original for gifs/videos). The two
# `#url=` tests that download from a MinIO URL, and the two poster tests that
# would run a real ffmpeg preview, keep their coverage where feasible and are
# otherwise documented as skips.
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

  test "url= downloads and attaches a public URL (incl. square-bracket encoding)" do
    skip "the two public-URL cases download from the MinIO S3 endpoint, which the lightweight Minitest CI job doesn't run (and SsrfFilter blocks the localhost address); the assertions also match the S3 URL shape rather than the Disk service's"
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

  test "retina_variant falls back to the original file URL when image processing times out" do
    asset_preview = create_asset_preview
    asset_preview.file.stubs(:variant).raises(Timeout::Error)
    assert_equal asset_preview.file.url, asset_preview.url_from_file(style: :retina)
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
end
