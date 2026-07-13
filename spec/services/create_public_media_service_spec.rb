# frozen_string_literal: true

require "spec_helper"

describe CreatePublicMediaService do
  let(:seller) { create(:user) }

  def fixture_path(name)
    Rails.root.join("spec", "support", "fixtures", name)
  end

  def uploaded_blob(fixture_name, content_type, uploaded_by: seller)
    ActiveStorage::Blob.create_and_upload!(
      io: Rack::Test::UploadedFile.new(fixture_path(fixture_name), content_type),
      filename: fixture_name,
      content_type:,
      metadata: uploaded_by ? { uploaded_by_user_id: uploaded_by.id } : {},
    )
  end

  # Stub SsrfFilter.get the same way the thumbnail specs do: a fake Net::HTTP response backed by a
  # fixture file, yielded to the streaming block and returned.
  def stub_remote_file(url, fixture_name, content_type, content_length: nil, response_class: Net::HTTPOK)
    body = File.binread(fixture_path(fixture_name))
    response = Class.new(response_class) do
      define_method(:initialize) do
        super("1.1", Net::HTTPResponse::CODE_TO_OBJ.key(response_class), "OK")
        @body = body
        @content_type = content_type
        @content_length = content_length
      end

      attr_reader :content_type

      def [](header)
        @content_length if header.downcase == "content-length"
      end

      def read_body
        yield @body
      end
    end.new

    allow(SsrfFilter).to receive(:get).with(url).and_yield(response).and_return(response)
  end

  describe "#process with a remote url" do
    it "downloads the file, hosts it as a PublicFile owned by the seller, and reports success" do
      url = "https://example.com/assets/logo.png?v=2"
      stub_remote_file(url, "smilie.png", "image/png")

      result = described_class.new(seller:, url:, name: "My logo").process

      expect(result).to be_success
      file = result.public_file
      expect(file).to be_persisted
      expect(file.seller).to eq(seller)
      expect(file.resource).to eq(seller)
      expect(file.display_name).to eq("My logo")
      expect(file.file).to be_attached
      expect(file.file_group).to eq("image")
      expect(SsrfFilter).to have_received(:get).with(url)
    end

    it "derives the file extension from the sniffed bytes when the url has none" do
      url = "https://example.com/logo"
      stub_remote_file(url, "smilie.png", "image/png")

      result = described_class.new(seller:, url:).process

      expect(result).to be_success
      expect(result.public_file.file.blob.filename.to_s).to end_with(".png")
      expect(result.public_file.file_group).to eq("image")
    end

    it "classifies the file by its actual bytes, not the extension or the server's content type" do
      # disguised_html_script.png is an HTML document with a .png name; the remote server also
      # (falsely) claims image/png. Magic-byte sniffing must see through both.
      url = "https://example.com/innocent.png"
      stub_remote_file(url, "disguised_html_script.png", "image/png")

      result = described_class.new(seller:, url:).process

      expect(result).not_to be_success
      expect(result.error_message).to match(/only image/i)
      expect(PublicFile.count).to eq(0)
    end

    it "rejects audio files until there is real media-byte moderation for them" do
      url = "https://example.com/track.mp3"
      stub_remote_file(url, "magic.mp3", "audio/mpeg")

      result = described_class.new(seller:, url:).process

      expect(result).not_to be_success
      expect(result.error_message).to match(/only image/i)
      expect(PublicFile.count).to eq(0)
    end

    it "rejects SVG even though it is an image type" do
      url = "https://example.com/logo.svg"
      stub_remote_file(url, "test-svg.svg", "image/svg+xml")

      result = described_class.new(seller:, url:).process

      expect(result).not_to be_success
      expect(result.error_message).to match(/only image/i)
    end

    it "rejects a download whose Content-Length exceeds the cap without storing anything" do
      url = "https://example.com/huge.mp4"
      stub_remote_file(url, "smilie.png", "video/mp4", content_length: described_class::MAX_IMAGE_BYTES + 1)

      result = described_class.new(seller:, url:).process

      expect(result).not_to be_success
      expect(result.error_message).to match(/too large/i)
      expect(PublicFile.count).to eq(0)
    end

    it "rejects an image larger than the image cap while streaming, before anything is stored" do
      url = "https://example.com/big.png"
      stub_remote_file(url, "smilie.png", "image/png")
      stub_const("#{described_class}::MAX_IMAGE_BYTES", 1.kilobyte)

      result = described_class.new(seller:, url:).process

      expect(result).not_to be_success
      expect(result.error_message).to match(/too large/i)
      # The image cap must abort the download itself — the file should never reach public
      # storage, not get uploaded and purged afterwards.
      expect(ActiveStorage::Blob.count).to eq(0)
    end

    it "reports an invalid url instead of raising when the SSRF guard rejects the host" do
      url = "https://internal.example.com/secret.png"
      allow(SsrfFilter).to receive(:get).with(url).and_raise(SsrfFilter::PrivateIPAddress.new("private"))

      result = described_class.new(seller:, url:).process

      expect(result).not_to be_success
      expect(result.error_message).to match(/valid public url/i)
    end

    it "rejects non-http(s) urls" do
      result = described_class.new(seller:, url: "ftp://example.com/file.png").process

      expect(result).not_to be_success
      expect(result.error_message).to match(/valid public url/i)
    end

    it "reports a friendly error when the remote fetch fails" do
      url = "https://example.com/missing.png"
      allow(SsrfFilter).to receive(:get).with(url).and_raise(SocketError.new("nope"))

      result = described_class.new(seller:, url:).process

      expect(result).not_to be_success
      expect(result.error_message).to match(/couldn't download/i)
    end
  end

  describe "#process with a signed_blob_id" do
    it "hosts an already-uploaded blob" do
      blob = uploaded_blob("smilie.png", "image/png")

      result = described_class.new(seller:, signed_blob_id: blob.signed_id).process

      expect(result).to be_success
      expect(result.public_file.file.blob).to eq(blob)
    end

    it "rejects an invalid signed_blob_id" do
      result = described_class.new(seller:, signed_blob_id: "garbage").process

      expect(result).not_to be_success
      expect(result.error_message).to match(/invalid or expired/i)
    end

    it "rejects a blob uploaded by another seller, with the same message as an invalid id" do
      other_seller = create(:user)
      blob = uploaded_blob("smilie.png", "image/png", uploaded_by: other_seller)

      result = described_class.new(seller:, signed_blob_id: blob.signed_id).process

      expect(result).not_to be_success
      expect(result.error_message).to match(/invalid or expired/i)
      expect(PublicFile.count).to eq(0)
      # The victim's blob must not be purged just because someone probed with its signed id.
      expect(blob.reload).to be_persisted
    end

    it "rejects a blob with no uploader stamp" do
      blob = uploaded_blob("smilie.png", "image/png", uploaded_by: nil)

      result = described_class.new(seller:, signed_blob_id: blob.signed_id).process

      expect(result).not_to be_success
      expect(result.error_message).to match(/invalid or expired/i)
    end

    it "rejects a blob that is already attached to another record" do
      blob = uploaded_blob("smilie.png", "image/png")
      existing = create(:public_file, seller:, resource: seller)
      existing.file.attach(blob.signed_id)

      result = described_class.new(seller:, signed_blob_id: blob.signed_id).process

      expect(result).not_to be_success
      expect(result.error_message).to match(/invalid or expired/i)
      expect(blob.reload).to be_persisted
    end
  end

  describe "input validation" do
    it "requires a url or signed_blob_id" do
      result = described_class.new(seller:).process

      expect(result).not_to be_success
      expect(result.error_message).to match(/url or signed_blob_id/i)
    end

    it "enforces the per-seller media file quota" do
      stub_const("#{described_class}::MAX_ALIVE_MEDIA_FILES_PER_SELLER", 1)
      create(:public_file, seller:, resource: seller)

      result = described_class.new(seller:, url: "https://example.com/logo.png").process

      expect(result).not_to be_success
      expect(result.error_message).to match(/limit/i)
    end

    it "re-checks the quota under lock before saving so a concurrent upload can't exceed it" do
      stub_const("#{described_class}::MAX_ALIVE_MEDIA_FILES_PER_SELLER", 1)
      url = "https://example.com/logo.png"
      stub_remote_file(url, "smilie.png", "image/png")

      # Simulate losing the race: the early check sees zero files, but by the time the locked
      # re-check runs, another request has already filled the seller's last quota slot.
      allow(seller).to receive(:lock!) do
        create(:public_file, seller:, resource: seller)
        seller
      end

      result = nil
      expect do
        result = described_class.new(seller:, url:).process
      end.not_to change { PublicFile.count }
      # (The simulated racing file is created inside the quota transaction, so the raise rolls
      # it back along with everything else — the point is this upload never saved a record.)

      expect(result).not_to be_success
      expect(result.error_message).to match(/limit/i)
      expect(ActiveStorage::Blob.count).to eq(0) # the rejected download was purged
    end
  end

  describe "content moderation" do
    before { Feature.activate(:content_moderation) }
    after { Feature.deactivate(:content_moderation) }

    it "rejects a flagged file and purges the blob so it isn't left publicly hosted" do
      url = "https://example.com/logo.png"
      stub_remote_file(url, "smilie.png", "image/png")
      flagged = ContentModeration::Strategies::ClassifierStrategy::Result.new(status: "flagged", reasoning: ["OpenAI moderation flagged: violence (score: 0.95, threshold: 0.9)"])
      allow_any_instance_of(ContentModeration::Strategies::ClassifierStrategy).to receive(:perform).and_return(flagged)

      expect do
        result = described_class.new(seller:, url:).process

        expect(result).not_to be_success
        expect(result.error_message).to match(/content guidelines/i)
      end.not_to change { PublicFile.count }

      expect(ActiveStorage::Blob.count).to eq(0)
    end

    it "skips moderation for verified sellers" do
      seller.update!(verified: true)
      url = "https://example.com/logo.png"
      stub_remote_file(url, "smilie.png", "image/png")
      expect_any_instance_of(ContentModeration::Strategies::ClassifierStrategy).not_to receive(:perform)

      result = described_class.new(seller:, url:).process

      expect(result).to be_success
    end

    it "passes the hosted image url to the moderation strategies for images" do
      url = "https://example.com/logo.png"
      stub_remote_file(url, "smilie.png", "image/png")
      compliant = ContentModeration::Strategies::ClassifierStrategy::Result.new(status: "compliant", reasoning: [])
      expect(ContentModeration::Strategies::ClassifierStrategy).to receive(:new) do |text:, image_urls:|
        expect(image_urls.size).to eq(1)
        instance_double(ContentModeration::Strategies::ClassifierStrategy, perform: compliant)
      end
      allow(ContentModeration::Strategies::PromptStrategy).to receive(:new).and_return(instance_double(ContentModeration::Strategies::PromptStrategy, perform: compliant))

      result = described_class.new(seller:, url:).process

      expect(result).to be_success
    end
  end
end
