# frozen_string_literal: false

require "spec_helper"

describe Purchases::DisputeEvidenceController do
  let(:dispute_evidence) { create(:dispute_evidence) }
  let(:purchase) { dispute_evidence.disputable.purchase_for_dispute_evidence }

  describe "GET show" do
    context "when the seller hasn't been contacted" do
      before do
        dispute_evidence.update_as_not_seller_contacted!
      end

      it "redirects" do
        get :show, params: { purchase_id: purchase.external_id }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    context "when the seller has already submitted" do
      before do
        dispute_evidence.update_as_seller_submitted!
      end

      it "redirects" do
        get :show, params: { purchase_id: purchase.external_id }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Additional information has already been submitted for this dispute.")
      end
    end

    context "when the dispute has already been submitted" do
      before do
        dispute_evidence.update_as_resolved!(resolution: DisputeEvidence::RESOLUTION_SUBMITTED)
      end

      it "redirects" do
        get :show, params: { purchase_id: purchase.external_id }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Additional information can no longer be submitted for this dispute.")
      end
    end

    RSpec.shared_examples "shows the dispute evidence page for the purchase" do
      it "shows the dispute evidence page for the purchase" do
        get :show, params: { purchase_id: purchase.external_id }

        expect(response).to be_successful
        expect(controller.send(:page_title)).to eq("Submit additional information")
        expect(assigns[:hide_layouts]).to be(true)

        expect(assigns[:dispute_evidence]).to eq(dispute_evidence)
        expect(assigns[:purchase]).to eq(purchase)
        dispute_evidence_page_presenter = assigns(:dispute_evidence_page_presenter)
        expect(dispute_evidence_page_presenter.send(:purchase)).to eq(purchase)
      end
    end

    context "when the dispute belongs to a charge" do
      let!(:charge) do
        charge = create(:charge)
        charge.purchases << create(:purchase)
        charge.purchases << create(:purchase)
        charge
      end
      let!(:purchase) { charge.purchase_for_dispute_evidence }
      let!(:dispute_evidence) do
        dispute = create(:dispute, purchase: nil, charge:)
        create(:dispute_evidence_on_charge, dispute:)
      end

      it_behaves_like "shows the dispute evidence page for the purchase"
    end

    it "404s for an invalid purchase id" do
      expect do
        get :show, params: { purchase_id: "1234" }
      end.to raise_error(ActionController::RoutingError)
    end

    it "adds X-Robots-Tag response header to avoid page indexing" do
      get :show, params: { purchase_id: purchase.external_id }

      expect(response).to be_successful
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    end
  end

  describe "PUT update" do
    it "updates the dispute evidence" do
      put :update, params: {
        purchase_id: purchase.external_id,
        dispute_evidence: {
          reason_for_winning: "Reason for winning",
          cancellation_rebuttal: "Cancellation rebuttal",
          refund_refusal_explanation: "Refusal explanation"
        }
      }

      dispute_evidence = assigns(:dispute_evidence)
      expect(dispute_evidence.reason_for_winning).to eq("Reason for winning")
      expect(dispute_evidence.cancellation_rebuttal).to eq("Cancellation rebuttal")
      expect(dispute_evidence.refund_refusal_explanation).to eq("Refusal explanation")
      expect(dispute_evidence.seller_submitted?).to be(true)

      expect(response.parsed_body).to eq({ "success" => true })
    end

    context "when a signed_id for a PNG file is provided" do
      let(:blob) do
        ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "receipt_image.png", content_type: "image/png")
      end

      it "converts the file to JPG and attaches it to the dispute evidence" do
        # Purging in test ENV returns Aws::S3::Errors::AccessDenied
        allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
        put :update, params: { purchase_id: purchase.external_id, dispute_evidence: { customer_communication_file_signed_blob_id: blob.signed_id } }

        dispute_evidence = assigns(:dispute_evidence)
        expect(dispute_evidence.customer_communication_file.attached?).to be(true)
        expect(dispute_evidence.customer_communication_file.filename.to_s).to eq("receipt_image.jpg")
        expect(dispute_evidence.customer_communication_file.content_type).to eq("image/jpeg")

        expect(response.parsed_body).to eq({ "success" => true })
      end
    end

    context "when a signed_id for a PDF file is provided" do
      let(:blob) do
        ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.pdf"), filename: "test.pdf", content_type: "application/pdf")
      end

      it "attaches it to the dispute evidence" do
        put :update, params: { purchase_id: purchase.external_id, dispute_evidence: { customer_communication_file_signed_blob_id: blob.signed_id } }

        dispute_evidence = assigns(:dispute_evidence)
        expect(dispute_evidence.customer_communication_file.attached?).to be(true)
        expect(dispute_evidence.customer_communication_file.filename.to_s).to eq("test.pdf")
        expect(dispute_evidence.customer_communication_file.content_type).to eq("application/pdf")

        expect(response.parsed_body).to eq({ "success" => true })
      end
    end

    context "when the dispute evidence is invalid" do
      it "returns errors" do
        put :update, params: { purchase_id: purchase.external_id, dispute_evidence: { cancellation_rebuttal: "a" * 3_001 } }

        dispute_evidence = assigns(:dispute_evidence)
        expect(dispute_evidence.valid?).to be(false)

        expect(response.parsed_body).to eq({ "success" => false, "error" => "Cancellation rebuttal is too long (maximum is 3000 characters)" })
      end
    end
  end
end
