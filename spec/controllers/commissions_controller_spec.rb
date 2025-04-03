# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe CommissionsController, :vcr do
  let(:seller) { create(:named_seller, :eligible_for_service_products) }
  let(:pundit_user) { SellerContext.new(user: seller, seller:) }
  let(:commission) { create(:commission, deposit_purchase: create(:purchase, seller:, link: create(:commission_product, user: seller), price_cents: 100, displayed_price_cents: 100, credit_card: create(:credit_card))) }

  include_context "with user signed in as admin for seller"

  describe "PUT update" do
    it_behaves_like "authorize called for action", :put, :update do
      let(:policy_klass) { CommissionPolicy }
      let(:record) { commission }
      let(:request_params) { { id: commission.external_id } }
    end

    it "attaches new files and purges old files" do
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)

      commission.files.attach(file_fixture("test.png"))

      file = fixture_file_upload("test.pdf")
      blob = ActiveStorage::Blob.create_and_upload!(io: file, filename: "test.pdf")

      expect do
        put :update, params: { id: commission.external_id, file_signed_ids: [blob.signed_id] }, as: :json
      end.to_not change { commission.reload.files.count }

      expect(response).to be_successful
      expect(response).to have_http_status(:no_content)
      expect(commission.files.first.filename).to eq("test.pdf")
    end

    context "when commission is not found" do
      it "raises an ActiveRecord::RecordNotFound error" do
        expect do
          put :update, params: { id: "non_existent_id", file_signed_ids: [] }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end

  describe "POST complete" do
    it_behaves_like "authorize called for action", :post, :complete do
      let(:policy_klass) { CommissionPolicy }
      let(:record) { commission }
      let(:request_params) { { id: commission.external_id } }
    end

    it "creates a completion purchase" do
      expect_any_instance_of(Commission).to receive(:create_completion_purchase!).and_call_original

      post :complete, params: { id: commission.external_id }

      expect(response).to be_successful
      expect(response).to have_http_status(:no_content)

      commission.reload
      expect(commission.completion_purchase).to be_present
      expect(commission.status).to eq(Commission::STATUS_COMPLETED)
    end

    context "when an error occurs during completion" do
      it "returns an error message" do
        allow_any_instance_of(Commission).to receive(:create_completion_purchase!).and_raise(ActiveRecord::RecordInvalid.new)

        post :complete, params: { id: commission.external_id }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to eq({ "errors" => ["Failed to complete commission"] })
      end
    end

    context "when commission is not found" do
      it "raises an ActiveRecord::RecordNotFound error" do
        expect do
          post :complete, params: { id: "non_existent_id" }
        end.to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
