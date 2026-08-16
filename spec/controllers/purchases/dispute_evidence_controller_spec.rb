# frozen_string_literal: false

require "spec_helper"
require "inertia_rails/rspec"

describe Purchases::DisputeEvidenceController, type: :controller, inertia: true do
  let(:dispute_evidence) { create(:dispute_evidence) }
  let(:purchase) { dispute_evidence.disputable.purchase_for_dispute_evidence }
  # Minted exactly the way the chargeback emails mint it, so the elapsed-window cases below
  # exercise the link a real seller holds. evidence_link_expires_at outlives the deadline on
  # purpose: the token is not what closes the window, check_if_needs_redirect is.
  let(:evidence_token) do
    purchase.secure_external_id(
      scope: Purchases::DisputeEvidenceController::SECURE_ID_SCOPE,
      expires_at: dispute_evidence.evidence_link_expires_at
    )
  end

  # gp#1921: a valid scoped token is no longer sufficient on its own — the authenticated
  # user must also be the seller who owns the sale. Sign in as the seller by default so the
  # existing token-based scenarios below still exercise the window/status logic they intend
  # to, and override sign_in explicitly in the specs that are testing authentication itself.
  before do
    sign_in(purchase.seller)
  end

  describe "GET show" do
    context "when the seller hasn't been contacted" do
      before do
        dispute_evidence.update_as_not_seller_contacted!
      end

      it "redirects" do
        get :show, params: { purchase_id: evidence_token }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("You are not allowed to perform this action.")
      end
    end

    # Nothing reaches Stripe until the window closes, so a seller who saved early must be able to
    # come back and add to their response rather than being bounced to the dashboard.
    context "when the seller has already saved a response" do
      before do
        dispute_evidence.update_as_seller_submitted!
      end

      it "renders the form again" do
        get :show, params: { purchase_id: evidence_token }

        expect(response).to be_successful
        expect(flash[:alert]).to be_nil
      end
    end

    # Past the deadline rather than exactly on it: a stamp of exactly
    # SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS.hours.ago puts the request on the boundary the
    # window check compares against, which is a state no seller can act from.
    context "when the window has elapsed without the row being resolved" do
      before do
        dispute_evidence.update!(seller_contacted_at: (DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS + 0.1).hours.ago)
      end

      it "redirects" do
        get :show, params: { purchase_id: evidence_token }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("The deadline for submitting additional information for this dispute has passed.")
      end
    end

    context "when the dispute has already been submitted" do
      before do
        dispute_evidence.update_as_resolved!(resolution: DisputeEvidence::RESOLUTION_SUBMITTED)
      end

      it "redirects" do
        get :show, params: { purchase_id: evidence_token }

        expect(response).to redirect_to(dashboard_url)
        expect(flash[:alert]).to eq("Additional information can no longer be submitted for this dispute.")
      end
    end

    RSpec.shared_examples "shows the dispute evidence page for the purchase" do
      it "shows the dispute evidence page for the purchase" do
        get :show, params: { purchase_id: evidence_token }

        expect(response).to be_successful
        expect(inertia.component).to eq("Purchases/DisputeEvidence/Show")

        expected_props = DisputeEvidencePagePresenter.new(dispute_evidence, purchase_route_id: evidence_token).props
        actual_props = inertia.props.slice(*expected_props.keys)
        expect(actual_props).to eq(expected_props)
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
      get :show, params: { purchase_id: evidence_token }

      expect(response).to be_successful
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    end
  end

  describe "GET success" do
    it "renders the success page" do
      get :success, params: { purchase_id: evidence_token }

      expect(response).to be_successful
      expect(inertia.component).to eq("Purchases/DisputeEvidence/Success")
    end

    it "adds X-Robots-Tag response header to avoid page indexing" do
      get :success, params: { purchase_id: evidence_token }

      expect(response).to be_successful
      expect(response.headers["X-Robots-Tag"]).to eq("noindex")
    end
  end

  describe "PUT update" do
    it "updates the dispute evidence and redirects to success page" do
      put :update, params: {
        purchase_id: evidence_token,
        dispute_evidence: {
          reason_for_winning: "Reason for winning",
          cancellation_rebuttal: "Cancellation rebuttal",
          refund_refusal_explanation: "Refusal explanation"
        }
      }

      dispute_evidence.reload
      expect(dispute_evidence.reason_for_winning).to eq("Reason for winning")
      expect(dispute_evidence.cancellation_rebuttal).to eq("Cancellation rebuttal")
      expect(dispute_evidence.refund_refusal_explanation).to eq("Refusal explanation")
      expect(dispute_evidence.seller_submitted?).to be(true)

      expect(response).to redirect_to(success_purchase_dispute_evidence_path(evidence_token))
    end

    it "saves without forwarding to the processor while the window is open" do
      put :update, params: {
        purchase_id: evidence_token,
        dispute_evidence: { reason_for_winning: "Reason for winning" }
      }

      expect(dispute_evidence.reload.seller_submitted?).to be(true)
      expect(FightDisputeJob.jobs.size).to eq(0)
    end

    # An elapsed window is refused before anything is written: FightDisputeJob is already forwarding
    # the submission, so a late save would either arrive too late or race the forward. This is the
    # one case where the seller genuinely cannot keep adding to their response.
    it "refuses a save once the window has elapsed, and forwards nothing" do
      dispute_evidence.update!(seller_contacted_at: (DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS + 0.1).hours.ago)

      put :update, params: {
        purchase_id: evidence_token,
        dispute_evidence: { reason_for_winning: "Reason for winning" }
      }

      expect(response).to redirect_to(dashboard_url)
      expect(flash[:alert]).to eq("The deadline for submitting additional information for this dispute has passed.")
      expect(dispute_evidence.reload.reason_for_winning).to be_nil
      expect(FightDisputeJob.jobs.size).to eq(0)
    end

    # The form pre-fills a saved value into its editable control, so resubmitting it unchanged is
    # what "leave alone" looks like at this layer — only an explicit clear should blank the field.
    it "keeps fields the seller left blank on a later revision" do
      put :update, params: {
        purchase_id: evidence_token,
        dispute_evidence: {
          reason_for_winning: "First answer",
          cancellation_rebuttal: "First rebuttal",
          refund_refusal_explanation: "First refusal"
        }
      }

      put :update, params: {
        purchase_id: evidence_token,
        dispute_evidence: {
          reason_for_winning: "Revised answer",
          cancellation_rebuttal: "First rebuttal",
          refund_refusal_explanation: "First refusal"
        }
      }

      dispute_evidence.reload
      expect(dispute_evidence.reason_for_winning).to eq("Revised answer")
      expect(dispute_evidence.cancellation_rebuttal).to eq("First rebuttal")
      expect(dispute_evidence.refund_refusal_explanation).to eq("First refusal")
    end

    # An explicitly-cleared field is not "left blank" — it is the seller retracting what they wrote,
    # and the deadline job must forward that retraction rather than the stale saved text.
    it "clears a field the seller explicitly blanked on a later revision" do
      put :update, params: {
        purchase_id: evidence_token,
        dispute_evidence: {
          reason_for_winning: "First answer",
          cancellation_rebuttal: "First rebuttal",
          refund_refusal_explanation: "First refusal"
        }
      }

      put :update, params: {
        purchase_id: evidence_token,
        dispute_evidence: {
          reason_for_winning: "Revised answer",
          cancellation_rebuttal: "",
          refund_refusal_explanation: ""
        }
      }

      dispute_evidence.reload
      expect(dispute_evidence.reason_for_winning).to eq("Revised answer")
      expect(dispute_evidence.cancellation_rebuttal).to be_nil
      expect(dispute_evidence.refund_refusal_explanation).to be_nil
    end

    context "when a signed_id for a PNG file is provided" do
      let(:blob) do
        ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "receipt_image.png", content_type: "image/png")
      end

      it "converts the file to JPG and attaches it to the dispute evidence" do
        # Purging in test ENV returns Aws::S3::Errors::AccessDenied
        allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
        put :update, params: { purchase_id: evidence_token, dispute_evidence: { customer_communication_file_signed_blob_id: blob.signed_id } }

        dispute_evidence.reload
        expect(dispute_evidence.customer_communication_file.attached?).to be(true)
        expect(dispute_evidence.customer_communication_file.filename.to_s).to eq("receipt_image.jpg")
        expect(dispute_evidence.customer_communication_file.content_type).to eq("image/jpeg")

        expect(response).to redirect_to(success_purchase_dispute_evidence_path(evidence_token))
      end
    end

    context "when a signed_id for a PDF file is provided" do
      let(:blob) do
        ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.pdf"), filename: "test.pdf", content_type: "application/pdf")
      end

      it "attaches it to the dispute evidence" do
        put :update, params: { purchase_id: evidence_token, dispute_evidence: { customer_communication_file_signed_blob_id: blob.signed_id } }

        dispute_evidence.reload
        expect(dispute_evidence.customer_communication_file.attached?).to be(true)
        expect(dispute_evidence.customer_communication_file.filename.to_s).to eq("test.pdf")
        expect(dispute_evidence.customer_communication_file.content_type).to eq("application/pdf")

        expect(response).to redirect_to(success_purchase_dispute_evidence_path(evidence_token))
      end
    end

    # customer_communication_file is has_one_attached, so a bare #attach on this second save would
    # replace rather than add to the first save's evidence — the exact loss Greptile flagged.
    context "when a later revision adds another file" do
      let(:first_blob) do
        ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("test.pdf"), filename: "first.pdf", content_type: "application/pdf")
      end
      let(:second_blob) do
        ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "second.png", content_type: "image/png")
      end

      it "merges the new file with the previously saved one instead of replacing it" do
        allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)

        put :update, params: { purchase_id: evidence_token, dispute_evidence: { customer_communication_file_signed_blob_id: first_blob.signed_id } }
        put :update, params: { purchase_id: evidence_token, dispute_evidence: { customer_communication_file_signed_blob_id: second_blob.signed_id } }

        dispute_evidence.reload
        expect(dispute_evidence.customer_communication_file.filename.to_s).to eq("customer_communication.pdf")
        pages = PDF::Reader.new(StringIO.new(dispute_evidence.customer_communication_file.download)).pages
        expect(pages.size).to eq(2)
      end
    end

    context "when an array with a single signed id is provided" do
      let(:blob) do
        ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "receipt_image.png", content_type: "image/png")
      end

      it "behaves like the singular param, including the PNG to JPG conversion" do
        # Purging in test ENV returns Aws::S3::Errors::AccessDenied
        allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
        put :update, params: { purchase_id: evidence_token, dispute_evidence: { customer_communication_file_signed_blob_ids: [blob.signed_id] } }

        dispute_evidence.reload
        expect(dispute_evidence.customer_communication_file.attached?).to be(true)
        expect(dispute_evidence.customer_communication_file.filename.to_s).to eq("receipt_image.jpg")
        expect(dispute_evidence.customer_communication_file.content_type).to eq("image/jpeg")

        expect(response).to redirect_to(success_purchase_dispute_evidence_path(evidence_token))
      end
    end

    context "when multiple signed ids are provided" do
      let(:blobs) do
        [
          ["autumn-leaves-1280x720.jpeg", "image/jpeg"],
          ["smilie.png", "image/png"],
          ["test.pdf", "application/pdf"],
        ].map do |fixture, content_type|
          ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload(fixture), filename: fixture, content_type:)
        end
      end

      before do
        # Purging in test ENV returns Aws::S3::Errors::AccessDenied
        allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
      end

      it "attaches a single merged PDF containing every file, in upload order" do
        put :update, params: { purchase_id: evidence_token, dispute_evidence: { customer_communication_file_signed_blob_ids: blobs.map(&:signed_id) } }

        dispute_evidence.reload
        expect(dispute_evidence.customer_communication_file.attached?).to be(true)
        expect(dispute_evidence.customer_communication_file.filename.to_s).to eq("customer_communication.pdf")
        expect(dispute_evidence.customer_communication_file.content_type).to eq("application/pdf")

        pages = PDF::Reader.new(StringIO.new(dispute_evidence.customer_communication_file.download)).pages
        expect(pages.size).to eq(3)
        # Image pages are sized to their source image, so dimensions prove the order survived.
        first_page_media_box = pages.first.attributes[:MediaBox]
        expect((first_page_media_box[2] - first_page_media_box[0]).round).to eq(1280)

        expect(dispute_evidence.seller_submitted?).to be(true)
        expect(FightDisputeJob.jobs.size).to eq(0)
        expect(response).to redirect_to(success_purchase_dispute_evidence_path(evidence_token))
      end

      context "when the merged PDF cannot fit within the size limit" do
        before do
          allow_any_instance_of(DisputeEvidence).to receive(:customer_communication_file_max_size).and_return(10_000)
        end

        it "fails loudly without submitting or truncating the evidence" do
          put :update, params: { purchase_id: evidence_token, dispute_evidence: { customer_communication_file_signed_blob_ids: blobs.map(&:signed_id) } }

          dispute_evidence.reload
          expect(dispute_evidence.customer_communication_file.attached?).to be(false)
          expect(dispute_evidence.seller_submitted?).to be(false)
          expect(FightDisputeJob.jobs.size).to eq(0)

          expect(response).to redirect_to(purchase_dispute_evidence_path(evidence_token))
          expect(flash[:alert]).to eq(DisputeEvidence::MergeCustomerCommunicationFilesService::FILE_TOO_LARGE_MESSAGE)
        end
      end

      # The seller's only Stripe submission is spent on submit, so a trivial validation error
      # must leave their uploads reusable rather than making them re-attach everything. Only
      # the orphaned merged PDF may be purged.
      it "keeps the uploaded files when the record is invalid" do
        purged_keys = []
        allow_any_instance_of(ActiveStorage::Blob).to receive(:purge) { |blob| purged_keys << blob.key }

        put :update, params: { purchase_id: evidence_token, dispute_evidence: { customer_communication_file_signed_blob_ids: blobs.map(&:signed_id), cancellation_rebuttal: "a" * 3_001 } }

        expect(dispute_evidence.reload.seller_submitted?).to be(false)
        expect(FightDisputeJob.jobs.size).to eq(0)
        expect(purged_keys).not_to include(*blobs.map(&:key))
        expect(response).to redirect_to(purchase_dispute_evidence_path(evidence_token))
      end

      it "purges the uploaded files once the submission is persisted" do
        purged_keys = []
        allow_any_instance_of(ActiveStorage::Blob).to receive(:purge) { |blob| purged_keys << blob.key }

        put :update, params: { purchase_id: evidence_token, dispute_evidence: { customer_communication_file_signed_blob_ids: blobs.map(&:signed_id) } }

        expect(dispute_evidence.reload.seller_submitted?).to be(true)
        expect(purged_keys).to include(*blobs.map(&:key))
      end

      it "redirects with an alert when a signed id no longer resolves" do
        put :update, params: { purchase_id: evidence_token, dispute_evidence: { customer_communication_file_signed_blob_ids: [blobs.first.signed_id, "not-a-signed-id"] } }

        expect(dispute_evidence.reload.seller_submitted?).to be(false)
        expect(FightDisputeJob.jobs.size).to eq(0)
        expect(response).to redirect_to(purchase_dispute_evidence_path(evidence_token))
        expect(flash[:alert]).to eq("We could not find your uploaded files. Please upload them again.")
      end
    end

    context "when the dispute evidence is invalid" do
      it "redirects with error message" do
        put :update, params: { purchase_id: evidence_token, dispute_evidence: { cancellation_rebuttal: "a" * 3_001 } }

        expect(response).to redirect_to(purchase_dispute_evidence_path(evidence_token))
        expect(flash[:alert]).to eq("Cancellation rebuttal is too long (maximum is 3000 characters)")
      end
    end

    # A suspension can land in the middle of the 72-hour evidence window. The
    # dispute still has to be answered on its own merits, so the submit must go
    # through even though the generic `check_suspended` filter would otherwise
    # block every non-GET request from a suspended user.
    context "when the seller is signed in and suspended" do
      let(:seller) { purchase.seller }

      before do
        seller.update!(user_risk_state: "compliant")
        seller.suspend_for_tos_violation!(author_id: create(:admin_user).id)
        sign_in(seller)
        # Suspension bumps `last_active_sessions_invalidated_at`, so a session
        # that predates it gets signed out by `invalidate_session_if_necessary`.
        # Stamp the session as fresh to model a seller who logged back in after
        # being suspended, which is when `check_suspended` actually applies.
        request.env["warden"].session["last_sign_in_at"] = DateTime.current.to_i
      end

      it "still accepts the evidence submission" do
        put :update, params: {
          purchase_id: evidence_token,
          dispute_evidence: { reason_for_winning: "The buyer downloaded and used the product." }
        }

        dispute_evidence.reload
        expect(dispute_evidence.reason_for_winning).to eq("The buyer downloaded and used the product.")
        expect(dispute_evidence.seller_submitted?).to be(true)
        expect(response).to redirect_to(success_purchase_dispute_evidence_path(evidence_token))
      end
    end
  end

  # gp#1921: purchase.external_id is buyer-visible via the library/download pages, so the disputing
  # buyer must never be able to use it to read or overwrite the seller's chargeback response.
  # Login is now required outright (Sahil's direction on gp#1921), so a signed-out request is
  # redirected to log in rather than 404ing — but no signed-in identity other than the seller
  # who owns the sale, including via a valid scoped token, can ever resolve the purchase.
  describe "buyer access via the legacy buyer-visible external_id" do
    before { sign_out(purchase.seller) }

    it "redirects a signed-out show request to log in" do
      get :show, params: { purchase_id: purchase.external_id }

      expect(response).to redirect_to(login_path(next: purchase_dispute_evidence_path(purchase.external_id)))
    end

    it "redirects a signed-out update request to log in and does not save anything" do
      put :update, params: {
        purchase_id: purchase.external_id,
        dispute_evidence: { reason_for_winning: "Overwritten by the buyer" }
      }

      expect(response).to redirect_to(login_path(next: purchase_dispute_evidence_path(purchase.external_id)))
      expect(dispute_evidence.reload.reason_for_winning).to be_nil
    end

    it "404s for the disputing buyer signed in as themselves" do
      sign_in(purchase.purchaser || create(:user, email: purchase.email))

      expect do
        get :show, params: { purchase_id: purchase.external_id }
      end.to raise_error(ActionController::RoutingError)
    end

    it "404s for an unrelated signed-in seller" do
      sign_in(create(:user))

      expect do
        get :show, params: { purchase_id: purchase.external_id }
      end.to raise_error(ActionController::RoutingError)
    end

    # The scoped token alone is exactly the surface gp#1921 reported: it was sufficient by
    # itself before this fix, so an unrelated signed-in user must still 404 even holding it.
    it "404s for an unrelated signed-in user holding a valid scoped token" do
      sign_in(create(:user))

      expect do
        get :show, params: { purchase_id: evidence_token }
      end.to raise_error(ActionController::RoutingError)
    end

    it "redirects a signed-out request holding a valid scoped token to log in" do
      get :show, params: { purchase_id: evidence_token }

      expect(response).to redirect_to(login_path(next: purchase_dispute_evidence_path(evidence_token)))
    end
  end

  # The legacy external_id keeps resolving for the seller who actually owns the sale, so
  # already-delivered emails predating the scoped token don't strand anyone.
  describe "seller access via the legacy buyer-visible external_id" do
    it "shows the page for the authenticated seller-owner" do
      sign_in(purchase.seller)

      get :show, params: { purchase_id: purchase.external_id }

      expect(response).to be_successful
    end

    it "accepts an update from the authenticated seller-owner" do
      sign_in(purchase.seller)

      put :update, params: {
        purchase_id: purchase.external_id,
        dispute_evidence: { reason_for_winning: "Reason for winning" }
      }

      expect(dispute_evidence.reload.reason_for_winning).to eq("Reason for winning")
      expect(response).to redirect_to(success_purchase_dispute_evidence_path(purchase.external_id))
    end
  end
end
