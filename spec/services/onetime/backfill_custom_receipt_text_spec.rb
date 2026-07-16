# frozen_string_literal: true

require "spec_helper"

describe Onetime::BackfillCustomReceiptText do
  describe ".process" do
    def product_with_legacy_receipt(text, **attrs)
      create(:product, **attrs).tap do |product|
        product.update_column(:custom_receipt, text)
      end
    end

    it "copies legacy custom_receipt into json_data custom_receipt_text when the new field is blank" do
      product = product_with_legacy_receipt("Carefully worded access instructions.")

      stats = described_class.process(dry_run: false)

      expect(product.reload.custom_receipt_text).to eq("Carefully worded access instructions.")
      expect(stats[:backfilled]).to eq(1)
    end

    it "does not overwrite a custom_receipt_text the seller already set" do
      product = product_with_legacy_receipt("Old legacy text")
      product.update!(custom_receipt_text: "New text saved via the Receipt tab")

      stats = described_class.process(dry_run: false)

      expect(product.reload.custom_receipt_text).to eq("New text saved via the Receipt tab")
      expect(stats[:skipped_already_set]).to eq(1)
      expect(stats[:backfilled]).to be_nil.or eq(0)
    end

    it "re-checks under the row lock and does not overwrite text saved after the row was loaded" do
      product = product_with_legacy_receipt("Old legacy text")
      stale_copy = Link.find(product.id)
      # Simulate a seller saving new receipt text between the batch load and the write.
      Link.find(product.id).update!(custom_receipt_text: "Saved concurrently by the seller")

      service = described_class.new(dry_run: false)
      service.send(:backfill, stale_copy)

      expect(product.reload.custom_receipt_text).to eq("Saved concurrently by the seller")
    end

    it "backfills deleted products so receipt resends still render the text" do
      product = product_with_legacy_receipt("Text on a deleted product", deleted_at: 1.month.ago)

      described_class.process(dry_run: false)

      expect(product.reload.custom_receipt_text).to eq("Text on a deleted product")
    end

    it "skips legacy text longer than the new field's validation limit instead of truncating" do
      too_long = "a" * (Product::Validations::MAX_CUSTOM_RECEIPT_TEXT_LENGTH + 1)
      product = product_with_legacy_receipt(too_long)

      stats = described_class.process(dry_run: false)

      expect(product.reload.custom_receipt_text).to be_nil
      expect(stats[:skipped_too_long]).to eq(1)
    end

    it "backfills text exactly at the validation limit" do
      at_limit = "a" * Product::Validations::MAX_CUSTOM_RECEIPT_TEXT_LENGTH
      product = product_with_legacy_receipt(at_limit)

      stats = described_class.process(dry_run: false)

      expect(product.reload.custom_receipt_text).to eq(at_limit)
      expect(stats[:backfilled]).to eq(1)
    end

    it "skips whitespace-only legacy text" do
      product = product_with_legacy_receipt("   \n  ")

      stats = described_class.process(dry_run: false)

      expect(product.reload.custom_receipt_text).to be_nil
      expect(stats[:backfilled]).to be_nil.or eq(0)
    end

    it "does not write anything in dry-run mode (the default)" do
      product = product_with_legacy_receipt("Dry run text")

      stats = described_class.process

      expect(product.reload.custom_receipt_text).to be_nil
      expect(stats[:would_backfill]).to eq(1)
      expect(stats[:dry_run]).to eq(true)
    end

    it "is idempotent across runs" do
      product = product_with_legacy_receipt("Run twice")

      described_class.process(dry_run: false)
      stats = described_class.process(dry_run: false)

      expect(product.reload.custom_receipt_text).to eq("Run twice")
      expect(stats[:skipped_already_set]).to eq(1)
      expect(stats[:backfilled]).to be_nil.or eq(0)
    end

    it "preserves other json_data attributes when writing" do
      product = product_with_legacy_receipt("Keep my neighbors")
      product.update!(custom_view_content_button_text: "Open course")

      described_class.process(dry_run: false)

      product.reload
      expect(product.custom_receipt_text).to eq("Keep my neighbors")
      expect(product.custom_view_content_button_text).to eq("Open course")
    end

    it "does not run save callbacks or validations on the product" do
      product = product_with_legacy_receipt("No callbacks please")
      expect_any_instance_of(Link).not_to receive(:save)
      expect_any_instance_of(Link).not_to receive(:save!)

      described_class.process(dry_run: false)

      expect(product.reload.custom_receipt_text).to eq("No callbacks please")
    end

    it "continues past a bad row and counts the error" do
      bad = product_with_legacy_receipt("Will raise")
      good = product_with_legacy_receipt("Will succeed")
      allow_any_instance_of(Link).to receive(:custom_receipt_text).and_wrap_original do |m, *args|
        raise "boom" if m.receiver.id == bad.id
        m.call(*args)
      end

      stats = described_class.process(dry_run: false)

      expect(stats[:errors]).to eq(1)
      expect(good.reload.custom_receipt_text).to eq("Will succeed")
    end

    it "counts a row with corrupt non-Hash json_data as an error and continues" do
      bad = product_with_legacy_receipt("Corrupt json_data row")
      bad.update_column(:json_data, [].to_json)
      good = product_with_legacy_receipt("Healthy row")

      stats = described_class.process(dry_run: false)

      expect(stats[:errors]).to eq(1)
      expect(good.reload.custom_receipt_text).to eq("Healthy row")
    end
  end
end
