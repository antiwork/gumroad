# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe Api::V2::ProductSectionsWriter, "against a profile sections writer on another connection" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    create(:seller_profile, seller: @seller)
    @product = create(:product, user: @seller)
    @listed = create(:product, user: @seller)
    @added = create(:product, user: @seller)
    @section = create(:seller_profile_products_section, seller: @seller, product: @product, shown_products: [@listed.id])
    @product.update!(sections: [@section.id])
  end

  after do
    SellerProfileSection.where(seller_id: @seller&.id).delete_all
    SellerProfile.where(seller_id: @seller&.id).delete_all
    product_ids = Link.where(user_id: @seller&.id).ids
    Price.where(link_id: product_ids).delete_all
    Link.where(id: product_ids).delete_all
    Affiliate.where(affiliate_user_id: @seller&.id).delete_all
    @seller&.destroy!
  end

  def lock_waits
    ActiveRecord::Base.uncached do
      ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM information_schema.innodb_trx WHERE trx_state = 'LOCK WAIT'").to_i
    end
  end

  # Returns once the writer's transaction is queued behind the held profile lock.
  def wait_for_lock_wait
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until lock_waits.positive?
      raise "the writer never waited for the profile lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end

  # A product created while the writer waits for the profile lock joins the section (as
  # `Link#add_to_profile_sections` does); changing only the sort must keep it listed.
  it "keeps a product another writer added to the section while it waited for the profile lock" do
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.find(@seller.id).with_profile_sections_lock do
          section = SellerProfileSection.find(@section.id)
          section.update!(shown_products: section.shown_products + [@added.id])
          locked << true
          release.pop
        end
      end
    end
    Timeout.timeout(10) { locked.pop }

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        described_class.new(Link.find(@product.id)).write!(sections: [{ "id" => @section.external_id, "default_product_sort" => "newest" }])
      end
    end
    wait_for_lock_wait
    release << true
    holder.join(20)
    result = Timeout.timeout(20) { writer.value }

    expect(result).to be_success
    @section.reload
    expect(@section.default_product_sort).to eq("newest")
    expect(@section.shown_products).to eq([@listed.id, @added.id])
  ensure
    release&.close
    holder&.join(20)
    writer&.join(20)
  end
end
