# frozen_string_literal: true

describe HandleNewBankAccountWorker do
  describe "perform" do
    let(:bank_account) { create(:ach_account) }

    it "calls StripeMerchantAccountManager.handle_new_bank_account with the bank account object" do
      expect(StripeMerchantAccountManager).to receive(:handle_new_bank_account).with(bank_account)
      described_class.new.perform(bank_account.id)
    end

    it "raises (triggering Sidekiq retry) when the manager returns :stripe_unknown_error" do
      allow(StripeMerchantAccountManager).to receive(:handle_new_bank_account).with(bank_account).and_return(:stripe_unknown_error)

      expect { described_class.new.perform(bank_account.id) }.to raise_error(/Stripe bank sync failed/)
    end

    it "does not raise when the manager returns a classified outcome" do
      %i[synced noop_metadata_match invalid_account_holder_name invalid_bank_account stripe_invalid_request].each do |outcome|
        allow(StripeMerchantAccountManager).to receive(:handle_new_bank_account).with(bank_account).and_return(outcome)

        expect { described_class.new.perform(bank_account.id) }.not_to raise_error
      end
    end
  end
end
