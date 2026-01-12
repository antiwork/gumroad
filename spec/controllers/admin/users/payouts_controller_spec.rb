# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"
require "inertia_rails/rspec"

describe Admin::Users::PayoutsController, type: :controller, inertia: true do
  it_behaves_like "inherits from Admin::BaseController"

  let(:admin_user) { create(:admin_user) }
  let(:seller) { create(:user) }
  let(:payout_period_end_date) { Date.today - 1 }

  describe "GET index" do
    render_views

    let!(:payout_1) { create(:payment_completed, user: seller) }
    let!(:payout_2) { create(:payment_failed, user: seller) }
    let!(:other_user_payout) { create(:payment_failed) }

    it "lists all the payouts for a user" do
      sign_in admin_user
      get :index, params: { user_external_id: seller.external_id }

      expect(response).to be_successful
      expect(inertia.component).to eq("Admin/Users/Payouts/Index")
      expect(inertia.props[:payouts]).to contain_exactly(
        hash_including(external_id: payout_1.external_id),
        hash_including(external_id: payout_2.external_id)
      )
    end
  end

  describe "POST pause" do
    before do
      sign_in admin_user
    end

    it "pauses payouts for seller, sets the pause source as admin, and saves the provided reason" do
      expect(seller.payouts_paused_internally?).to be false
      expect(seller.payouts_paused_by_source).to be nil
      expect(seller.payouts_paused_for_reason).to be nil

      expect do
        post :pause, params: { user_external_id: seller.external_id, pause_payouts: { reason: "Chargeback rate too high." } }, format: :json
      end.to change { seller.comments.with_type_payouts_paused.count }.by(1)

      expect(seller.reload.payouts_paused_internally?).to be true
      expect(seller.payouts_paused_by).to eq(admin_user.id)
      expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
      expect(seller.payouts_paused_for_reason).to eq("Chargeback rate too high.")
    end

    it "pauses payouts for seller and sets the pause source as admin even if no reason is provided" do
      expect(seller.payouts_paused_internally?).to be false
      expect(seller.payouts_paused_by_source).to be nil
      expect(seller.payouts_paused_for_reason).to be nil

      expect do
        post :pause, params: { user_external_id: seller.external_id, pause_payouts: { reason: nil } }, format: :json
      end.not_to change { seller.comments.with_type_payouts_paused.count }

      expect(seller.reload.payouts_paused_internally?).to be true
      expect(seller.payouts_paused_by).to eq(admin_user.id)
      expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
      expect(seller.payouts_paused_for_reason).to be nil
    end
  end

  describe "POST resume" do
    before do
      seller.update!(payouts_paused_internally: true)
      sign_in admin_user
    end

    it "resumes payouts for seller and clears the payout pause source if payouts are paused by admin" do
      expect(seller.payouts_paused_internally?).to be true
      expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_ADMIN)
      expect(seller.payouts_paused_for_reason).to be nil

      expect do
        post :resume, params: { user_external_id: seller.external_id }, format: :json
      end.to change { seller.comments.with_type_payouts_resumed.count }.by(1)

      expect(seller.reload.payouts_paused_internally?).to be false
      expect(seller.payouts_paused_by).to be nil
      expect(seller.payouts_paused_by_source).to be nil
      expect(seller.payouts_paused_for_reason).to be nil
    end

    it "resumes payouts for seller and clears the payout pause source if payouts are paused by stripe" do
      seller.update!(payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_STRIPE)
      expect(seller.reload.payouts_paused_internally?).to be true
      expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_STRIPE)
      expect(seller.payouts_paused_for_reason).to be nil

      expect do
        post :resume, params: { user_external_id: seller.external_id }, format: :json
      end.to change { seller.comments.with_type_payouts_resumed.count }.by(1)

      expect(seller.reload.payouts_paused_internally?).to be false
      expect(seller.payouts_paused_by).to be nil
      expect(seller.payouts_paused_by_source).to be nil
      expect(seller.payouts_paused_for_reason).to be nil
    end

    it "resumes payouts for seller and clears the payout pause source if payouts are paused by the system" do
      seller.update!(payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      expect(seller.reload.payouts_paused_internally?).to be true
      expect(seller.payouts_paused_by_source).to eq(User::PAYOUT_PAUSE_SOURCE_SYSTEM)
      expect(seller.payouts_paused_for_reason).to be nil

      expect do
        post :resume, params: { user_external_id: seller.external_id }, format: :json
      end.to change { seller.comments.with_type_payouts_resumed.count }.by(1)

      expect(seller.reload.payouts_paused_internally?).to be false
      expect(seller.payouts_paused_by).to be nil
      expect(seller.payouts_paused_by_source).to be nil
      expect(seller.payouts_paused_for_reason).to be nil
    end
  end
end
