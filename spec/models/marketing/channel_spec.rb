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

  # The column is a string, so the persisted value is the channel name; a mapping of names
  # to anything else would write a value nothing can read back.
  it "maps every channel to its own name, cart channel included" do
    expect(described_class.action_channels).to eq(
      "x" => "x",
      "instagram" => "instagram",
      "youtube" => "youtube",
      "tiktok" => "tiktok",
      "email" => "email",
      described_class::ABANDONED_CART => described_class::ABANDONED_CART,
    )
  end

  it "reads a persisted action's channel back as the name that was written" do
    action = create(:marketing_action, user: create(:user), channel: described_class::ABANDONED_CART)
    expect(action.reload.channel).to eq(described_class::ABANDONED_CART)
    expect(Marketing::Action.where(channel: described_class::ABANDONED_CART).sole).to eq(action)
  end
end
