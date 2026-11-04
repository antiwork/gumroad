# frozen_string_literal: true

require "spec_helper"

describe Onetime::SyncTaiwanBankHolderNamesToStripe do
  describe ".process" do
    let(:user) { create(:user) }

    before { create(:user_compliance_info, user:, country: "Taiwan") }

    def create_linked_taiwan_bank_account(**attributes)
      create(:taiwan_bank_account, user:, stripe_bank_account_id: "ba_#{SecureRandom.hex(4)}", **attributes)
    end

    it "enqueues a sync for the active, Stripe-linked Taiwan account with an ASCII name" do
      bank_account = create_linked_taiwan_bank_account(account_holder_full_name: "SHIE BING YUAN")

      expect { described_class.process }.to change { HandleNewBankAccountWorker.jobs.size }.by(1)
      expect(HandleNewBankAccountWorker.jobs.last["args"]).to eq([bank_account.id])
    end

    it "normalizes the stored name like the model before enqueueing" do
      bank_account = create_linked_taiwan_bank_account
      bank_account.update_column(:account_holder_full_name, " SHIE BING YUAN\u3000")

      expect { described_class.process }.to change { HandleNewBankAccountWorker.jobs.size }.by(1)
      expect(bank_account.reload.account_holder_full_name).to eq("SHIE BING YUAN")
    end

    it "does not overwrite a name the seller saves after the row is loaded" do
      bank_account = create_linked_taiwan_bank_account
      bank_account.update_column(:account_holder_full_name, " SHIE BING YUAN\u3000")
      loaded = TaiwanBankAccount.find(bank_account.id)
      TaiwanBankAccount.where(id: bank_account.id).update_all(account_holder_full_name: "SHIE BING YUAN JR")

      described_class.new.send(:normalize_holder_name!, loaded)

      expect(bank_account.reload.account_holder_full_name).to eq("SHIE BING YUAN JR")
    end

    it "skips non-ASCII names and accounts that are not the active one" do
      create_linked_taiwan_bank_account(account_holder_full_name: "謝秉原")
      create_linked_taiwan_bank_account(account_holder_full_name: "SHIE BING YUAN")

      expect { described_class.process }.not_to change { HandleNewBankAccountWorker.jobs.size }
    end

    it "skips banks Stripe never accepted and suspended sellers" do
      create(:taiwan_bank_account, user:, account_holder_full_name: "SHIE BING YUAN")
      other_user = create(:user)
      create(:user_compliance_info, user: other_user, country: "Taiwan")
      create(:taiwan_bank_account, user: other_user, stripe_bank_account_id: "ba_suspended", account_holder_full_name: "SHIE BING YUAN")
      other_user.update_columns(user_risk_state: "suspended_for_fraud")

      expect { described_class.process }.not_to change { HandleNewBankAccountWorker.jobs.size }
    end
  end
end
