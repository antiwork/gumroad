# frozen_string_literal: true

require "spec_helper"

describe Onetime::DeduplicateProductAffiliates do
  # The races that created these duplicates bypassed the model callbacks, and
  # serialize_assignment now blocks even validate: false saves — so insert raw.
  def create_duplicate_of(product_affiliate, **overrides)
    duplicate = build(:product_affiliate,
                      affiliate: product_affiliate.affiliate,
                      product: product_affiliate.product,
                      affiliate_basis_points: product_affiliate.affiliate_basis_points,
                      destination_url: product_affiliate.destination_url,
                      flags: product_affiliate.flags,
                      **overrides)
    now = Time.current
    ProductAffiliate.insert_all!([duplicate.attributes.except("id").merge("created_at" => now, "updated_at" => now)])
    ProductAffiliate.where(affiliate_id: duplicate.affiliate_id, link_id: duplicate.link_id).order(:id).last
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

    it "sticks a live run to the primary so discovery cannot read a lagging replica" do
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original
      described_class.process(dry_run: false)
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

  describe ".process_url_divergent" do
    let!(:url_pair_resolved) do
      create(:product_affiliate, affiliate_basis_points: 1000, destination_url: "https://example.com/current")
    end
    let!(:url_pair_surplus) { create_duplicate_of(url_pair_resolved, destination_url: "https://example.com/unreachable") }

    it "does not delete anything on a dry run" do
      expect do
        described_class.process_url_divergent
      end.not_to change { ProductAffiliate.count }
    end

    it "skips row locks on a dry run so it works against a read-only replica" do
      expect(locking_queries_during { described_class.process_url_divergent }).to be_empty
    end

    it "locks the pair's rows so the content re-check and the delete are atomic" do
      expect(locking_queries_during { described_class.process_url_divergent(dry_run: false) }).not_to be_empty
    end

    it "keeps the row the application lookup returns for a destination_url-only pair" do
      resolved_id = ProductAffiliate.where(affiliate_id: url_pair_resolved.affiliate_id,
                                           link_id: url_pair_resolved.link_id).take.id

      expect do
        described_class.process_url_divergent(dry_run: false)
      end.to change { ProductAffiliate.count }.by(-1)

      remaining_ids = ProductAffiliate.where(affiliate_id: url_pair_resolved.affiliate_id,
                                             link_id: url_pair_resolved.link_id).pluck(:id)
      expect(remaining_ids).to eq([resolved_id])
    end

    it "does not change the destination url the app serves, whatever the row timestamps say" do
      pair_row = create(:product_affiliate, destination_url: "https://example.com/one")
                   .tap { _1.update_columns(updated_at: 3.days.ago) }
      create_duplicate_of(pair_row, destination_url: "https://example.com/two")
      affiliate = pair_row.affiliate
      url_before = affiliate.final_destination_url(product: pair_row.product)

      described_class.process_url_divergent(dry_run: false)

      expect(affiliate.reload.final_destination_url(product: pair_row.product)).to eq(url_before)
    end

    it "sticks a live run to the primary so discovery cannot read a lagging replica" do
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original
      described_class.process_url_divergent(dry_run: false)
    end

    it "restores the single-product redirect for an affiliate whose only product was duplicated" do
      pair_row = create(:product_affiliate, destination_url: "https://example.com/one")
      create_duplicate_of(pair_row, destination_url: "https://example.com/two")
      affiliate = pair_row.affiliate

      expect do
        described_class.process_url_divergent(dry_run: false)
      end.to change { affiliate.reload.product_affiliates.count }.from(2).to(1)

      kept_row = affiliate.product_affiliates.sole
      expect(affiliate.final_destination_url).to eq(kept_row.destination_url)
    end

    it "handles a pair whose rows carry nil updated_at" do
      pair_row = create(:product_affiliate, destination_url: "https://example.com/one")
                   .tap { _1.update_columns(updated_at: nil) }
      create_duplicate_of(pair_row, destination_url: "https://example.com/two")

      expect do
        described_class.process_url_divergent(dry_run: false)
      end.to change { ProductAffiliate.where(affiliate_id: pair_row.affiliate_id, link_id: pair_row.link_id).count }.to(1)
    end

    it "leaves pairs with commission divergence untouched" do
      described_class.process_url_divergent(dry_run: false)

      expect(ProductAffiliate.exists?(divergent_pair_row_one.id)).to be(true)
      expect(ProductAffiliate.exists?(divergent_pair_row_two.id)).to be(true)
    end

    it "leaves a pair that mixes url and basis_points divergence untouched" do
      mixed_row_one = create(:product_affiliate, affiliate_basis_points: 1000, destination_url: "https://example.com/one")
      mixed_row_two = create_duplicate_of(mixed_row_one, affiliate_basis_points: 2500, destination_url: "https://example.com/two")

      described_class.process_url_divergent(dry_run: false)

      expect(ProductAffiliate.exists?(mixed_row_one.id)).to be(true)
      expect(ProductAffiliate.exists?(mixed_row_two.id)).to be(true)
    end

    it "leaves identical pairs for the first pass" do
      expect do
        described_class.process_url_divergent(dry_run: false)
      end.not_to change { ProductAffiliate.exists?(identical_pair_surplus.id) }
    end
  end

  describe ".process_commission_divergent" do
    it "does not delete anything on a dry run" do
      expect do
        described_class.process_commission_divergent
      end.not_to change { ProductAffiliate.count }
    end

    it "skips row locks on a dry run so it works against a read-only replica" do
      expect(locking_queries_during { described_class.process_commission_divergent }).to be_empty
    end

    it "locks the pair's rows so the content re-check and the delete are atomic" do
      expect(locking_queries_during { described_class.process_commission_divergent(dry_run: false) }).not_to be_empty
    end

    it "sticks a live run to the primary so discovery cannot read a lagging replica" do
      expect(ActiveRecord::Base.connection).to receive(:stick_to_primary!).at_least(:once).and_call_original
      described_class.process_commission_divergent(dry_run: false)
    end

    it "keeps the row the application lookup returns for a basis-points-divergent pair" do
      resolved_id = ProductAffiliate.where(affiliate_id: divergent_pair_row_one.affiliate_id,
                                           link_id: divergent_pair_row_one.link_id).take.id

      expect do
        described_class.process_commission_divergent(dry_run: false)
      end.to change { ProductAffiliate.count }.by(-1)

      remaining_ids = ProductAffiliate.where(affiliate_id: divergent_pair_row_one.affiliate_id,
                                             link_id: divergent_pair_row_one.link_id).pluck(:id)
      expect(remaining_ids).to eq([resolved_id])
    end

    it "serves the same basis points the app resolved before the collapse" do
      pair = create(:product_affiliate, affiliate_basis_points: 1000).tap { _1.update_columns(updated_at: 3.days.ago) }
      create_duplicate_of(pair, affiliate_basis_points: 4000)
      affiliate = pair.affiliate

      basis_before = affiliate.product_affiliates.find_by(link_id: pair.link_id).affiliate_basis_points

      described_class.process_commission_divergent(dry_run: false)

      expect(affiliate.product_affiliates.find_by(link_id: pair.link_id).affiliate_basis_points).to eq(basis_before)
    end

    it "deletes every surplus row in a pair with more than two commission-divergent rows" do
      create_duplicate_of(divergent_pair_row_one, affiliate_basis_points: 3000)
      create_duplicate_of(divergent_pair_row_one, affiliate_basis_points: 5000)

      described_class.process_commission_divergent(dry_run: false)

      remaining = ProductAffiliate.where(affiliate_id: divergent_pair_row_one.affiliate_id,
                                         link_id: divergent_pair_row_one.link_id).pluck(:id)
      expect(remaining.size).to eq(1)
    end

    it "collapses a pair that diverges only on flags" do
      flags_pair_row_one = create(:product_affiliate, affiliate_basis_points: 1000)
      flags_pair_row_two = create_duplicate_of(flags_pair_row_one, dont_show_as_co_creator: true)

      described_class.process_commission_divergent(dry_run: false)

      remaining = ProductAffiliate.where(affiliate_id: flags_pair_row_one.affiliate_id,
                                         link_id: flags_pair_row_one.link_id).pluck(:id)
      expect(remaining.size).to eq(1)
      expect(remaining).not_to include(flags_pair_row_two.id)
    end

    it "leaves identical pairs for the first pass" do
      expect do
        described_class.process_commission_divergent(dry_run: false)
      end.not_to change { ProductAffiliate.exists?(identical_pair_surplus.id) }
    end

    it "resolves a pair that mixes url and commission divergence to the row the app serves" do
      mixed_row_one = create(:product_affiliate, affiliate_basis_points: 1000, destination_url: "https://example.com/one")
      create_duplicate_of(mixed_row_one, affiliate_basis_points: 2500, destination_url: "https://example.com/two")
      resolved_id = ProductAffiliate.where(affiliate_id: mixed_row_one.affiliate_id,
                                           link_id: mixed_row_one.link_id).take.id

      described_class.process_commission_divergent(dry_run: false)

      remaining_ids = ProductAffiliate.where(affiliate_id: mixed_row_one.affiliate_id,
                                             link_id: mixed_row_one.link_id).pluck(:id)
      expect(remaining_ids).to eq([resolved_id])
    end

    it "leaves a destination_url-only pair for the second pass" do
      url_pair = create(:product_affiliate, destination_url: "https://example.com/one")
      create_duplicate_of(url_pair, destination_url: "https://example.com/two")

      expect do
        described_class.process_commission_divergent(dry_run: false)
      end.not_to change { ProductAffiliate.where(affiliate_id: url_pair.affiliate_id, link_id: url_pair.link_id).count }
    end
  end
end
