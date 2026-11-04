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

  # Waits for this writer's own connection to queue behind the section lock: the seller_profiles row
  # when the seller has a saved profile, the seller's own row when they do not (the row the writer
  # takes before the product row, since a seller with no profile row has no section row to
  # serialize on). An unrelated lock wait cannot release the holder early.
  def wait_until_waiting_on(connection_id, table)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until waiting_on?(connection_id, table)
      raise "the writer never waited for the #{table} lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.15
    end
  end

  def waiting_on?(connection_id, table)
    ActiveRecord::Base.connection.uncached do
      ActiveRecord::Base.connection.select_value(<<~SQL.squish).to_i.positive?
        SELECT COUNT(*) FROM sys.innodb_lock_waits
        WHERE waiting_pid = #{connection_id.to_i}
          AND locked_table = CONCAT('`', DATABASE(), '`.`#{table}`')
      SQL
    end
  end

  # Runs `holder_work` under a lock on one connection, starts `write!` on another, and releases the
  # lock only once the writer is queued behind it. Returns the writer's result. `holder_lock`
  # defaults to the sections lock the editor and the writer share; a caller that needs the seller's
  # own row instead (the lock the writer takes when the seller has no profile row) passes it.
  def write_while_section_lock_is_held(sections, table:, holder_lock: nil, &holder_work)
    locked = Queue.new
    release = Queue.new
    hold = holder_lock || ->(&block) { User.find(@seller.id).with_profile_sections_lock(&block) }
    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        hold.call do
          holder_work.call
          locked << true
          release.pop
        end
      end
    end
    Timeout.timeout(10) { locked.pop }

    writer_connection_id = Queue.new
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        writer_connection_id << connection.select_value("SELECT CONNECTION_ID()")
        described_class.new(Link.find(@product.id)).write!(sections:)
      end
    end
    wait_until_waiting_on(Timeout.timeout(10) { writer_connection_id.pop }, table)
    release << true
    holder.join(20)
    Timeout.timeout(20) { writer.value }
  ensure
    release&.close
    holder&.join(20)
    writer&.join(20)
  end

  # A product created while the writer waits for the profile lock joins the section (as
  # `Link#add_to_profile_sections` does); changing only the sort must keep it listed.
  it "keeps a product another writer added to the section while it waited for the profile lock" do
    result = write_while_section_lock_is_held([{ "id" => @section.external_id, "default_product_sort" => "newest" }], table: "seller_profiles") do
      section = SellerProfileSection.find(@section.id)
      section.update!(shown_products: section.shown_products + [@added.id])
    end

    expect(result).to be_success
    @section.reload
    expect(@section.default_product_sort).to eq("newest")
    expect(@section.shown_products).to eq([@listed.id, @added.id])
  end

  # Same write, but the seller has never saved a profile: there is no seller_profiles row to
  # serialize on, so the writer's own seller-row lock is what keeps this write from dropping the
  # other one. `with_profile_sections_lock` deliberately takes no lock here (main's design: with no
  # profile row there is nothing for it to serialize against, and `Link#add_to_profile_sections`
  # runs before a save's own bounded product lock, so any lock it took would take the bound's place
  # — see spec/controllers/links_controller_gp2583_lock_fail_fast_spec.rb).
  it "keeps a product another writer added while the seller has no saved profile" do
    SellerProfile.where(seller_id: @seller.id).delete_all

    result = write_while_section_lock_is_held(
      [{ "id" => @section.external_id, "default_product_sort" => "newest" }],
      table: "users",
      holder_lock: ->(&block) do
        User.transaction do
          User.where(id: @seller.id).lock.pick(:id)
          block.call
        end
      end
    ) do
      section = SellerProfileSection.find(@section.id)
      section.update!(shown_products: section.shown_products + [@added.id])
    end

    expect(result).to be_success
    @section.reload
    expect(@section.default_product_sort).to eq("newest")
    expect(@section.shown_products).to eq([@listed.id, @added.id])
  end

  it "refuses, and creates nothing, when a section it changes was deleted while it waited" do
    result = write_while_section_lock_is_held([{ "type" => "products", "shown_products" => [@listed.external_id] }, { "id" => @section.external_id, "default_product_sort" => "newest" }], table: "seller_profiles") do
      SellerProfileSection.find(@section.id).destroy!
    end

    expect(result).not_to be_success
    expect(result.error).to eq(described_class::OWNERSHIP_MESSAGE)
    expect(SellerProfileSection.where(seller_id: @seller.id)).to be_empty
    expect(@product.reload.sections).to eq([@section.id])
  end
end
