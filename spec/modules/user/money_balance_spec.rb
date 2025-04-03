# frozen_string_literal: true

require "spec_helper"

describe User::MoneyBalance do
  before :each do
    @user = create(:user)
  end

  describe "#unpaid_balance_cents" do
    context "via SQL" do
      it "returns sum of unpaid balance in cents" do
        create(:balance, user: @user, amount_cents: 100, state: "unpaid", date: 1.day.ago)
        create(:balance, user: @user, amount_cents: 200, state: "unpaid", date: 3.days.ago)
        expect(@user.unpaid_balance_cents).to eq 300
      end

      it "ignores paid balance" do
        create(:balance, user: @user, amount_cents: 100, state: "paid")
        expect(@user.unpaid_balance_cents).to eq 0
      end

      it "ignores someone else's balance" do
        create(:balance, user: create(:user), amount_cents: 100, state: "paid")
        expect(@user.unpaid_balance_cents).to eq 0
      end
    end

    context "via Elasticsearch", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      it "returns sum of unpaid balance in cents" do
        create(:balance, user: @user, amount_cents: 100, state: "unpaid", date: 1.day.ago)
        create(:balance, user: @user, amount_cents: 200, state: "unpaid", date: 3.days.ago)
        expect(@user.unpaid_balance_cents(via: :elasticsearch)).to eq 300
      end

      it "ignores paid balance" do
        create(:balance, user: @user, amount_cents: 100, state: "paid")
        expect(@user.unpaid_balance_cents(via: :elasticsearch)).to eq 0
      end

      it "ignores someone else's balance" do
        create(:balance, user: create(:user), amount_cents: 100, state: "paid")
        expect(@user.unpaid_balance_cents(via: :elasticsearch)).to eq 0
      end

      it "still returns the correct balance if Elasticsearch call failed and sends error to Bugsnag" do
        create(:balance, user: @user, amount_cents: 100, state: "unpaid", date: 1.day.ago)
        create(:balance, user: @user, amount_cents: 200, state: "unpaid", date: 3.days.ago)
        expect(Balance).to receive(:amount_cents_sum_for).with(@user).and_raise(Net::OpenTimeout)
        expect(Bugsnag).to receive(:notify).and_call_original
        expect(@user.unpaid_balance_cents(via: :elasticsearch)).to eq 300
      end
    end
  end

  describe "#unpaid_balance_cents_up_to_date" do
    it "returns sum of unpaid balance in cents with date up to a given date" do
      create(:balance, user: @user, amount_cents: 100, state: "unpaid", date: 3.days.ago)
      create(:balance, user: @user, amount_cents: 200, state: "unpaid", date: 5.days.ago)
      expect(@user.unpaid_balance_cents_up_to_date(1.day.ago)).to eq 300
    end

    it "ignores paid balance" do
      create(:balance, user: @user, amount_cents: 100, state: "paid", date: 3.days.ago)
      expect(@user.unpaid_balance_cents_up_to_date(1.day.ago)).to eq 0
    end

    it "ignores unpaid balance with date after a given date" do
      create(:balance, user: @user, amount_cents: 100, state: "paid", date: 1.day.ago)
      expect(@user.unpaid_balance_cents_up_to_date(3.days.ago)).to eq 0
    end
  end

  describe "#unpaid_balances_up_to_date" do
    it "returns all unpaid balances with date up to a given date" do
      b1 = create(:balance, user: @user, amount_cents: 100, state: "unpaid", date: 3.days.ago)
      b2 = create(:balance, user: @user, amount_cents: 200, state: "unpaid", date: 5.days.ago)
      result = @user.unpaid_balances_up_to_date(1.day.ago)
      expect(result.size).to eq 2
      expect(result.include?(b1)).to be(true)
      expect(result.include?(b2)).to be(true)
    end

    it "ignores paid balances" do
      create(:balance, user: @user, amount_cents: 100, state: "paid", date: 3.days.ago)
      expect(@user.unpaid_balances_up_to_date(1.day.ago)).to be_empty
    end

    it "ignores balances with date after a given date" do
      create(:balance, user: @user, amount_cents: 100, state: "unpaid", date: 1.day.ago)
      expect(@user.unpaid_balances_up_to_date(3.days.ago)).to be_empty
    end
  end

  describe "#unpaid_balance_cents_up_to_date_held_by_gumroad" do
    it "returns unpaid cents that are held by gumroad with date up to the given date" do
      create(:balance, user: @user, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                       amount_cents: 100, state: "unpaid", date: 3.days.ago)
      create(:balance, user: @user, merchant_account: MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id),
                       amount_cents: 200, state: "unpaid", date: 5.days.ago)
      expect(@user.unpaid_balance_cents_up_to_date_held_by_gumroad(1.day.ago)).to eq(300)
    end

    it "does not include balance held in stripe connect account" do
      create(:balance, user: @user, merchant_account: create(:merchant_account, user: @user),
                       amount_cents: 100, state: "unpaid", date: 3.days.ago)
      expect(@user.unpaid_balance_cents_up_to_date_held_by_gumroad(1.day.ago)).to eq(0)
    end

    it "does not include paid balance" do
      create(:balance, user: @user, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                       amount_cents: 100, state: "paid", date: 3.days.ago)
      expect(@user.unpaid_balance_cents_up_to_date_held_by_gumroad(1.day.ago)).to eq(0)
    end

    it "does not include balance with date after the given date" do
      create(:balance, user: @user, merchant_account: MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id),
                       amount_cents: 100, state: "unpaid", date: 1.day.ago)
      expect(@user.unpaid_balance_cents_up_to_date_held_by_gumroad(3.days.ago)).to eq(0)
    end
  end


  describe "#unpaid_balance_holding_cents_up_to_date_held_by_stripe" do
    let(:stripe_connect_merchant_account) { create(:merchant_account, user: @user, currency: "aud") }

    it "returns unpaid holding cents that are held in stripe connect account with date up to the given date" do
      create(:balance, user: @user, merchant_account: stripe_connect_merchant_account,
                       holding_currency: stripe_connect_merchant_account.currency,
                       amount_cents: 100, holding_amount_cents: 129, state: "unpaid", date: 3.days.ago)
      create(:balance, user: @user, merchant_account: stripe_connect_merchant_account,
                       holding_currency: stripe_connect_merchant_account.currency,
                       amount_cents: 200, holding_amount_cents: 258, state: "unpaid", date: 5.days.ago)

      expect(@user.unpaid_balance_holding_cents_up_to_date_held_by_stripe(1.day.ago)).to eq(387)
    end

    it "does not include balance held by gumroad" do
      create(:balance, user: @user, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id),
                       amount_cents: 100, state: "unpaid", date: 3.days.ago)
      create(:balance, user: @user, merchant_account: MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id),
                       amount_cents: 200, state: "unpaid", date: 5.days.ago)

      expect(@user.unpaid_balance_holding_cents_up_to_date_held_by_stripe(1.day.ago)).to eq(0)
    end

    it "does not include paid balance" do
      create(:balance, user: @user, merchant_account: stripe_connect_merchant_account,
                       amount_cents: 100, state: "paid", date: 3.days.ago)
      expect(@user.unpaid_balance_holding_cents_up_to_date_held_by_stripe(1.day.ago)).to eq(0)
    end

    it "does not include balance with date after the given date" do
      create(:balance, user: @user, merchant_account: stripe_connect_merchant_account,
                       amount_cents: 100, state: "unpaid", date: 1.day.ago)
      expect(@user.unpaid_balance_holding_cents_up_to_date_held_by_stripe(3.days.ago)).to eq(0)
    end
  end

  describe "#paid_payments_cents_for_date" do
    let(:payout_date) { Date.today }

    before do
      create(:payment,           payout_period_end_date: payout_date,   user: @user, amount_cents: 1_00) # included
      create(:payment_completed, payout_period_end_date: payout_date,   user: @user, amount_cents: 10_00) # included
      create(:payment_unclaimed, payout_period_end_date: payout_date,   user: @user, amount_cents: 100_00) # included
      create(:payment_returned,  payout_period_end_date: payout_date,   user: @user, amount_cents: 100_000) # ignored
      create(:payment_reversed,  payout_period_end_date: payout_date,   user: @user, amount_cents: 1_000_000) # ignored
      create(:payment_failed,    payout_period_end_date: payout_date,   user: @user, amount_cents: 10_000_000) # ignored
      create(:payment,           payout_period_end_date: payout_date - 1, user: @user, amount_cents: 100_000_000) # ignored
    end

    it "returns the sum of balances that haven't failed or been returned/reversed, and only the ones on the same day" do
      expect(@user.paid_payments_cents_for_date(payout_date)).to eq(111_00)
    end
  end

  describe "#formatted_balance_to_forfeit" do
    context "country_change" do
      let(:merchant_account) { create(:merchant_account, user: @user) }

      it "returns formatted balance if there's a positive balance" do
        create(:balance, user: @user, merchant_account:, amount_cents: 1322)
        expect(@user.formatted_balance_to_forfeit(:country_change)).to eq("$13.22")
      end

      it "returns nil if there's a zero or negative balance to forfeit" do
        expect(@user.formatted_balance_to_forfeit(:country_change)).to eq(nil)

        create(:balance, user: @user, state: :unpaid, merchant_account:, amount_cents: -233)
        expect(@user.formatted_balance_to_forfeit(:country_change)).to eq(nil)
      end
    end

    context "account_closure" do
      it "returns nil when the delete_account_forfeit_balance feature is inactive" do
        create(:balance, user: @user, state: :unpaid, amount_cents: 942)
        expect(@user.formatted_balance_to_forfeit(:account_closure)).to eq(nil)
      end

      context "when the delete_account_forfeit_balance feature is active" do
        before do
          Feature.activate_user(:delete_account_forfeit_balance, @user)
        end

        it "returns formatted balance if there's a positive balance" do
          create(:balance, user: @user, state: :unpaid, amount_cents: 10_00)
          expect(@user.formatted_balance_to_forfeit(:account_closure)).to eq("$10")
        end

        it "returns nil if there's a zero or negative balance to forfeit" do
          expect(@user.formatted_balance_to_forfeit(:account_closure)).to eq(nil)

          create(:balance, user: @user, state: :unpaid, amount_cents: -233)
          expect(@user.formatted_balance_to_forfeit(:account_closure)).to eq(nil)
        end
      end
    end
  end

  describe "#forfeit_unpaid_balance!" do
    before do
      stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id) # For negative credits
    end

    context "country_change" do
      let(:merchant_account) { create(:merchant_account, user: @user) }

      it "does nothing if there is no balance to forfeit" do
        expect(@user.balances.unpaid.sum(:amount_cents)).to eq(0)
        expect(@user.forfeit_unpaid_balance!(:country_change)).to eq(nil)

        expect(@user.reload.comments.last).to eq(nil)
      end

      it "marks balances as forfeited and adds a comment" do
        balance1 = create(:balance, user: @user, amount_cents: 10_00, merchant_account:, date: Date.yesterday)
        balance2 = create(:balance, user: @user, amount_cents: 20_00, merchant_account:, date: Date.today)
        balance3 = create(:balance, user: @user, amount_cents: 30_00, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), date: Date.today)

        @user.forfeit_unpaid_balance!(:country_change)

        expect(balance1.reload.state).to eq("forfeited")
        expect(balance2.reload.state).to eq("forfeited")
        expect(balance3.reload.state).to eq("unpaid")
        expect(@user.comments.last.comment_type).to eq(Comment::COMMENT_TYPE_BALANCE_FORFEITED)
        expect(@user.comments.last.content).to eq("Balance of $30 has been forfeited. Reason: Country changed. Balance IDs: #{balance1.id}, #{balance2.id}")
      end
    end

    context "account_closure" do
      context "when the delete_account_forfeit_balance feature is not active" do
        it "does nothing" do
          create(:balance, user: @user, amount_cents: 255)
          expect(@user.forfeit_unpaid_balance!(:account_closure)).to eq(nil)

          expect(@user.reload.comments.last).to eq(nil)
        end
      end

      context "when the delete_account_forfeit_balance feature is active" do
        before do
          Feature.activate_user(:delete_account_forfeit_balance, @user)
        end

        it "does nothing if there is no balance to forfeit" do
          expect(@user.forfeit_unpaid_balance!(:account_closure)).to eq(nil)

          expect(@user.reload.comments.last).to eq(nil)
        end

        it "marks balances as forfeited and adds a comment" do
          balance1 = create(:balance, user: @user, amount_cents: 255, date: Date.yesterday)
          balance2 = create(:balance, user: @user, amount_cents: 635, date: Date.today)

          @user.forfeit_unpaid_balance!(:account_closure)

          expect(balance1.reload.state).to eq("forfeited")
          expect(balance2.reload.state).to eq("forfeited")
          expect(@user.comments.last.comment_type).to eq(Comment::COMMENT_TYPE_BALANCE_FORFEITED)
          expect(@user.comments.last.content).to eq("Balance of $8.90 has been forfeited. Reason: Account closed. Balance IDs: #{balance1.id}, #{balance2.id}")
        end
      end
    end
  end

  describe "#validate_account_closure_balances!" do
    context "when the delete_account_forfeit_balance feature is not active" do
      it "raises UnpaidBalanceError" do
        create(:balance, user: @user, state: :unpaid, amount_cents: 942)

        expect { @user.validate_account_closure_balances! }.to raise_error(User::UnpaidBalanceError) do |error|
          expect(error.amount).to eq("$9.42")
        end
      end
    end

    context "when the delete_account_forfeit_balance feature is active" do
      before do
        Feature.activate_user(:delete_account_forfeit_balance, @user)
      end

      it "returns nil if there's a zero balance" do
        expect(@user.validate_account_closure_balances!).to eq(nil)
      end

      it "raises User::UnpaidBalanceError if there's non-zero balance to forfeit" do
        create(:balance, user: @user, state: :unpaid, amount_cents: 10_00, date: Date.yesterday)
        expect { @user.validate_account_closure_balances! }.to raise_error(User::UnpaidBalanceError) do |error|
          expect(error.amount).to eq("$10")
        end

        create(:balance, user: @user, state: :unpaid, amount_cents: -2333)
        expect { @user.validate_account_closure_balances! }.to raise_error(User::UnpaidBalanceError) do |error|
          expect(error.amount).to eq("$-13.33")
        end
      end
    end
  end
end
