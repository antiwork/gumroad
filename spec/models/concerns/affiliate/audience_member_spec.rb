# frozen_string_literal: true

require "spec_helper"

describe Affiliate::AudienceMember do
  let(:seller) { create(:user) }
  let(:affiliate_user) { create(:affiliate_user) }
  let(:product) { create(:product, user: seller) }
  let(:direct_affiliate) { create(:direct_affiliate, affiliate_user:, seller:, products: [product]) }

  describe "a concurrent insert race on the same (seller, email) pair" do
    it "retries once and updates the winner's row instead of raising" do
      # See Purchase::AudienceMember#add_to_audience_member_details for the race shape. The
      # winner row is inserted via `insert_all` so it doesn't also trip the `save!` stub below.
      save_count = 0
      allow_any_instance_of(AudienceMember).to receive(:save!).and_wrap_original do |original|
        save_count += 1
        if save_count == 1
          AudienceMember.insert_all([{ seller_id: seller.id, email: affiliate_user.email,
                                       details: { "follower" => { "id" => 1, "created_at" => Time.current.iso8601 } },
                                       created_at: Time.current, updated_at: Time.current }])
          raise ActiveRecord::RecordNotUnique, "boom"
        end
        original.call
      end

      expect { direct_affiliate.update_audience_member_with_added_product(product.id) }.not_to raise_error

      member = AudienceMember.find_by(seller_id: seller.id, email: affiliate_user.email)
      expect(member).to be_present
      expect(member.details["affiliates"]).to include(a_hash_including("id" => direct_affiliate.id, "product_id" => product.id))
      expect(save_count).to eq(2)
    end

    it "raises if the race persists past the single retry" do
      allow_any_instance_of(AudienceMember).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique, "boom")

      expect do
        direct_affiliate.update_audience_member_with_added_product(product.id)
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "does not duplicate an existing affiliate detail on retry (private callback path)" do
      product_affiliate = direct_affiliate.product_affiliates.first
      direct_affiliate.update_column(:deleted_at, Time.current)

      save_count = 0
      allow_any_instance_of(AudienceMember).to receive(:save!).and_wrap_original do |original|
        save_count += 1
        if save_count == 1
          AudienceMember.insert_all([{ seller_id: seller.id, email: affiliate_user.email,
                                       details: { "affiliates" => [{ "id" => direct_affiliate.id, "product_id" => product_affiliate.link_id, "created_at" => Time.current.iso8601 }] },
                                       created_at: Time.current, updated_at: Time.current }])
          raise ActiveRecord::RecordNotUnique, "boom"
        end
        original.call
      end

      expect { direct_affiliate.update!(deleted_at: nil) }.not_to raise_error

      member = AudienceMember.find_by(seller_id: seller.id, email: affiliate_user.email)
      matches = member.details["affiliates"].select { _1["id"] == direct_affiliate.id && _1["product_id"] == product_affiliate.link_id }
      expect(matches.length).to eq(1)
      expect(save_count).to eq(2)
    end
  end

  describe "a LockWaitTimeout on an existing audience_members row" do
    it "does not raise from update_audience_member_with_added_product" do
      allow_any_instance_of(AudienceMember).to receive(:save!).and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::LockWaitTimeout))

      expect { direct_affiliate.update_audience_member_with_added_product(product.id) }.not_to raise_error
    end
  end
end
