# frozen_string_literal: true

require "spec_helper"

describe Purchase::CreateService, "inventory lock" do
  def lock_client_for(product)
    described_class.new(product:, params: { purchase: {} }).send(:inventory_lock_client)
  end

  def perform_until_lock(product)
    described_class.new(product:, params: { purchase: {} }).perform
  end

  it "acquires one seller-keyed lock for every call product owned by that seller" do
    seller = create(:user, :eligible_for_service_products)
    product_a = create(:call_product, user: seller)
    product_b = create(:call_product, user: seller)
    expected_key = "locks:seller:#{seller.id}:call_inventory"

    expect(lock_client_for(product_a).key).to eq(expected_key)
    expect(lock_client_for(product_b).key).to eq(expected_key)
  end

  it "keeps a product-keyed lock for non-call inventory products" do
    product = create(:product, max_purchase_count: 10)

    expect(lock_client_for(product).key).to eq("locks:product:#{product.id}:inventory")
  end

  it "takes the seller-scoped lock on the checkout path for a call product" do
    seller = create(:user, :eligible_for_service_products)
    product = create(:call_product, user: seller)
    lock = instance_double(Suo::Client::Redis, lock: nil)

    expect(SuoSemaphore).to receive(:seller_call_inventory)
      .with(seller.id, hash_including(:acquisition_timeout))
      .and_return(lock)
    expect(SuoSemaphore).not_to receive(:product_inventory)

    purchase, error = perform_until_lock(product)

    expect(purchase).to be_nil
    expect(error).to eq("Sorry, something went wrong. Please try again.")
  end

  it "takes the product-scoped lock on the checkout path for a capped non-call product" do
    product = create(:product, max_purchase_count: 10)
    lock = instance_double(Suo::Client::Redis, lock: nil)

    expect(SuoSemaphore).to receive(:product_inventory)
      .with(product.id, hash_including(:acquisition_timeout))
      .and_return(lock)
    expect(SuoSemaphore).not_to receive(:seller_call_inventory)

    purchase, error = perform_until_lock(product)

    expect(purchase).to be_nil
    expect(error).to eq("Sorry, something went wrong. Please try again.")
  end
end
