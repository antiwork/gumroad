# frozen_string_literal: true

require "spec_helper"

describe PartnerMigration::RemoteFileTransfer do
  let(:seller) { create(:user) }

  def stub_download(body, code: "200", content_length: nil, content_disposition: nil)
    allow(SsrfFilter).to receive(:get) do |_url, &block|
      response = (Net::HTTPResponse::CODE_TO_OBJ[code] || Net::HTTPResponse::CODE_CLASS_TO_OBJ.fetch(code[0])).new("1.1", code, "")
      response["content-length"] = content_length.to_s if content_length
      response["content-disposition"] = content_disposition if content_disposition
      allow(response).to receive(:read_body).and_yield(body)
      block&.call(response)
      response
    end
  end

  it "copies the file into the seller's attachments folder" do
    stub_download("zip bytes")

    url = described_class.new(seller:, url: "https://files.example.com/packs/Texture%20Pack.zip").perform

    expect(url).to start_with("#{S3_BASE_URL}attachments/#{seller.external_id}/")
    expect(url).to end_with("/original/Texture Pack.zip")
    expect(Aws::S3::Resource.new.bucket(S3_BUCKET).object(url.delete_prefix(S3_BASE_URL)).get.body.read).to eq("zip bytes")
  end

  it "uses the filename from the Content-Disposition header" do
    stub_download("zip bytes", content_disposition: 'attachment; filename="Texture Pack.zip"')

    url = described_class.new(seller:, url: "https://files.example.com/download?id=123").perform

    expect(url).to end_with("/original/Texture Pack.zip")
  end

  it "replaces bytes that are not valid UTF-8 in the filename" do
    stub_download("zip bytes", content_disposition: "attachment; filename*=UTF-8''Caf%E9.zip")

    url = described_class.new(seller:, url: "https://files.example.com/caf%E9.zip").perform

    expect(url).to end_with("/original/Caf_.zip")
  end

  it "adds the extension of the detected type to a filename without one" do
    stub_download(File.binread(Rails.root.join("spec/support/fixtures/smilie.png")))

    url = described_class.new(seller:, url: "https://files.example.com/download?id=123").perform

    expect(url).to end_with("/original/download.png")
  end

  it "stops a download that runs past the time limit" do
    stub_const("#{described_class}::MAX_DOWNLOAD_DURATION", -1.second)
    stub_download("zip bytes")

    expect { described_class.new(seller:, url: "https://files.example.com/pack.zip").perform }.to raise_error(described_class::TemporaryError, /took longer than/)
  end

  it "rejects a file larger than the product file limit" do
    stub_download("", content_length: described_class::MAX_BYTES + 1)

    expect { described_class.new(seller:, url: "https://files.example.com/huge.zip").perform }.to raise_error(described_class::Error, /larger than/)
  end

  it "stops a download that grows past the limit without a content-length header" do
    stub_const("#{described_class}::MAX_BYTES", 4)
    stub_download("12345")

    expect { described_class.new(seller:, url: "https://files.example.com/pack.zip").perform }.to raise_error(described_class::Error, /larger than/)
  end

  it "rejects a failed download" do
    stub_download("", code: "404")

    expect { described_class.new(seller:, url: "https://files.example.com/missing.zip").perform }.to raise_error(described_class::Error, "The file download failed with HTTP 404.")
  end

  it "raises a temporary error for a response that can succeed later" do
    stub_download("", code: "503")

    expect { described_class.new(seller:, url: "https://files.example.com/pack.zip").perform }.to raise_error(described_class::TemporaryError, "The file download failed with HTTP 503.")
  end

  it "treats every 5xx response as temporary" do
    stub_download("", code: "520")

    expect { described_class.new(seller:, url: "https://files.example.com/pack.zip").perform }.to raise_error(described_class::TemporaryError, "The file download failed with HTTP 520.")
  end

  it "rejects a URL that is not https" do
    expect { described_class.new(seller:, url: "http://files.example.com/pack.zip").perform }.to raise_error(described_class::Error, "Only https URLs are supported.")
  end

  it "does not follow a redirect to an http URL", :skip_ssrf_stub do
    allow(Resolv).to receive(:getaddresses).with("files.example.com").and_return(["93.184.215.14"])
    stub_request(:get, "https://files.example.com/pack.zip").to_return(status: 302, headers: { "Location" => "http://files.example.com/pack.zip" })
    stub_request(:get, "http://files.example.com/pack.zip").to_return(status: 200, body: "zip bytes")

    expect { described_class.new(seller:, url: "https://files.example.com/pack.zip").perform }.to raise_error(SsrfFilter::InvalidUriScheme)
  end

  it "blocks a private address", :skip_ssrf_stub do
    expect { described_class.new(seller:, url: "https://127.0.0.1/pack.zip").perform }.to raise_error(SsrfFilter::PrivateIPAddress)
  end
end
