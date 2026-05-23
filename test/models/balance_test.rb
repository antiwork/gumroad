# frozen_string_literal: true

require "test_helper"

class BalanceTest < ActiveSupport::TestCase
  self.described_class = Balance



  context_ Balance do
    let(:user) { create(:user) }
    let(:merchant_account) { create(:merchant_account, user:) }

  context_ "validate_amounts_are_only_changed_when_unpaid" do
      let(:balance) { create(:balance, user:, merchant_account:, date: Date.today) }

  context_ "new balance" do
  test "allows the balance creation without error" do
          balance
        end
      end

  context_ "updating balance's amounts and is unpaid" do
  test "allows the balance's amounts to be updated" do
          balance.increment(:amount_cents, 1000)
          balance.save!
        end
      end

  context_ "updating balance's amounts and is processing" do
        before do
          balance.mark_processing!
          balance.increment(:amount_cents, 1000)
        end

  test "raises an error if save! is called with the amount changed" do
          expect { balance.save! }.to raise_error(ActiveRecord::RecordInvalid, /Amount cents may not be changed in processing state/)
        end
      end

  context_ "updating balance's amounts and is paid" do
        before do
          balance.mark_processing!
          balance.mark_paid!
          balance.increment(:amount_cents, 1000)
        end

  test "does not allow the balance's amounts to be updated" do
          expect { balance.save! }.to raise_error(ActiveRecord::RecordInvalid, /Amount cents may not be changed in paid state/)
        end
      end

  context_ "updating balance's amounts and was paid then marked unpaid again" do
        before do
          balance.mark_processing!
          balance.mark_paid!
          balance.mark_unpaid!
          balance.increment(:amount_cents, 1000)
        end

  test "allows the balance's amounts to be updated" do
          balance.save!
        end
      end
    end

  context_ "forfeited balances" do
      let(:balance) { create(:balance) }

  test "allows the balance to be forfeited" do
        balance.mark_forfeited!
      end
    end

  context_ "#state" do
  test "has an initial state of unpaid" do
        expect(Balance.new.state).to eq("unpaid")
      end
    end
  end
end
