# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe ProductAffiliate, "assignment concurrency" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user, username: "pas#{SecureRandom.hex(8)}")
    @affiliate_user = create(:affiliate_user, username: "paa#{SecureRandom.hex(8)}")
    @affiliate = create(:direct_affiliate, seller: @seller, affiliate_user: @affiliate_user)
    @product = create(:product, user: @seller)
  end

  after do
    user_ids = [@seller&.id, @affiliate_user&.id].compact
    product_id = @product&.id

    ProductAffiliate.where(affiliate_id: @affiliate&.id, link_id: product_id).delete_all
    AudienceMember.where(seller_id: @seller&.id, email: @affiliate_user&.email).delete_all
    Price.where(link_id: product_id).delete_all
    Link.where(id: product_id).delete_all
    Affiliate.where(affiliate_user_id: user_ids).or(Affiliate.where(id: @affiliate&.id)).delete_all
    RefundPolicy.where(seller_id: user_ids).delete_all
    UserComplianceInfo.where(user_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
  end

  it "creates one assignment when two inserts run concurrently" do
    first_lock = Queue.new
    release_first = Queue.new
    start_second = Queue.new
    results = Queue.new
    errors = Queue.new

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:product_affiliate_first_writer]
      next unless payload[:sql].include?("FROM `affiliates`") && payload[:sql].include?("FOR UPDATE")

      Thread.current[:product_affiliate_first_writer] = false
      first_lock << true
      release_first.pop
    end

    first_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:product_affiliate_first_writer] = true
        results << ProductAffiliate.create!(affiliate_id: @affiliate.id, link_id: @product.id)
      rescue StandardError => error
        errors << error
      ensure
        Thread.current[:product_affiliate_first_writer] = false
      end
    end

    Timeout.timeout(10) { first_lock.pop }
    second_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        start_second << true
        results << ProductAffiliate.create!(affiliate_id: @affiliate.id, link_id: @product.id)
      rescue StandardError => error
        errors << error
      end
    end
    Timeout.timeout(10) { start_second.pop }
    sleep 0.1

    expect(second_writer).to be_alive
    expect(results).to be_empty

    release_first << true
    [first_writer, second_writer].each { expect(_1.join(10)).to be_present }

    expect(ProductAffiliate.where(affiliate_id: @affiliate.id, link_id: @product.id).count).to eq(1)
    expect(results.size).to eq(1)
    expect(errors.size).to eq(1)
    expect(errors.pop).to be_a(ActiveRecord::RecordInvalid)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_first << true if defined?(release_first) && release_first
    [first_writer, second_writer].compact.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end
end
