# frozen_string_literal: true

require "spec_helper"

describe "primary pin boundaries" do
  def writing_block?
    ApplicationRecord.connected_to_stack.any? { |entry| entry[:role] == :writing && entry[:klasses].include?(ApplicationRecord) }
  end

  [[:handle_new_bank_account, :update_bank_account], [:handle_new_user_compliance_info, :update_account]].each do |callback, update|
    it "keeps #{callback} pinned through dependent account updates" do
      user = double("user", has_stripe_account_connected?: false, stripe_account: double("account"))
      record = double("new record", user:)
      expect(StripeMerchantAccountManager).to receive(update) do
        expect(writing_block?).to eq(true)
      end

      StripeMerchantAccountManager.public_send(callback, record)
    end
  end

  # LinksController wires #show's pin as an around_action declared BELOW the product and seller
  # lookups, so those keep reading the replica and only the action body is pinned — the boundary
  # the old in-action `stick_to_primary!` drew. Declaration order is the whole contract here:
  # moving the line up silently puts the entire product page on the primary.
  it "declares the product page's primary pin after #show's product lookups" do
    filters = LinksController._process_action_callbacks.map(&:filter)

    expect(filters).to include(:use_primary_database, :prepare_product_page)
    expect(filters.index(:use_primary_database)).to be > filters.index(:prepare_product_page)
  end

  [true, false].each do |dry_run|
    it "#{dry_run ? "releases" : "pins"} merchant cleanup discovery" do
      service = Onetime::CleanupWedgedStripeMerchantAccounts.new
      expect(service).to receive(:candidates) do
        expect(writing_block?).to eq(!dry_run)
        MerchantAccount.none
      end
      service.process(dry_run:)
    end

    [:process, :process_url_divergent, :process_commission_divergent].each do |method|
      it "#{dry_run ? "releases" : "pins"} affiliate #{method} discovery" do
        service = Onetime::DeduplicateProductAffiliates.new
        allow(service).to receive(:duplicate_pairs) do
          expect(writing_block?).to eq(!dry_run)
          []
        end
        allow(service).to receive(:report_remaining_duplicates)
        service.public_send(method, dry_run:)
      end
    end
  end
end
