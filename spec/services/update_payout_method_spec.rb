# frozen_string_literal: true

require "spec_helper"

describe UpdatePayoutMethod do
  describe "#process" do
    describe "updating only the account holder name" do
      let(:user) { create(:named_user) }

      context "when the seller is in a country that syncs holder name to Stripe" do
        let!(:bank_account) { create(:japan_bank_account, user:) }
        let!(:compliance_info) { create(:user_compliance_info, user:, country: "Japan") }

        it "saves the name and enqueues HandleNewBankAccountWorker" do
          params = ActionController::Parameters.new(
            bank_account: { type: JapanBankAccount.name, account_holder_full_name: "ヤマダ タロウ" }
          )

          expect do
            result = described_class.new(user_params: params, seller: user).process
            expect(result).to eq(success: true)
          end.to change { HandleNewBankAccountWorker.jobs.size }.by(1)

          expect(bank_account.reload.account_holder_full_name).to eq("ヤマダ タロウ")
        end
      end
    end
  end
end
