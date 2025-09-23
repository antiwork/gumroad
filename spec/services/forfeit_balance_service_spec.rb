# frozen_string_literal: true

require "spec_helper"

describe ForfeitBalanceService do
  let(:user) { create(:named_user) }
  let(:merchant_account) { create(:merchant_account, user:, charge_processor_id: StripeChargeProcessor.charge_processor_id) }

  context "country_change" do
    before do
      @service = ForfeitBalanceService.new(user:, reason: :country_change)
    end

    describe "#process" do
      context "when the user doesn't have an unpaid balance" do
        it "returns nil" do
          expect(@service.process).to eq(nil)

          expect(user.reload.comments.last).to eq(nil)
        end
      end

      context "when the user has an unpaid balance" do
        before do
          @balance = create(:balance, merchant_account:, user:, amount_cents: 1050)
        end

        it "marks the balances as forfeited" do
          @service.process

          expect(@balance.reload.state).to eq("forfeited")
          expect(user.reload.unpaid_balance_cents).to eq(0)
        end

        it "adds a comment on the user" do
          @service.process

          comment = user.reload.comments.last
          expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_BALANCE_FORFEITED)
          expect(comment.content).to eq("Balance of $10.50 has been forfeited. Reason: Country changed. Balance IDs: #{Balance.last.id}")
        end

        it "does not add a negative credit" do
          @service.process

          expect(user.reload.credits.last).to be nil
        end
      end
    end

    describe "#balance_amount_cents_to_forfeit" do
      it "returns the correctly formatted balance" do
        create(:balance, user:, merchant_account:, amount_cents: 765)

        expect(@service.balance_amount_cents_to_forfeit).to eq(765)
      end

      it "excludes balances held by Gumroad" do
        create(:balance, user:, merchant_account: MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id), amount_cents: 765)

        expect(@service.balance_amount_cents_to_forfeit).to eq(0)
      end
    end

    describe "#balance_amount_formatted" do
      it "returns the correctly formatted balance" do
        @balance = create(:balance, user:, merchant_account:, amount_cents: 680)

        expect(@service.balance_amount_formatted).to eq("$6.80")
      end
    end
  end

  context "account_closure" do
    before do
      @service = ForfeitBalanceService.new(user:, reason: :account_closure)
    end

    describe "#process" do
      context "when the user doesn't have an unpaid balance" do
        it "returns nil" do
          expect(@service.process).to eq(nil)

          expect(user.reload.comments.last).to eq(nil)
        end
      end

      context "when the user has a positive unpaid balance" do
        before do
          @balance = create(:balance, user:, amount_cents: 876)
        end

        it "marks the balances as forfeited" do
          @service.process

          expect(@balance.reload.state).to eq("forfeited")
          expect(user.reload.unpaid_balance_cents).to eq(0)
        end

        it "adds a comment on the user" do
          @service.process

          comment = user.reload.comments.last
          expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_BALANCE_FORFEITED)
          expect(comment.content).to eq("Balance of $8.76 has been forfeited. Reason: Account closed. Balance IDs: #{Balance.last.id}")
        end

        it "does not add a negative credit" do
          @service.process

          expect(user.reload.credits.last).to be nil
        end
      end

      context "when the user has a negative unpaid balance" do
        before do
          @balance = create(:balance, user:, merchant_account:, amount_cents: -765)
        end

        it "doesn't forfeit the balance" do
          expect(@service.process).to eq(nil)

          expect(@balance.reload.state).to eq("unpaid")
          expect(user.reload.comments.last).to eq(nil)
        end
      end
    end

    describe "#balance_amount_cents_to_forfeit" do
      it "returns the correct amount" do
        create(:balance, user:, amount_cents: 850)

        expect(@service.balance_amount_cents_to_forfeit).to eq(850)
      end
    end

    describe "#balance_amount_formatted" do
      it "returns the correctly formatted balance" do
        @balance = create(:balance, user:, amount_cents: 589)

        expect(@service.balance_amount_formatted).to eq("$5.89")
      end
    end
  end
end
