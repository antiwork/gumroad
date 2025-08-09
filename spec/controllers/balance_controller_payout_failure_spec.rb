# frozen_string_literal: true

require "spec_helper"

describe BalanceController do
  let(:seller) { create(:named_seller) }

  describe "GET index with payout failure" do
    include_context "with user signed in as admin for seller"

    context "when seller has a failed payout note" do
      before do
        comment = create(:comment, 
          user: seller, 
          content: "Payout via Stripe on #{Date.current} failed because insufficient funds in bank account. Solution: Please update your bank account information. The balance has been carried over and will be included in your next payout.",
          comment_type: Comment::CommentType::PAYOUT_NOTE,
          author_id: User::GUMROAD_ADMIN_ID
        )
        
        comment.update!(created_at: Time.current)
      end

      it "includes failed payout note in presenter data" do
        get :index
        expect(response).to be_successful
        
        payout_presenter = assigns(:payout_presenter)
        props = payout_presenter.props
        
        expect(props[:next_payout_period_data]).to be_present
        expect(props[:next_payout_period_data][:payout_note]).to be_present
        expect(props[:next_payout_period_data][:payout_note].downcase).to include("failed")
      end
    end

    context "when seller has no failed payout note" do
      it "does not include payout note in presenter data" do
        get :index
        expect(response).to be_successful
        
        payout_presenter = assigns(:payout_presenter)
        props = payout_presenter.props
        
        payout_note = props[:next_payout_period_data]&.[](:payout_note)
        expect(payout_note).to be_nil.or satisfy { |v| !v.to_s.downcase.include?("failed") }
      end
    end
  end
end