# frozen_string_literal: true

require "test_helper"

class HandleNewBankAccountWorkerTest < ActiveSupport::TestCase
  self.described_class = HandleNewBankAccountWorker


  context_ HandleNewBankAccountWorker do
  context_ "perform" do
      let(:bank_account) { create(:ach_account) }

  test "calls StripeMerchantAccountManager.handle_new_bank_account with the bank account object" do
        expect(StripeMerchantAccountManager).to receive(:handle_new_bank_account).with(bank_account)
        described_class.new.perform(bank_account.id)
      end

  test "raises (triggering Sidekiq retry) when the manager returns :stripe_unknown_error" do
        allow(StripeMerchantAccountManager).to receive(:handle_new_bank_account).with(bank_account).and_return(:stripe_unknown_error)

        expect { described_class.new.perform(bank_account.id) }.to raise_error(/Stripe bank sync failed/)
      end

  test "does not raise when the manager returns a classified outcome" do
        %i[synced noop_metadata_match invalid_account_holder_name invalid_bank_account stripe_invalid_request].each do |outcome|
          allow(StripeMerchantAccountManager).to receive(:handle_new_bank_account).with(bank_account).and_return(outcome)

          expect { described_class.new.perform(bank_account.id) }.not_to raise_error
        end
      end
    end
  end
end
