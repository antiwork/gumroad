# frozen_string_literal: true

require "spec_helper"

describe Onetime::ClearDetachedDefaultOfferCodes do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, price_cents: 2000) }

  it "clears the default when the product was removed from a product-specific code" do
    other_product = create(:product, user: seller)
    offer_code = create(:offer_code, user: seller, products: [product, other_product])
    product.update!(default_offer_code_id: offer_code.id)
    # Collection deletes skip offer code validations, like the flows that
    # created these rows before the removed products validation existed.
    offer_code.products.delete(product)

    expect do
      described_class.new(dry_run: false).process
    end.to change { product.reload.default_offer_code_id }.from(offer_code.id).to(nil)
  end

  it "clears the default when the code was deleted" do
    offer_code = create(:offer_code, user: seller, products: [product])
    product.update!(default_offer_code_id: offer_code.id)
    offer_code.update_column(:deleted_at, Time.current)

    expect do
      described_class.new(dry_run: false).process
    end.to change { product.reload.default_offer_code_id }.from(offer_code.id).to(nil)
  end

  it "clears the default when a universal code excludes the product" do
    offer_code = create(:universal_offer_code, user: seller)
    product.update!(default_offer_code_id: offer_code.id)
    offer_code.excluded_products << product

    expect do
      described_class.new(dry_run: false).process
    end.to change { product.reload.default_offer_code_id }.from(offer_code.id).to(nil)
  end

  it "clears a default pointing at a codeless upsell discount" do
    upsell = create(:upsell, seller:, product:)
    upsell.build_offer_code(user: seller, products: [product], amount_percentage: 10, amount_cents: nil)
    upsell.save!
    # Legacy rows predate the codeless-discount rejection in
    # Link#default_offer_code_must_be_valid, so write the column directly.
    product.update_column(:default_offer_code_id, upsell.offer_code.id)

    expect do
      described_class.new(dry_run: false).process
    end.to change { product.reload.default_offer_code_id }.to(nil)
  end

  it "clears a default pointing at a missing offer code row" do
    product.update_column(:default_offer_code_id, 123_456_789)

    expect do
      described_class.new(dry_run: false).process
    end.to change { product.reload.default_offer_code_id }.to(nil)
  end

  it "leaves attached defaults alone" do
    offer_code = create(:offer_code, user: seller, products: [product])
    product.update!(default_offer_code_id: offer_code.id)
    universal_offer_code = create(:universal_offer_code, user: seller, code: "uni")
    other_product = create(:product, user: seller)
    other_product.update!(default_offer_code_id: universal_offer_code.id)

    expect(described_class.new(dry_run: false).process).to eq([])
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
    expect(other_product.reload.default_offer_code_id).to eq(universal_offer_code.id)
  end

  it "leaves expired but attached defaults alone" do
    offer_code = create(:offer_code, user: seller, products: [product], valid_at: 2.days.ago, expires_at: 1.day.ago)
    product.update_column(:default_offer_code_id, offer_code.id)

    expect(described_class.new(dry_run: false).process).to eq([])
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
  end

  it "ignores deleted products" do
    offer_code = create(:offer_code, user: seller, products: [product])
    product.update!(default_offer_code_id: offer_code.id)
    offer_code.products.delete(product)
    product.update!(deleted_at: Time.current)

    expect(described_class.new(dry_run: false).process).to eq([])
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
  end

  it "keeps a default that was repointed while the batch was being processed" do
    offer_code = create(:offer_code, user: seller, products: [product])
    replacement_offer_code = create(:offer_code, user: seller, products: [product], code: "replacement")
    product.update!(default_offer_code_id: offer_code.id)
    offer_code.products.delete(product)

    # Simulate a seller assigning a new default between the batch read and the
    # row lock; the locked re-check must leave it in place.
    allow(ReplicaLagWatcher).to receive(:watch) do
      Link.where(id: product.id).update_all(default_offer_code_id: replacement_offer_code.id)
    end

    expect(described_class.new(dry_run: false).process).to eq([])
    expect(product.reload.default_offer_code_id).to eq(replacement_offer_code.id)
  end

  it "clears the default even when the product fails unrelated validations" do
    offer_code = create(:offer_code, user: seller, products: [product])
    product.update!(default_offer_code_id: offer_code.id)
    offer_code.products.delete(product)
    product.update_columns(name: "")

    expect(described_class.new(dry_run: false).process).to eq([{ product_id: product.id, offer_code_id: offer_code.id }])
    expect(product.reload.default_offer_code_id).to be_nil
  end

  it "reports detached defaults without clearing them on a dry run" do
    offer_code = create(:offer_code, user: seller, products: [product])
    product.update!(default_offer_code_id: offer_code.id)
    offer_code.products.delete(product)

    expect(described_class.new.process).to eq([{ product_id: product.id, offer_code_id: offer_code.id }])
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
  end

  it "aborts on a replica lag failure instead of logging it once per row" do
    offer_code = create(:offer_code, user: seller, products: [product])
    product.update!(default_offer_code_id: offer_code.id)
    offer_code.products.delete(product)
    # The console-pod failure mode: SHOW SLAVE STATUS comes back empty. Swallowed
    # per row this reports "cleared 0" and exits successfully, which is
    # indistinguishable from a clean no-op run.
    allow(ReplicaLagWatcher).to receive(:watch).and_raise(NoMethodError.new("undefined method '[]' for nil"))

    expect { described_class.new(dry_run: false).process }.to raise_error(NoMethodError)
    expect(product.reload.default_offer_code_id).to eq(offer_code.id)
  end

  it "logs and continues when a single row fails to write" do
    offer_code = create(:offer_code, user: seller, products: [product])
    product.update!(default_offer_code_id: offer_code.id)
    offer_code.products.delete(product)
    allow_any_instance_of(Link).to receive(:with_lock).and_raise(ActiveRecord::LockWaitTimeout.new("busy"))

    expect(Rails.logger).to receive(:warn).with(/skipped product #{product.id}/)
    expect(described_class.new(dry_run: false).process).to eq([])
  end
end
