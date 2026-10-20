# frozen_string_literal: true

require "spec_helper"

describe Onetime::ClearNewCustomerDefaultOfferCodes do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 4000) }
  let(:offer_code) { create(:offer_code, user: seller, products: [product], code: "launch", amount_cents: nil, amount_percentage: 10, currency_type: nil) }

  # #8538 let a product's automatically applied code be switched to new customers only; validations now
  # refuse that, so the legacy row is written directly.
  def legacy_new_customer_default(product, offer_code)
    product.update!(default_offer_code: offer_code)
    offer_code.update_columns(new_customers_only: true)
  end

  it "reports only the new-customer defaults it would clear, without changing them" do
    legacy_new_customer_default(product, offer_code)
    ordinary_product = create(:product, user: seller, price_cents: 4000)
    ordinary_code = create(:offer_code, user: seller, products: [ordinary_product], code: "ordinary", amount_cents: nil, amount_percentage: 10, currency_type: nil)
    ordinary_product.update!(default_offer_code: ordinary_code)

    expect(described_class.new.process).to eq([{ product_id: product.id, offer_code_id: offer_code.id }])
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
  end

  it "clears only defaults that are new-customers-only codes" do
    legacy_new_customer_default(product, offer_code)
    ordinary_product = create(:product, user: seller, price_cents: 4000)
    ordinary_code = create(:offer_code, user: seller, products: [ordinary_product], code: "ordinary", amount_cents: nil, amount_percentage: 10, currency_type: nil)
    ordinary_product.update!(default_offer_code: ordinary_code)
    product_without_default = create(:product, user: seller)

    expect(described_class.new(dry_run: false).process).to eq([{ product_id: product.id, offer_code_id: offer_code.id }])
    expect(product.reload.default_offer_code_id).to be_nil
    expect(ordinary_product.reload.default_offer_code_id).to eq(ordinary_code.id)
    expect(product_without_default.reload.default_offer_code_id).to be_nil
    expect(offer_code.reload).to be_alive
  end

  it "leaves deleted products for their restore to repair" do
    legacy_new_customer_default(product, offer_code)
    product.update_column(:deleted_at, Time.current)

    expect(described_class.new(dry_run: false).process).to be_empty
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
  end

  it "finds nothing to do when no default is a new-customers-only code" do
    product.update!(default_offer_code: offer_code)

    expect(described_class.new(dry_run: false).process).to be_empty
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
  end

  it "does nothing more when it runs again" do
    legacy_new_customer_default(product, offer_code)
    described_class.new(dry_run: false).process

    expect(described_class.new(dry_run: false).process).to be_empty
  end

  it "keeps a default the seller repointed to an ordinary code after the batch was read" do
    legacy_new_customer_default(product, offer_code)
    ordinary_code = create(:offer_code, user: seller, products: [product], code: "ordinary", amount_cents: nil, amount_percentage: 10, currency_type: nil)
    allow_any_instance_of(Link).to receive(:with_lock).and_wrap_original do |original, *args, &block|
      Link.where(id: product.id).update_all(default_offer_code_id: ordinary_code.id)
      original.call(*args, &block)
    end

    expect(described_class.new(dry_run: false).process).to be_empty
    expect(product.reload.default_offer_code_id).to eq(ordinary_code.id)
  end

  it "keeps a default whose code was made ordinary again after the batch was read" do
    legacy_new_customer_default(product, offer_code)
    allow_any_instance_of(Link).to receive(:with_lock).and_wrap_original do |original, *args, &block|
      offer_code.update_columns(new_customers_only: false)
      original.call(*args, &block)
    end

    expect(described_class.new(dry_run: false).process).to be_empty
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
  end

  it "expires the cleared product's cached pages and leaves other products' alone" do
    legacy_new_customer_default(product, offer_code)
    other_product = create(:product, user: seller)
    product.product_cached_values.create!
    other_product.product_cached_values.create!

    described_class.new(dry_run: false).process

    expect(product.reload.product_cached_values.fresh.size).to eq(0)
    expect(other_product.reload.product_cached_values.fresh.size).to eq(1)
  end
end
