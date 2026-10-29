# frozen_string_literal: true

require "spec_helper"

describe "MCP server product files" do
  before do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")

    @seller = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @seller, name: "Field notes", price_cents: 1900)
    @stored_objects = []
    allow_any_instance_of(Aws::S3::Client).to receive(:put_object) { |_client, params| @stored_objects << params }
    @deleted_keys = []
    allow_any_instance_of(Aws::S3::Client).to receive(:delete_object) { |_client, params| @deleted_keys << params[:key] }
  end

  def fixture_path(name)
    Rails.root.join("spec", "support", "fixtures", name)
  end

  # Stub SsrfFilter.get the way the thumbnail and media-ingest specs do: a fake Net::HTTP response
  # backed by a fixture file, yielded to the streaming block and returned.
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

  def file_embed(file)
    { "type" => RichContent::FILE_EMBED_NODE_TYPE, "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
  end

  def call_tool(name, arguments, scopes: "edit_products")
    token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes:)
    payload = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: } }
    post "/muse/v1/mcp", params: payload.to_json, headers: {
      "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "ACCEPT" => "application/json, text/event-stream",
      "Authorization" => "Bearer #{token.token}"
    }
    response.parsed_body.dig("result")
  end

  describe "add_file" do
    it "copies a linked file into the seller's own prefix and attaches it to the product" do
      url = "https://example.com/files/billion-dollar-company-chapter-0.pdf"
      stub_remote_file(url, "billion-dollar-company-chapter-0.pdf", "application/pdf")

      result = call_tool("add_file", { id: @product.unique_permalink, url: })

      file = @product.reload.alive_product_files.sole
      expect(result.dig("structuredContent", "files")).to eq([{
                                                               "id" => file.external_id, "name" => "billion-dollar-company-chapter-0",
                                                               "type" => "PDF", "size_bytes" => File.size(fixture_path("billion-dollar-company-chapter-0.pdf")),
                                                               "position" => 1
                                                             }])
      expect(file.s3_key).to match(%r{\Aattachments/#{@seller.external_id}/[0-9a-f]{32}/original/billion-dollar-company-chapter-0\.pdf\z})
      expect(@stored_objects.sole).to include(bucket: S3_BUCKET, content_type: "application/pdf")
      expect(@stored_objects.sole[:content_length]).to eq(File.size(fixture_path("billion-dollar-company-chapter-0.pdf")))
    end

    it "attaches a file small enough to stay in the write buffer" do
      url = "https://example.com/files/financial-annual-summary-2022.csv"
      stub_remote_file(url, "financial-annual-summary-2022.csv", "text/csv")

      result = call_tool("add_file", { id: @product.unique_permalink, url: })

      expect(result.dig("structuredContent", "files").sole).to include(
        "name" => "financial-annual-summary-2022",
        "size_bytes" => File.size(fixture_path("financial-annual-summary-2022.csv"))
      )
    end

    it "keeps the product's other files" do
      existing = create(:product_file, link: @product)
      url = "https://example.com/files/blah.txt"
      stub_remote_file(url, "blah.txt", "text/plain")

      call_tool("add_file", { id: @product.unique_permalink, url: })

      files = @product.reload.alive_product_files
      expect(files.map(&:id)).to match_array([existing.id, ProductFile.where.not(id: existing.id).last.id])
      # The add goes to the end of the download list, not in front of the files already there.
      expect(files.last.position).to eq((existing.position || 0) + 1)
    end

    it "uses the display name for a link with no filename in it" do
      url = "https://example.com/"
      stub_remote_file(url, "blah.txt", "text/plain")

      call_tool("add_file", { id: @product.unique_permalink, url:, display_name: "Field notes PDF" })

      file = @product.reload.alive_product_files.sole
      expect(file.s3_filename).to eq("Field notes PDF.txt")
      expect(file.name_displayable).to eq("Field notes PDF")
    end

    it "adds the file to a content page that already lists files" do
      existing = create(:product_file, link: @product)
      page = create(:rich_content, entity: @product, description: [file_embed(existing)])
      url = "https://example.com/files/blah.txt"
      stub_remote_file(url, "blah.txt", "text/plain")

      call_tool("add_file", { id: @product.unique_permalink, url: })

      file = @product.reload.alive_product_files.find { _1.id != existing.id }
      expect(page.reload.embedded_product_file_ids_in_order).to eq([existing.id, file.id])
    end

    it "leaves a content page that lists no files alone" do
      description = [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Notes" }] }]
      page = create(:rich_content, entity: @product, description:)
      url = "https://example.com/files/blah.txt"
      stub_remote_file(url, "blah.txt", "text/plain")

      call_tool("add_file", { id: @product.unique_permalink, url: })

      expect(page.reload.description).to eq(description)
    end

    it "keeps the copy it stored when the save left a live row behind" do
      url = "https://example.com/files/blah.txt"
      stub_remote_file(url, "blah.txt", "text/plain")
      allow_any_instance_of(Link).to receive(:save_files!) do |product, files, **_options|
        ProductFile.create!(link: product, url: files.sole[:url], display_name: "blah")
        raise Redis::BaseError, "connection lost"
      end

      result = call_tool("add_file", { id: @product.unique_permalink, url: })

      expect(result.dig("isError")).to eq(true)
      expect(result.dig("content", 0, "text")).to include("was attached")
      expect(@product.reload.alive_product_files.count).to eq(1)
      expect(@deleted_keys).to be_empty
    end

    it "refuses a file larger than the limit and stores nothing" do
      url = "https://example.com/files/huge.mp4"
      stub_remote_file(url, "blah.txt", "video/mp4", content_length: Mcp::ProductFileIngest::MAX_BYTES + 1)

      result = call_tool("add_file", { id: @product.unique_permalink, url: })

      expect(result.dig("isError")).to eq(true)
      expect(result.dig("content", 0, "text")).to include("larger than 250 MB", "product editor")
      expect(@product.reload.alive_product_files).to be_empty
      expect(@stored_objects).to be_empty
    end

    it "refuses a URL that the fetch guard rejects" do
      url = "http://169.254.169.254/latest/meta-data"
      allow(SsrfFilter).to receive(:get).with(url).and_raise(SsrfFilter::PrivateIPAddress.new("private address"))

      result = call_tool("add_file", { id: @product.unique_permalink, url: })

      expect(result.dig("isError")).to eq(true)
      expect(result.dig("content", 0, "text")).to include("public https link")
      expect(@product.reload.alive_product_files).to be_empty
    end

    it "removes the copy it stored when the file cannot be saved" do
      url = "https://example.com/files/blah.txt"
      stub_remote_file(url, "blah.txt", "text/plain")
      allow_any_instance_of(Link).to receive(:save_files!).and_raise(ActiveRecord::RecordInvalid.new(ProductFile.new))

      call_tool("add_file", { id: @product.unique_permalink, url: })

      expect(@deleted_keys).to eq([@stored_objects.sole[:key]])
    end

    it "cannot reach another seller's product" do
      url = "https://example.com/files/blah.txt"
      stub_remote_file(url, "blah.txt", "text/plain")
      @product.update!(user: create(:user))

      result = call_tool("add_file", { id: @product.unique_permalink, url: })

      expect(result.dig("isError")).to eq(true)
      expect(result.dig("content", 0, "text")).to eq("The product was not found.")
    end
  end

  describe "list_files" do
    it "lists the files in download order with their type and size" do
      first = create(:product_file, link: @product, url: "#{S3_BASE_URL}attachments/#{@seller.external_id}/#{SecureRandom.hex}/original/notes.pdf",
                                    position: 1, size: 2048)
      second = create(:product_file, link: @product, url: "#{S3_BASE_URL}attachments/#{@seller.external_id}/#{SecureRandom.hex}/original/bonus.zip",
                                     position: 2)

      files = call_tool("list_files", { id: @product.external_id }).dig("structuredContent", "files")

      expect(files).to eq([
                            { "id" => first.external_id, "name" => "notes", "type" => "PDF", "size_bytes" => 2048, "position" => 1 },
                            { "id" => second.external_id, "name" => "bonus", "type" => "ZIP", "size_bytes" => 0, "position" => 2 },
                          ])
    end
  end
end
