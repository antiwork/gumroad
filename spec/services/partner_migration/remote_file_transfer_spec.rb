# frozen_string_literal: true

require "spec_helper"

describe PartnerMigration::RemoteFileTransfer do
  let(:seller) { create(:user) }

  def stub_download(body, code: "200", content_length: nil, content_disposition: nil)
    allow(SsrfFilter).to receive(:get) do |_url, &block|
      response = (Net::HTTPResponse::CODE_TO_OBJ[code] || Net::HTTPResponse::CODE_CLASS_TO_OBJ.fetch(code[0])).new("1.1", code, "")
      response["content-length"] = content_length.to_s if content_length
      response["content-disposition"] = content_disposition if content_disposition
      chunks = Array(body)
      allow(response).to receive(:read_body) { |&read| chunks.each(&read) }
      @last_response = response
      block&.call(response)
      response
    end
  end

  def seller_objects
    Aws::S3::Resource.new.bucket(S3_BUCKET).objects(prefix: "attachments/#{seller.external_id}/").to_a
  end

  it "copies the file into the seller's attachments folder" do
    stub_download("zip bytes")

    url = described_class.new(seller:, url: "https://files.example.com/packs/Texture%20Pack.zip").perform

    expect(url).to start_with("#{S3_BASE_URL}attachments/#{seller.external_id}/")
    expect(url).to end_with("/original/Texture Pack.zip")
    expect(Aws::S3::Resource.new.bucket(S3_BUCKET).object(url.delete_prefix(S3_BASE_URL)).get.body.read).to eq("zip bytes")
  end

  it "streams a binary file across chunks and parts into S3 without a tempfile for the whole file" do
    stub_const("#{described_class}::UPLOAD_PART_SIZE", 5.megabytes)
    bytes = Random.bytes(12.megabytes)
    stub_download((0...bytes.bytesize).step(1.megabyte).map { bytes.byteslice(_1, 1.megabyte) })
    allow(Tempfile).to receive(:new).and_call_original

    url = described_class.new(seller:, url: "https://files.example.com/pack.zip").perform

    # Only the SDK's part buffers touch the disk, never a tempfile for the whole file.
    expect(Tempfile).to have_received(:new).with("aws-sdk-s3-upload_stream").at_least(:once)
    expect(Tempfile).not_to have_received(:new).with("partner-migration", anything)

    expect(Aws::S3::Resource.new.bucket(S3_BUCKET).object(url.delete_prefix(S3_BASE_URL)).get.body.read.b).to eq(bytes.b)
  end

  it "reports the storage error, not the closed pipe, when a part fails to upload" do
    stub_const("#{described_class}::UPLOAD_PART_SIZE", 5.megabytes)
    stub_download((0...12).map { Random.bytes(1.megabyte) })
    # One concrete client: the SDK's upload threads call it at the same time, and any_instance stubs are not thread-safe.
    client = Aws::S3::Client.new
    allow(client).to receive(:upload_part).and_raise(Aws::S3::Errors::AccessDenied.new(nil, "Access Denied"))
    allow(Aws::S3::Client).to receive(:new).and_return(client)

    expect { described_class.new(seller:, url: "https://files.example.com/pack.zip").perform }.to raise_error(Aws::S3::Errors::AccessDenied)
  end

  it "keeps the size limit error when aborting the upload fails too" do
    stub_const("#{described_class}::MAX_BYTES", 5)
    stub_const("#{described_class}::SNIFF_BYTES", 2)
    stub_download(%w[123 45 6])
    expect_any_instance_of(Aws::S3::Client).to receive(:create_multipart_upload).and_call_original
    allow_any_instance_of(Aws::S3::Client).to receive(:abort_multipart_upload).and_raise(Aws::S3::Errors::NoSuchUpload.new(nil, "No such upload"))

    expect { described_class.new(seller:, url: "https://files.example.com/pack.zip").perform }.to raise_error(described_class::Error, /larger than/)
  end

  it "reads a redirect's body under a limit" do
    stub_const("#{described_class}::MAX_REDIRECT_BODY_BYTES", 4)
    allow(SsrfFilter).to receive(:get) do |_url, &block|
      redirect = Net::HTTPFound.new("1.1", "302", "")
      allow(redirect).to receive(:read_body) { |&read| %w[123 45].each(&read) }
      block.call(redirect)
      redirect
    end

    expect { described_class.new(seller:, url: "https://files.example.com/pack.zip").perform }.to raise_error(described_class::Error, "The redirect page is larger than 4 Bytes.")
  end

  it "applies one download's time limit to its redirects too" do
    allow(SsrfFilter).to receive(:get) do |_url, &block|
      redirect = Net::HTTPFound.new("1.1", "302", "")
      allow(redirect).to receive(:read_body) { |&read| ["moved"].each(&read) }
      block.call(redirect)
      redirect
    end

    expect { described_class.download("https://files.example.com/avatar.png", max_bytes: 1.megabyte, max_duration: -1.second) { } }.to raise_error(described_class::TemporaryError, /took longer than/)
  end

  it "keeps only the last attempt's body in a downloaded tempfile" do
    allow(SsrfFilter).to receive(:get) do |_url, &block|
      %w[broken-first-attempt cover-bytes].map do |body|
        Net::HTTPOK.new("1.1", "200", "").tap do |response|
          allow(response).to receive(:read_body) { |&read| [body].each(&read) }
          block.call(response)
        end
      end.last
    end

    described_class.download("https://files.example.com/cover.png", max_bytes: 1.megabyte) do |tempfile, _filename|
      expect(tempfile.read).to eq("cover-bytes")
    end
  end

  it "follows a redirect to the file" do
    allow(SsrfFilter).to receive(:get) do |_url, &block|
      redirect = Net::HTTPFound.new("1.1", "302", "")
      allow(redirect).to receive(:read_body) { |&read| ["moved"].each(&read) }
      block.call(redirect)
      file = Net::HTTPOK.new("1.1", "200", "")
      allow(file).to receive(:read_body) { |&read| ["zip bytes"].each(&read) }
      block.call(file)
      file
    end

    url = described_class.new(seller:, url: "https://files.example.com/pack.zip").perform

    expect(Aws::S3::Resource.new.bucket(S3_BUCKET).object(url.delete_prefix(S3_BASE_URL)).get.body.read).to eq("zip bytes")
  end

  it "keeps an empty file" do
    stub_download("")

    url = described_class.new(seller:, url: "https://files.example.com/empty.txt").perform

    expect(Aws::S3::Resource.new.bucket(S3_BUCKET).object(url.delete_prefix(S3_BASE_URL)).content_length).to eq(0)
  end

  it "uses the filename from the Content-Disposition header" do
    stub_download("zip bytes", content_disposition: 'attachment; filename="Texture Pack.zip"')

    url = described_class.new(seller:, url: "https://files.example.com/download?id=123").perform

    expect(url).to end_with("/original/Texture Pack.zip")
  end

  it "does not read a plus sign in the URL path as a space" do
    stub_download("pdf bytes")

    url = described_class.new(seller:, url: "https://files.example.com/C++%20Guide.pdf").perform

    expect(url).to end_with("/original/C__ Guide.pdf")
  end

  it "replaces bytes that are not valid UTF-8 in the filename" do
    stub_download("zip bytes", content_disposition: "attachment; filename*=UTF-8''Caf%E9.zip")

    url = described_class.new(seller:, url: "https://files.example.com/caf%E9.zip").perform

    expect(url).to end_with("/original/Caf_.zip")
  end

  it "adds the extension of the detected type to a filename without one, also when the bytes arrive in small chunks" do
    stub_download(File.binread(Rails.root.join("spec/support/fixtures/smilie.png")).bytes.each_slice(4).map { _1.pack("C*") })

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
    stub_download(%w[123 45])

    expect { described_class.new(seller:, url: "https://files.example.com/pack.zip").perform }.to raise_error(described_class::Error, /larger than/)
    expect(seller_objects).to be_empty
  end

  it "rejects a failed download without reading its body" do
    stub_download("", code: "404")

    expect { described_class.new(seller:, url: "https://files.example.com/missing.zip").perform }.to raise_error(described_class::Error, "The file download failed with HTTP 404.")
    expect(@last_response).not_to have_received(:read_body)
  end

  it "rejects a response that ends before its declared length", :skip_ssrf_stub do
    allow(SsrfFilter).to receive(:get) do |_url, **options, &block|
      client = Net::HTTP.new("files.example.com")
      options.fetch(:http_options, {}).each { |key, value| client.public_send("#{key}=", value) }
      socket = Net::BufferedIO.new(StringIO.new("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort"))
      response = Net::HTTPResponse.read_new(socket)
      response.ignore_eof = client.ignore_eof
      response.reading_body(socket, true) { block.call(response) }
      response
    end

    expect { described_class.new(seller:, url: "https://files.example.com/pack.zip").perform }.to raise_error(EOFError)
    expect(seller_objects).to be_empty
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
