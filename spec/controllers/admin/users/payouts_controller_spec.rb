# frozen_string_literal: true

require "spec_helper"
require "shared_examples/admin_base_controller_concern"

describe Admin::Users::PayoutsController do
  it_behaves_like "inherits from Admin::BaseController"

  let(:payout_period_end_date) { Date.today - 1 }

  before do
    @admin_user = create(:admin_user)
    @admin_user_with_payout_privileges = create(:admin_user, has_payout_privilege: true)
    @params = {
      payout_period_end_date: payout_period_end_date.to_s,
      passphrase: "1234"
    }
  end

  describe "GET 'index'" do
    render_views

    before do
      @admin_user = create(:admin_user)
      @user = create(:user)
      @payout_1 = create(:payment_completed, user: @user)
      @payout_2 = create(:payment_failed, user: @user)
      @other_user_payout = create(:payment_failed)
    end

    it "lists all the payouts for a user" do
      sign_in @admin_user
      get :index, params: { user_id: @user.id }

      payouts = assigns(:payouts)
      expect(payouts.count).to eq(@user.payments.count)
      expect(payouts.exclude?(@other_user_payout)).to be(true)
      expect(payouts.first).to eq(@payout_2)

      expect(response.body).to include("Payouts")
      expect(response.body).to include(admin_payout_path(@payout_1))
    end
  end
end

  describe "payout pause/resume with reasons" do
    let(:admin_user) { create(:user, has_payout_privilege: true) }
    let(:target_user) { create(:user) }

    before do
      sign_in admin_user
    end

    describe "#pause" do
      it "pauses payouts and sets admin source" do
        patch :pause, params: { user_id: target_user.id, reason: "Verification required" }
        
        target_user.reload
        expect(target_user.payouts_paused_internally?).to be_truthy
        expect(target_user.payout_pause_source).to eq("admin")
      end

      it "uses default reason when none provided" do
        patch :pause, params: { user_id: target_user.id }
        
        target_user.reload
        expect(target_user.payout_pause_source).to eq("admin")
        # Check that a note was added with default reason
        expect(target_user.comments.with_type_payout_note.last.content).to include("Manual pause by admin")
      end

      it "adds payout note with admin email and reason" do
        expect {
          patch :pause, params: { user_id: target_user.id, reason: "Account review needed" }
        }.to change { target_user.comments.with_type_payout_note.count }.by(1)
        
        note = target_user.comments.with_type_payout_note.last
        expect(note.content).to include("Account review needed")
        expect(note.content).to include(admin_user.email)
      end
    end

    describe "#resume" do
      before do
        target_user.update!(payouts_paused_internally: true)
        target_user.set_payout_pause_source("admin")
      end

      it "resumes payouts and clears pause source" do
        patch :resume, params: { user_id: target_user.id }
        
        target_user.reload
        expect(target_user.payouts_paused_internally?).to be_falsey
        expect(target_user.payout_pause_source).to be_nil
      end

      it "adds payout note with admin email" do
        expect {
          patch :resume, params: { user_id: target_user.id }
        }.to change { target_user.comments.with_type_payout_note.count }.by(1)
        
        note = target_user.comments.with_type_payout_note.last
        expect(note.content).to include("resumed by admin")
        expect(note.content).to include(admin_user.email)
      end
    end
  end
