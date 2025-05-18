# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::PurchasesController, :vcr do
  it_behaves_like "inherits from Admin::BaseController"

  before do
    @admin_user = create(:admin_user)
    sign_in @admin_user
  end

  describe "#show" do
    before do
      @purchase = create(:purchase)
    end

    it "raises ActionController::RoutingError when purchase is not found" do
      expect { get :show, params: { id: "invalid-id" } }.to raise_error(ActionController::RoutingError)
    end

    it "finds the purchase correctly when loaded via external id" do
      expect(Purchase).not_to receive(:find_by_stripe_transaction_id)
      expect(Purchase).to receive(:find_by_external_id).and_call_original
      get :show, params: { id: @purchase.external_id }

      expect(assigns(:purchase)).to eq(@purchase)
      assert_response :success
    end

    it "finds the purchase correctly when loaded via id" do
      expect(Purchase).not_to receive(:find_by_stripe_transaction_id)
      expect(Purchase).not_to receive(:find_by_external_id)
      get :show, params: { id: @purchase.id }

      expect(assigns(:purchase)).to eq(@purchase)
      assert_response :success
    end

    it "finds the purchase correctly when loaded via numeric external id" do
      expect(Purchase).to receive(:find_by_external_id_numeric).and_call_original
      get :show, params: { id: @purchase.external_id_numeric }

      expect(assigns(:purchase)).to eq(@purchase)
      assert_response :success
    end

    it "finds the purchase correctly when loaded via stripe_transaction_id" do
      expect(Purchase).to receive(:find_by_stripe_transaction_id).and_call_original
      get :show, params: { id: @purchase.stripe_transaction_id }

      expect(assigns(:purchase)).to eq(@purchase)
      assert_response :success
    end
  end

  describe "POST refund_for_fraud" do
    before do
      @purchase = create(:purchase_in_progress, chargeable: create(:chargeable), purchaser: create(:user))
      @purchase.process!
      @purchase.mark_successful!
    end

    it "refunds the purchase and blocks the buyer" do
      comment_content = "Buyer blocked by Admin (#{@admin_user.email})"
      expect do
        post :refund_for_fraud, params: { id: @purchase.id }

        expect(@purchase.reload.stripe_refunded).to be(true)
        expect(@purchase.buyer_blocked?).to eq(true)
        expect(response).to be_successful
        expect(response.parsed_body["success"]).to be(true)
      end.to change { @purchase.comments.where(content: comment_content, comment_type: "note", author_id: @admin_user.id).count }.by(1)
       .and change { @purchase.purchaser.comments.where(content: comment_content, comment_type: "note", author_id: @admin_user.id, purchase: @purchase).count }.by(1)
    end
  end
end
