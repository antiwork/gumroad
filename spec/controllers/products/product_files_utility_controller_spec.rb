# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe ProductFilesUtilityController, :vcr do
  describe "GET external_link_title", :skip_ssrf_stub do
    before do
      @user = create(:user)
      sign_in @user
    end

    it "extracts title if valid url is passed" do
      post :external_link_title, params: { url: "https://en.wikipedia.org" }

      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["title"]).to eq("Wikipedia, the free encyclopedia")
    end

    it "falls back to 'Untitled' if title is blank" do
      post :external_link_title, params: { url: "https://drive.protonmail.com/urls/FJT6WRE0S0#SD4fDZbd1Bxy" }

      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["title"]).to eq("Untitled")
    end

    it "fails if invalid url is passed" do
      post :external_link_title, params: { url: "invalid url" }

      expect(response.parsed_body["success"]).to eq(false)
    end

    it "fails if the url is a local IP address" do
      post :external_link_title, params: { url: "http://127.0.0.1" }

      expect(response.parsed_body["success"]).to eq(false)
    end
  end

  describe "GET download_product_files" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }

    include_context "with user signed in as admin for seller"

    it "fails if user is not logged in" do
      sign_out(seller)
      get :download_product_files, format: :json, params: { product_id: product.external_id, product_file_ids: ["123"] }
      expect(response).to have_http_status(:not_found)
    end

    it_behaves_like "authorize called for action", :get, :download_product_files do
      let(:record) { product }
      let(:policy_method) { :edit? }
      let(:request_params) { { product_id: product.external_id, product_file_ids: ["123"] } }
    end

    it "returns failure response if the product is not found" do
      expect { get :download_product_files, format: :json, params: { product_id: "123", product_file_ids: ["123"] } }.to raise_error(ActionController::RoutingError)
    end

    it "returns failure response if the requested product files are not found" do
      expect { get :download_product_files, format: :json, params: { product_id: product.external_id, product_file_ids: [] } }.to raise_error(ActionController::RoutingError)
      expect { get :download_product_files, format: :json, params: { product_id: product.external_id, product_file_ids: ["123", "456"] } }.to raise_error(ActionController::RoutingError)
    end

    it "returns the file download info for all requested files" do
      file1 = create(:readable_document, link: product, display_name: "file1")
      file2 = create(:streamable_video, link: product, display_name: "file2")

      allow_any_instance_of(UrlRedirect).to receive(:signed_location_for_file).with(file1).and_return("https://example.com/file1.pdf")
      allow_any_instance_of(UrlRedirect).to receive(:signed_location_for_file).with(file2).and_return("https://example.com/file2.pdf")
      get :download_product_files, format: :json, params: { product_file_ids: [file1.external_id, file2.external_id], product_id: product.external_id }

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["files"]).to eq(product.product_files.map { { "url" => "https://example.com/#{_1.display_name}.pdf", "filename" => _1.s3_filename } })
    end

    it "redirects to the first product file if the format is HTML" do
      file = create(:product_file, link: product)
      expect_any_instance_of(UrlRedirect).to receive(:signed_location_for_file).with(file).and_return("https://example.com/file.srt")
      get :download_product_files, format: :html, params: { product_id: product.external_id, product_file_ids: [file.external_id] }

      expect(response).to redirect_to("https://example.com/file.srt")
    end
  end

  describe "GET download_folder_archive" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:file) { create(:product_file, link: product, display_name: "File 1") }
    let(:pdf_file) { create(:readable_document, link: product) }
    let(:video_file) { create(:streamable_video, link: product) }

    include_context "with user signed in as admin for seller"

    before do
      @archive = product.product_files_archives.new(folder_id: SecureRandom.uuid)
      @archive.product_files = product.product_files
      @archive.save!
      @archive.mark_in_progress!
      @archive.mark_ready!
    end

    it "fails if user is not logged in" do
      sign_out(seller)
      get :download_folder_archive, format: :json, params: { product_id: product.external_id, folder_id: "123" }
      expect(response).to have_http_status(:not_found)
    end

    it_behaves_like "authorize called for action", :get, :download_folder_archive do
      let(:record) { product }
      let(:policy_method) { :edit? }
      let(:request_params) { { product_id: product.external_id, folder_id: "123" } }
    end

    it "returns failure response if the product is not found" do
      expect { get :download_folder_archive, format: :json, params: { product_id: "123", folder_id: "123" } }.to raise_error(ActionController::RoutingError)
    end

    it "returns nil if the archive is not found" do
      get :download_folder_archive, format: :json, params: { product_id: product.external_id, folder_id: "123" }

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["url"]).to be_nil
    end

    it "returns the download URL if the archive is ready" do
      expect_any_instance_of(SignedUrlHelper).to receive(:download_folder_archive_url).with(@archive.folder_id, { variant_id: nil, product_id: product.external_id }).and_return("https://example.com/zip-archive.zip")
      get :download_folder_archive, format: :json, params: { product_id: product.external_id, folder_id: @archive.folder_id }

      expect(response).to have_http_status(:success)
      expect(response.parsed_body["url"]).to eq("https://example.com/zip-archive.zip")
    end

    it "redirects to the download URL if the archive is ready and the format is HTML" do
      expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).with(@archive.s3_key, @archive.s3_filename).and_return("https://example.com/zip-archive.zip")
      get :download_folder_archive, format: :html, params: { product_id: product.external_id, folder_id: @archive.folder_id }

      expect(response).to redirect_to("https://example.com/zip-archive.zip")
    end

    context "with variants" do
      before do
        category = create(:variant_category, link: product, title: "Versions")
        @variant = create(:variant, variant_category: category, name: "Version 1")
        @variant.product_files = product.product_files

        @variant_archive = @variant.product_files_archives.new(folder_id: SecureRandom.uuid)
        @variant_archive.product_files = @variant.product_files
        @variant_archive.save!
        @variant_archive.mark_in_progress!
        @variant_archive.mark_ready!
      end

      it "returns the download URL if the variant archive is ready" do
        expect_any_instance_of(SignedUrlHelper).to receive(:download_folder_archive_url).with(@variant_archive.folder_id, { variant_id: @variant.external_id, product_id: product.external_id }).and_return("https://example.com/zip-archive.zip")
        get :download_folder_archive, format: :json, params: { product_id: product.external_id, variant_id: @variant.external_id, folder_id: @variant_archive.folder_id }

        expect(response).to have_http_status(:success)
        expect(response.parsed_body["url"]).to eq("https://example.com/zip-archive.zip")
      end

      it "redirects to the download URL if the variant archive is ready and the format is HTML" do
        expect_any_instance_of(SignedUrlHelper).to receive(:signed_download_url_for_s3_key_and_filename).with(@variant_archive.s3_key, @variant_archive.s3_filename).and_return("https://example.com/zip-archive.zip")
        get :download_folder_archive, format: :html, params: { product_id: product.external_id, variant_id: @variant.external_id, folder_id: @variant_archive.folder_id }

        expect(response).to redirect_to("https://example.com/zip-archive.zip")
      end
    end
  end
end
