# frozen_string_literal: true

require "spec_helper"

describe CheckIndianCardMandateRegistrationJob do
  it "runs the setup-intent e-mandate check for the given purchase" do
    purchase = create(:purchase_in_progress)
    other_purchase = create(:purchase_in_progress)

    expect(Purchase).to receive(:find).with(purchase.id).and_return(purchase)
    expect(purchase).to receive(:check_indian_card_setup_intent_mandate_was_registered)
    expect(other_purchase).not_to receive(:check_indian_card_setup_intent_mandate_was_registered)

    described_class.new.perform(purchase.id)
  end

  it "is configured for the low queue with a unique lock" do
    expect(described_class.sidekiq_options["queue"]).to eq(:low)
    expect(described_class.sidekiq_options["lock"]).to eq(:until_executed)
  end
end
