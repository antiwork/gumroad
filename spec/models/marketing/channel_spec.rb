# frozen_string_literal: true

require "spec_helper"

describe Marketing::Channel do
  it "keeps the cart channel out of the posting picker" do
    expect(described_class::ALL.keys).not_to include(described_class::ABANDONED_CART)
    expect(described_class.live?(described_class::ABANDONED_CART)).to eq(false)
  end

  it "records the cart channel under the workflow's own abandoned-cart type" do
    expect(described_class::ABANDONED_CART).to eq(Workflow::ABANDONED_CART_TYPE)
  end

  it "gives every channel a persisted value that does not move with the picker" do
    expect(described_class.action_channels).to eq(
      "x" => 0, "instagram" => 1, "youtube" => 2, "tiktok" => 3, described_class::ABANDONED_CART => 5
    )
  end
end
