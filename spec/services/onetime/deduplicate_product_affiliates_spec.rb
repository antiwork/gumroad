# frozen_string_literal: true

require "spec_helper"

describe Onetime::DeduplicateProductAffiliates do
  # The races that created these duplicates bypassed the model validation, so the
  # spec does the same: build the duplicate and save it without validation.
  def create_duplicate_of(product_affiliate, **overrides)
    build(:product_affiliate,
          affiliate: product_affiliate.affiliate,
          product: product_affiliate.product,
          affiliate_basis_points: product_affiliate.affiliate_basis_points,
          destination_url: product_affiliate.destination_url,
          flags: product_affiliate.flags,
          **overrides).tap { _1.save!(validate: false) }
  end

  def locking_queries_during(&block)
    locking_queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      locking_queries << payload[:sql] if payload[:sql].include?("FOR UPDATE")
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    locking_queries
  end

  let!(:identical_pair_keeper) do
    create(:product_affiliate, affiliate_basis_points: 1000, destination_url: "https://example.com/landing")
  end
  let!(:identical_pair_surplus) { create_duplicate_of(identical_pair_keeper) }

  let!(:divergent_pair_row_one) { create(:product_affiliate, affiliate_basis_points: 1000) }
  let!(:divergent_pair_row_two) { create_duplicate_of(divergent_pair_row_one, affiliate_basis_points: 2500) }

  let!(:unique_row) { create(:product_affiliate) }

  describe ".process" do
    it "does not delete anything on a dry run" do
      expect do
        described_class.process
      end.not_to change { ProductAffiliate.count }
    end

    it "skips ReplicaLagWatcher on a dry run so it works against a replica connection" do
      expect(ReplicaLagWatcher).not_to receive(:watch)
      described_class.process
    end

    it "skips row locks on a dry run so it works against a read-only replica" do
      expect(locking_queries_during { described_class.process }).to be_empty
    end

    it "locks the pair's rows so the content re-check and the delete are atomic" do
      expect(locking_queries_during { described_class.process(dry_run: false) }).not_to be_empty
    end

    it "deletes the surplus row of an identical pair and keeps the lowest id" do
      expect do
        described_class.process(dry_run: false)
      end.to change { ProductAffiliate.count }.by(-1)

      expect(ProductAffiliate.exists?(identical_pair_keeper.id)).to be(true)
      expect(ProductAffiliate.exists?(identical_pair_surplus.id)).to be(false)
    end

    it "deletes every surplus row when a pair has more than two identical rows" do
      create_duplicate_of(identical_pair_keeper)
      create_duplicate_of(identical_pair_keeper)

      described_class.process(dry_run: false)

      remaining_ids = ProductAffiliate.where(affiliate_id: identical_pair_keeper.affiliate_id,
                                             link_id: identical_pair_keeper.link_id).pluck(:id)
      expect(remaining_ids).to eq([identical_pair_keeper.id])
    end

    it "leaves pairs that diverge on affiliate_basis_points untouched" do
      described_class.process(dry_run: false)

      expect(ProductAffiliate.exists?(divergent_pair_row_one.id)).to be(true)
      expect(ProductAffiliate.exists?(divergent_pair_row_two.id)).to be(true)
    end

    it "leaves pairs that diverge only on flags untouched" do
      flags_pair_row_one = create(:product_affiliate, affiliate_basis_points: 1000)
      flags_pair_row_two = create_duplicate_of(flags_pair_row_one, dont_show_as_co_creator: true)

      described_class.process(dry_run: false)

      expect(ProductAffiliate.exists?(flags_pair_row_one.id)).to be(true)
      expect(ProductAffiliate.exists?(flags_pair_row_two.id)).to be(true)
    end

    it "leaves pairs that diverge only on destination_url untouched" do
      url_pair_row_one = create(:product_affiliate, destination_url: "https://example.com/one")
      url_pair_row_two = create_duplicate_of(url_pair_row_one, destination_url: "https://example.com/two")

      described_class.process(dry_run: false)

      expect(ProductAffiliate.exists?(url_pair_row_one.id)).to be(true)
      expect(ProductAffiliate.exists?(url_pair_row_two.id)).to be(true)
    end

    it "reports the remaining duplicate pairs from a fresh rescan after a live run" do
      expect do
        described_class.process(dry_run: false)
      end.to output(/Remaining duplicate pair\(s\) after this run: 1/).to_stdout
    end

    it "leaves non-duplicated rows untouched" do
      described_class.process(dry_run: false)

      expect(ProductAffiliate.exists?(unique_row.id)).to be(true)
    end
  end

  describe "#divergent_pairs" do
    it "lists only the pairs whose rows differ on content" do
      expect(described_class.new.divergent_pairs)
        .to contain_exactly([divergent_pair_row_one.affiliate_id, divergent_pair_row_one.link_id])
    end
  end
end
