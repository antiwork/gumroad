# frozen_string_literal: true

require "spec_helper"

describe Onetime::SyncTaiwanBankHolderNamesToStripe do
  describe ".process" do
    let(:user) { create(:user) }

    before { create(:user_compliance_info, user:, country: "Taiwan") }

    it "enqueues a sync for an active Taiwan account with an ASCII name" do
      bank_account = create(:taiwan_bank_account, user:, account_holder_full_name: "SHIE BING YUAN")

      expect { described_class.process }.to change { HandleNewBankAccountWorker.jobs.size }.by(1)
      expect(HandleNewBankAccountWorker.jobs.last["args"]).to eq([bank_account.id])
    end

    it "strips surrounding whitespace before enqueueing" do
      bank_account = create(:taiwan_bank_account, user:)
      bank_account.update_column(:account_holder_full_name, " SHIE BING YUAN ")

      expect { described_class.process }.to change { HandleNewBankAccountWorker.jobs.size }.by(1)
      expect(bank_account.reload.account_holder_full_name).to eq("SHIE BING YUAN")
    end

    it "skips non-ASCII names and inactive accounts" do
      create(:taiwan_bank_account, user:, account_holder_full_name: "謝秉原")
      create(:taiwan_bank_account, user:, account_holder_full_name: "SHIE BING YUAN").mark_deleted!

      expect { described_class.process }.not_to change { HandleNewBankAccountWorker.jobs.size }
    end
  end
end
