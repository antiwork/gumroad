# frozen_string_literal: true

require "spec_helper"

describe SuoSemaphore do
  it "keys the seller call inventory lock on the seller id" do
    client = described_class.seller_call_inventory(42)

    expect(client.key).to eq("locks:seller:42:call_inventory")
  end

  it "keys the product inventory lock on the product id" do
    client = described_class.product_inventory(99)

    expect(client.key).to eq("locks:product:99:inventory")
  end
end
