# frozen_string_literal: true

require "spec_helper"
require "timeout"

# The shape the Sentry group reported: the duplicate's `after_create` section write waited out the
# server's lock timeout on the seller's profile row, inside ProductDuplicatorService's transaction.
describe ProductDuplicatorService, "with the seller_profiles row held by another connection" do
  # The holder thread has to see committed rows, so this group cannot run inside the fixture
  # transaction. Cleanup is explicit for the same reason.
  self.use_transactional_tests = false

  let(:seller) { create(:user) }
  let!(:profile) { seller.seller_profile.tap(&:save!) }
  let(:product) { create(:product, user: seller, name: "test product", price_cents: 500) }

  after do
    Price.where(link_id: Link.where(user_id: seller&.id).select(:id)).delete_all
    SellerProfileSection.where(seller_id: seller&.id).delete_all
    Link.where(user_id: seller&.id).delete_all
    SellerProfile.where(seller_id: seller&.id).delete_all
    User.where(id: seller&.id).delete_all
  end

  it "completes the duplication instead of rolling the whole of it back" do
    create(:seller_profile_products_section, seller:, add_new_products: true)
    product

    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          SellerProfile.where(seller_id: seller.id).lock.pluck(:id)
          locked << true
          release.pop
        end
      end
    end

    begin
      Timeout.timeout(15) { locked.pop }

      duplicate = ProductDuplicatorService.new(product.id).duplicate

      expect(duplicate).to be_persisted
      # Not a bare "did not raise": the writes the rollback used to discard are what the seller
      # loses, so assert they are there on the duplicate.
      expect(duplicate.name).to eq("test product (copy)")
      expect(duplicate.prices.alive).to be_present
      expect(duplicate.prices.alive.map(&:price_cents)).to eq(product.prices.alive.map(&:price_cents))
    ensure
      release << true if release
      if holder && !holder.join(10)
        holder.kill
        holder.join
      end
    end
  end
end
