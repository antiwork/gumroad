# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe DropboxFilesController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  describe "POST create" do
    it_behaves_like "authorize called for action", :post, :create do
      let(:policy_klass) { DropboxFilesPolicy }
      let(:record) { :dropbox_files }
    end

    it "enqueues the job to transfer the file to S3" do
      post :create, params: { link: "http://example.com/dropbox-url" }

      expect(TransferDropboxFileToS3Worker).to have_enqueued_sidekiq_job(kind_of(Integer))
    end
  end

  describe "GET index" do
    let(:product) { create(:product, user: seller) }
    let!(:dropbox_file) { create(:dropbox_file, link: product) }

    it_behaves_like "authorize called for action", :get, :index do
      let(:policy_klass) { DropboxFilesPolicy }
      let(:record) { :dropbox_files }
    end

    it "returns available files for product" do
      get :index, params: { link_id: product.unique_permalink }

      expect(response.parsed_body["dropbox_files"]).to eq([dropbox_file.as_json.stringify_keys])
    end

    it "returns available files for user" do
      dropbox_file = create(:dropbox_file, user: seller)

      get :index

      expect(response.parsed_body["dropbox_files"]).to eq([dropbox_file.as_json.stringify_keys])
    end
  end

  describe "POST cancel_upload" do
    let(:product) { create(:product, user: seller) }
    let!(:dropbox_file) { create(:dropbox_file, link: product) }

    it_behaves_like "authorize called for action", :post, :cancel_upload do
      let(:policy_klass) { DropboxFilesPolicy }
      let(:record) { :dropbox_files }
      let(:request_params) { { id: dropbox_file.external_id } }
    end
  end
end
