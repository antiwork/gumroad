# frozen_string_literal: true

describe HandleNewBankAccountWorker do
  describe "perform" do
    let(:bank_account) { create(:ach_account) }

    it "calls StripeMerchantAccountManager.handle_new_bank_account with the bank account object" do
      expect(StripeMerchantAccountManager).to receive(:handle_new_bank_account).with(bank_account)
      described_class.new.perform(bank_account.id)
    end
  end
end
