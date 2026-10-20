# frozen_string_literal: true

require "spec_helper"

describe Onetime::ClearNewCustomerDefaultOfferCodes do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 4000) }
  let(:offer_code) { create(:offer_code, user: seller, products: [product], code: "launch", amount_cents: nil, amount_percentage: 10, currency_type: nil) }

  # Validations now refuse this pairing, so the legacy row is written directly.
  def legacy_new_customer_default(product, offer_code)
    product.update!(default_offer_code: offer_code)
    offer_code.update_columns(new_customers_only: true)
  end

  def ordinary_default(code)
    ordinary_product = create(:product, user: seller, price_cents: 4000)
    ordinary_code = create(:offer_code, user: seller, products: [ordinary_product], code:, amount_cents: nil, amount_percentage: 10, currency_type: nil)
    ordinary_product.update!(default_offer_code: ordinary_code)
    ordinary_product
  end

  # Deterministic interleaving: runs the block just before the task's own UPDATE clears a default, after
  # anything it read to decide that the row matched.
  def before_the_clear(&block)
    fired = false
    allow(Link.connection).to receive(:exec_update).and_wrap_original do |original, sql, *rest|
      if !fired && sql.to_s.match?(/\AUPDATE `links` SET .*`default_offer_code_id` = NULL/)
        fired = true
        block.call
      end
      original.call(sql, *rest)
    end
    -> { fired }
  end

  it "reports only the new-customer defaults it would clear, without changing them" do
    legacy_new_customer_default(product, offer_code)
    ordinary_default("ordinary")

    expect(described_class.new.process).to eq(matched: 1, cleared: 0, skipped: 0, sample: [{ product_id: product.id, offer_code_id: offer_code.id }])
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
  end

  it "clears only defaults that are new-customers-only codes" do
    legacy_new_customer_default(product, offer_code)
    ordinary_product = ordinary_default("ordinary")
    product_without_default = create(:product, user: seller)

    expect(described_class.new(dry_run: false).process).to eq(matched: 1, cleared: 1, skipped: 0, sample: [{ product_id: product.id, offer_code_id: offer_code.id }])
    expect(product.reload.default_offer_code_id).to be_nil
    expect(ordinary_product.reload.default_offer_code).to be_present
    expect(product_without_default.reload.default_offer_code_id).to be_nil
    expect(offer_code.reload).to be_alive
  end

  it "counts every match across batches but keeps only a bounded sample" do
    stub_const("#{described_class}::BATCH_SIZE", 2)
    stub_const("#{described_class}::SAMPLE_SIZE", 2)
    products = 3.times.map do |i|
      create(:product, user: seller, price_cents: 4000).tap do |p|
        legacy_new_customer_default(p, create(:offer_code, user: seller, products: [p], code: "launch#{i}", amount_cents: nil, amount_percentage: 10, currency_type: nil))
      end
    end

    report = described_class.new(dry_run: false).process

    expect(report.slice(:matched, :cleared, :skipped)).to eq(matched: 3, cleared: 3, skipped: 0)
    expect(report[:sample].size).to eq(2)
    expect(products.map { _1.reload.default_offer_code_id }).to all(be_nil)
  end

  it "leaves deleted products for their restore to repair" do
    legacy_new_customer_default(product, offer_code)
    product.update_column(:deleted_at, Time.current)

    expect(described_class.new(dry_run: false).process).to include(matched: 0, cleared: 0)
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
  end

  it "finds nothing to do when no default is a new-customers-only code" do
    product.update!(default_offer_code: offer_code)

    expect(described_class.new(dry_run: false).process).to eq(matched: 0, cleared: 0, skipped: 0, sample: [])
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
  end

  it "does nothing more when it runs again" do
    legacy_new_customer_default(product, offer_code)
    described_class.new(dry_run: false).process

    expect(described_class.new(dry_run: false).process).to include(matched: 0, cleared: 0)
  end

  it "keeps a default the seller repoints to an ordinary code between the check and the write" do
    legacy_new_customer_default(product, offer_code)
    ordinary_code = create(:offer_code, user: seller, products: [product], code: "ordinary", amount_cents: nil, amount_percentage: 10, currency_type: nil)
    fired = before_the_clear { Link.where(id: product.id).update_all(default_offer_code_id: ordinary_code.id) }

    expect(described_class.new(dry_run: false).process).to include(matched: 1, cleared: 0, skipped: 1)
    expect(fired.call).to be(true)
    expect(product.reload.default_offer_code_id).to eq(ordinary_code.id)
  end

  it "keeps a default whose code is made ordinary between the check and the write" do
    legacy_new_customer_default(product, offer_code)
    fired = before_the_clear { OfferCode.find(offer_code.id).update!(new_customers_only: false) }

    expect(described_class.new(dry_run: false).process).to include(matched: 1, cleared: 0, skipped: 1)
    expect(fired.call).to be(true)
    expect(offer_code.reload.new_customers_only?).to be(false)
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

  it "stops on a failure and leaves the row to clear on a rerun" do
    legacy_new_customer_default(product, offer_code)
    allow_any_instance_of(Link).to receive(:invalidate_cache).and_raise(ActiveRecord::StatementInvalid, "cache table unavailable")

    expect { described_class.new(dry_run: false).process }.to raise_error(ActiveRecord::StatementInvalid)
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)

    allow_any_instance_of(Link).to receive(:invalidate_cache).and_call_original
    expect(described_class.new(dry_run: false).process).to include(matched: 1, cleared: 1)
    expect(product.reload.default_offer_code_id).to be_nil
  end
end
