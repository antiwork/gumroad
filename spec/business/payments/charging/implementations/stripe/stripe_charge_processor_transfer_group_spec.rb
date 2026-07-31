# frozen_string_literal: true

require "spec_helper"

describe StripeChargeProcessor, "#merchant_account_for_transfer_group" do
  let(:processor) { described_class.new }
  let(:merchant_account) { create(:merchant_account) }
  let(:purchase) { create(:purchase_in_progress, merchant_account:) }

  it "resolves a combined charge's CH-prefixed transfer group to the charge's merchant account" do
    charge = create(:charge, purchases: [purchase])

    expect(processor.send(:merchant_account_for_transfer_group, charge.id_with_prefix))
      .to eq(merchant_account)
  end

  it "resolves a bare purchase id transfer group" do
    expect(processor.send(:merchant_account_for_transfer_group, purchase.id.to_s))
      .to eq(merchant_account)
  end

  it "returns nil rather than raising for a blank or unknown transfer group" do
    expect(processor.send(:merchant_account_for_transfer_group, nil)).to be_nil
    expect(processor.send(:merchant_account_for_transfer_group, "")).to be_nil
    expect(processor.send(:merchant_account_for_transfer_group, "CH-99999999")).to be_nil
    expect(processor.send(:merchant_account_for_transfer_group, "99999999")).to be_nil
  end
end
