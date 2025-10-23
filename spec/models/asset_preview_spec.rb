# frozen_string_literal: true

require "spec_helper"

describe AssetPreview, :vcr do
  describe "Attachment" do
    it "scales down a big image and keeps original" do
      asset_preview = create(:asset_preview)
      expect(asset_preview.file.url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{asset_preview.file.key}")
      expect(asset_preview.retina_variant.url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{asset_preview.retina_variant.key}")
      expect(asset_preview.width).to eq(1633)
      expect(asset_preview.height).to eq(512)
      expect(asset_preview.display_width).to eq(670)
      expect(asset_preview.display_height).to eq(210)
      expect(asset_preview.retina_width).to eq(1005)
    end

    it "does not scale up a smaller image" do
      asset_preview = create(:asset_preview_jpg)
      expect(asset_preview.width).to eq(25)
      expect(asset_preview.height).to eq(25)
      expect(asset_preview.display_width).to eq(25)
      expect(asset_preview.display_height).to eq(25)
    end

    it "succeeds with video" do
      asset_preview = create(:asset_preview_mov)
      expect(asset_preview.url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{asset_preview.file.key}")
    end

    it "doesn't post process GIFs and keeps the original" do
      asset_preview = create(:asset_preview_gif)
      expect(asset_preview.url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{asset_preview.file.key}")
      expect(asset_preview.display_width).to eq(670)
      expect(asset_preview.display_height).to eq(500)
      expect(asset_preview.retina_width).to eq(670)
    end

    it "fails with an arbitrary filetype" do
      asset_preview = create(:asset_preview)
      asset_preview.file.attach Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "test.zip"), "application/octet-stream")
      expect(asset_preview.save).to eq(false)
      expect(asset_preview.errors.full_messages).to eq(["Could not process your preview, please try again."])
    end

    describe "#analyze_file" do
      it "fails with a video which cannot be analyzed" do
        asset_preview = create(:asset_preview)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("invalid_asset_preview_video.MOV"), filename: "invalid_asset_preview_video.MOV", content_type: "video/quicktime")
        blob.analyze
        asset_preview.file.attach(blob)
        expect(asset_preview.save).to eq(false)
        expect(asset_preview.errors.full_messages).to include("Could not analyze cover. Please check the uploaded file.")
      end

      it "fails with a script disguised as an image" do
        asset_preview = create(:asset_preview)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("disguised_html_script.png"), filename: "disguised_html_script.png", content_type: "image/png")
        blob.analyze
        asset_preview.file.attach(blob)
        expect(asset_preview.save).to eq(false)
        expect(asset_preview.errors.full_messages).to include("Could not process your preview, please try again.")
      end

      it "fails with an image which cannot be analyzed" do
        asset_preview = create(:asset_preview)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("invalid_asset_preview_image.jpeg"), filename: "invalid_asset_preview_image.jpeg", content_type: "image/jpeg")
        blob.analyze
        asset_preview.file.attach(blob)
        expect(asset_preview.save).to eq(false)
        expect(asset_preview.errors.full_messages).to include("Could not analyze cover. Please check the uploaded file.")
      end
    end

    it "does not allow unsupported image formats" do
      asset_preview = create(:asset_preview)
      asset_preview.file.attach(Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "webp_image.webp"), "image/webp"))
      expect(asset_preview.save).to eq(false)
      expect(asset_preview.errors.full_messages).to eq(["Could not process your preview, please try again."])
    end

    context "deleted" do
      it "allows marking deleted existing records with unsupported image formats " do
        asset_preview = create(:asset_preview)
        asset_preview.file.attach(Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "webp_image.webp"), "image/webp"))
        asset_preview.save(validate: false)
        asset_preview.reload
        asset_preview.mark_deleted!

        expect(asset_preview.reload).to be_deleted
      end
    end
  end

  describe "Embeddable link" do
    it "succeeds with a video URL" do
      asset_preview = create(:asset_preview, url: "https://www.youtube.com/watch?v=huKYieB4evw")
      expect(asset_preview.display_type).to eq("oembed")
      expect(asset_preview.url).to eq("https://www.youtube.com/embed/huKYieB4evw?feature=oembed&showinfo=0&controls=0&rel=0&enablejsapi=1")
      expect(asset_preview.oembed_thumbnail_url).to eq("https://i.ytimg.com/vi/huKYieB4evw/hqdefault.jpg")
    end

    it "succeeds with a sound URL" do
      asset_preview = create(:asset_preview, url: "https://soundcloud.com/user-656397481/tbl31-here-comes-the-new-year")
      expect(asset_preview.display_type).to eq("oembed")
      expect(asset_preview.oembed_url).to eq("https://w.soundcloud.com/player/?visual=true&url=https%3A%2F%2Fapi.soundcloud.com%2Ftracks%2F376574774&auto_play=false&show_artwork=false&show_comments=false&buying=false&sharing=false&download=false&show_playcount=false&show_user=false&liking=false&maxwidth=670")
      expect(asset_preview.oembed_thumbnail_url).to match("https://i1.sndcdn.com/artworks-000278260091-nbg7dg-t500x500.jpg")
    end

    it "fails with a dodgy URL and keeps attachment" do
      expect do
        expect do
          asset_preview = AssetPreview.new(link: create(:product))
          asset_preview.url = "https://www.nsa.gov"
          asset_preview.save!
        end.to raise_error(ActiveRecord::RecordInvalid)
      end.to_not change { AssetPreview.count }
    end

    it "fails when oembed has no width or height" do
      expect do
        expect(OEmbedFinder).to receive(:embeddable_from_url)
          .and_return({ html: "<iframe src=\"https://madeup.url\"></iframe>",
                        info: { "thumbnail_url" => "https://madeup.thumbnail.url" } })
        allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
        asset_preview = create(:asset_preview)
        asset_preview.url = "https://madeup.url"
        asset_preview.save!
      end.to raise_error(ActiveRecord::RecordInvalid,
                         "Validation failed: Could not analyze cover. Please check the uploaded file.")
    end

    it "fails if URL is not of a supported provider" do
      expect do
        create(:asset_preview, url: "https://www.tiktok.com/@soflofooodie/video/7164885074863787307")
      end.to raise_error(ActiveRecord::RecordInvalid,
                         "Validation failed: A URL from an unsupported platform was provided. Please try again.")
    end
  end

  describe "#url=" do
    let(:asset_preview) { create(:asset_preview) }

    it "works as expected with a public URL" do
      expect do
        asset_preview.url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test.png"
        asset_preview.analyze_file
        asset_preview.save!
      end.to_not raise_error

      expect(asset_preview.file.url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{asset_preview.file.key}")
      expect(asset_preview.retina_variant.url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{asset_preview.retina_variant.key}")
    end

    it "works as expected when a URL with square brackets is encoded and passed as an argument" do
      expect do
        asset_preview.url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/specs/test-small+with+%5Bsquare+brackets%5D.jpg"
        asset_preview.analyze_file
        asset_preview.save!
      end.to_not raise_error

      expect(asset_preview.file.url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{asset_preview.file.key}")
      expect(asset_preview.retina_variant.url).to match("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/#{asset_preview.retina_variant.key}")
    end

    it "prevents non-http urls from being downloaded" do
      expect do
        asset_preview.url = "/etc/sudoers"
      end.to raise_error(URI::InvalidURIError, /not a web url/)
    end
  end

  it "auto-generates a GUID on creation" do
    asset_preview = create(:asset_preview)

    expect(asset_preview.guid).to be_present
  end

  it "does not auto-generate a GUID on creation if one is supplied" do
    guid = "a" * 32 # Same length as one generated by `SecureRandom.hex`
    asset_preview = create(:asset_preview, guid:)

    expect(asset_preview.guid).to be_present
    expect(asset_preview.guid).to eq(guid)
  end

  describe "product update on save" do
    it "updates the updated_at timestamp of the product after creating asset_preview" do
      product = create(:product, updated_at: 1.month.ago)

      travel_to(Time.current) do
        expect do
          create(:asset_preview, link: product)
        end.to change { product.updated_at }.to(Time.current)
      end
    end
  end

  describe "position" do
    it "auto-increments position on creation" do
      product = create(:product)

      a = create(:asset_preview, link: product)
      expect(a.position).to eq 0

      b = create(:asset_preview, link: product)
      expect(b.position).to eq 1

      c = create(:asset_preview, link: product)
      expect(c.position).to eq 2

      b.mark_deleted!

      d = create(:asset_preview, link: product)
      expect(d.position).to eq 3
    end

    it "properly sets position on creation if the previous preview is missing position" do
      product = create(:product)

      pre_existing = create(:asset_preview, link: product)
      pre_existing.position = nil
      pre_existing.save!

      a = create(:asset_preview, link: product)
      expect(a.position).to eq 1

      b = create(:asset_preview, link: product)
      expect(b.position).to eq 2
    end
  end

  describe "file attachment" do
    let!(:asset_preview) { create(:asset_preview) }

    context "with file attached" do
      it "returns proper width" do
        expect(asset_preview.width).to eq(1633)
        expect(asset_preview.display_width).to eq(670)
        expect(asset_preview.retina_width).to eq(1005)
      end

      it "returns proper height" do
        expect(asset_preview.height).to eq(512)
        expect(asset_preview.display_height).to eq(210)
      end

      describe "#url" do
        it "returns retina variant" do
          expect(asset_preview.url).to match(asset_preview.retina_variant.key)
        end

        it "returns original file for non-image files" do
          asset_preview.file.attach(Rack::Test::UploadedFile.new(
                                      Rails.root.join("spec", "support", "fixtures", "sample.gif"), "image/gif"))
          asset_preview.save!
          asset_preview.file.analyze
          expect(asset_preview.url).to match(asset_preview.file.url)
        end

        it "works well with video types" do
          asset_preview.file.attach(Rack::Test::UploadedFile.new(
                                      Rails.root.join("spec", "support", "fixtures", "thing.mov"), "video/quicktime"))
          asset_preview.save!
          asset_preview.file.analyze
          expect(asset_preview.url).to match(asset_preview.file.url)
        end
      end
    end
  end

  describe "callbacks" do
    describe "#reset_moderated_by_iffy_flag" do
      let(:product) { create(:product, moderated_by_iffy: true) }
      let(:asset_preview) { create(:asset_preview, link: product) }

      context "when a new asset preview is created" do
        it "resets moderated_by_iffy flag on the associated product" do
          expect do
            create(:asset_preview, link: product)
          end.to change { product.reload.moderated_by_iffy }.from(true).to(false)
        end
      end
    end
  end

  describe "#image_url?" do
    it "returns true for image assets" do
      image = create(:asset_preview_jpg)
      expect(image.image_url?).to eq(true)

      video = create(:asset_preview_mov)
      expect(video.image_url?).to eq(false)
    end
  end

  shared_examples "rejects unsafe URLs" do |method, url_key|
    let(:asset_preview) { build(:asset_preview) }
    let(:dangerous_urls) do
      [
        "javascript:alert('xss')",
        "data:text/html,<script>alert('xss')</script>",
        "vbscript:msgbox('xss')",
        "file:///etc/passwd",
        " javascript:alert('xss')",  # Leading whitespace
        "JavaScript:alert('xss')",   # Mixed case
        "\njavascript:alert('xss')"  # Leading newline
      ]
    end

    it "returns nil for dangerous URLs" do
      dangerous_urls.each do |url|
        if method == :oembed_thumbnail_url
          asset_preview.oembed = { "info" => { url_key => url } }
        else
          asset_preview.oembed = { "html" => "<iframe src=\"#{url}\"></iframe>" }
        end
        expect(asset_preview.public_send(method)).to be_nil, "Expected #{url} to be rejected"
      end
    end
  end

  describe "#oembed_thumbnail_url" do
    let(:asset_preview) { build(:asset_preview) }

    it "returns nil when oembed is not present" do
      expect(asset_preview.oembed_thumbnail_url).to be_nil
    end

    it "returns nil for blank thumbnail URLs" do
      ["", " "].each do |blank_url|
        asset_preview.oembed = { "info" => { "thumbnail_url" => blank_url } }
        expect(asset_preview.oembed_thumbnail_url).to be_nil
      end
    end

    include_examples "rejects unsafe URLs", :oembed_thumbnail_url, "thumbnail_url"

    it "returns safe thumbnail URLs unchanged" do
      url = "https://example.com/thumb.jpg"
      asset_preview.oembed = { "info" => { "thumbnail_url" => url } }
      expect(asset_preview.oembed_thumbnail_url).to eq(url)
    end
  end

  describe "#oembed_url" do
    let(:asset_preview) { build(:asset_preview) }

    it "returns nil when oembed is not present or has no iframe" do
      expect(asset_preview.oembed_url).to be_nil

      asset_preview.oembed = { "html" => "<div>No iframe here</div>" }
      expect(asset_preview.oembed_url).to be_nil
    end

    include_examples "rejects unsafe URLs", :oembed_url, "src"

    it "handles protocol-relative and absolute URLs" do
      {
        "//example.com/embed" => "https://example.com/embed",
        "https://example.com/embed" => "https://example.com/embed"
      }.each do |input, expected|
        asset_preview.oembed = { "html" => "<iframe src=\"#{input}\"></iframe>" }
        expect(asset_preview.oembed_url).to eq(expected)
      end
    end

    it "adds platform-specific parameters" do
      {
        "https://youtube.com/embed/123?feature=oembed" => "&enablejsapi=1",
        "https://vimeo.com/video/123" => "?api=1"
      }.each do |url, param|
        asset_preview.oembed = { "html" => "<iframe src=\"#{url}\"></iframe>" }
        expect(asset_preview.oembed_url).to eq(url + param)
      end
    end
  end
end
