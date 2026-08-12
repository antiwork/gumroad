# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe ProductAffiliate, "assignment concurrency" do
  self.use_transactional_tests = false

  def wait_for_row_lock(process_id:, table:)
    Timeout.timeout(10) do
      loop do
        lock_wait_count = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
          SELECT COUNT(*)
          FROM performance_schema.data_lock_waits AS lock_waits
          INNER JOIN performance_schema.data_locks AS requested_lock
            ON requested_lock.ENGINE_LOCK_ID = lock_waits.REQUESTING_ENGINE_LOCK_ID
          INNER JOIN performance_schema.threads AS requesting_thread
            ON requesting_thread.THREAD_ID = lock_waits.REQUESTING_THREAD_ID
          WHERE requesting_thread.PROCESSLIST_ID = #{process_id.to_i}
            AND requested_lock.OBJECT_SCHEMA = DATABASE()
            AND requested_lock.OBJECT_NAME = #{ActiveRecord::Base.connection.quote(table)}
        SQL
        break if lock_wait_count.to_i.positive?

        sleep 0.01
      end
    end
  end

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

  it "publishes once when two requests assign the same apply-to-all affiliate" do
    @affiliate.update!(apply_to_all_products: true)
    @product.update!(draft: true)
    first_lock = Queue.new
    release_first = Queue.new
    second_connection_id = Queue.new
    results = Queue.new
    errors = Queue.new
    first_publisher = nil
    second_publisher = nil

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:link_first_publisher]
      next unless payload[:sql].include?("FROM `links`") && payload[:sql].include?("FOR UPDATE")

      Thread.current[:link_first_publisher] = false
      first_lock << true
      release_first.pop
    end

    expect do
      first_publisher = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:link_first_publisher] = true
          results << Link.find(@product.id).publish!
        rescue StandardError => error
          errors << error
        ensure
          Thread.current[:link_first_publisher] = false
        end
      end
      Timeout.timeout(10) { first_lock.pop }

      second_publisher = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          connection = ActiveRecord::Base.connection
          second_connection_id << connection.select_value("SELECT CONNECTION_ID()")
          results << Link.find(@product.id).publish!
        rescue StandardError => error
          errors << error
        end
      end
      process_id = Timeout.timeout(10) { second_connection_id.pop }
      wait_for_row_lock(process_id:, table: "links")

      expect(second_publisher).to be_alive
      expect(results).to be_empty

      release_first << true
      [first_publisher, second_publisher].each { expect(_1.join(10)).to be_present }
    end.to have_enqueued_mail(AffiliateMailer, :notify_direct_affiliate_of_new_product).with(@affiliate.id, @product.id).once

    expect(errors).to be_empty
    expect(@product.reload).to be_published
    expect(ProductAffiliate.where(affiliate_id: @affiliate.id, link_id: @product.id).count).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_first << true if defined?(release_first) && release_first
    [first_publisher, second_publisher].compact.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end

  it "serializes publication before a collaborator update" do
    @affiliate.update!(apply_to_all_products: true)
    @product.update!(draft: true)
    collaborator_user = create(:affiliate_user, username: "pac#{SecureRandom.hex(8)}")
    collaborator = create(:collaborator, seller: @seller, affiliate_user: collaborator_user, affiliate_basis_points: 40_00)
    first_lock = Queue.new
    release_first = Queue.new
    updater_connection_id = Queue.new
    results = Queue.new
    errors = Queue.new
    publisher = nil
    updater = nil

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:link_first_publisher]
      next unless payload[:sql].include?("FROM `links`") && payload[:sql].include?("FOR UPDATE")

      Thread.current[:link_first_publisher] = false
      first_lock << true
      release_first.pop
    end

    publisher = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:link_first_publisher] = true
        Link.find(@product.id).publish!
        results << :published
      rescue StandardError => error
        errors << error
      ensure
        Thread.current[:link_first_publisher] = false
      end
    end
    Timeout.timeout(10) { first_lock.pop }

    updater = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        updater_connection_id << ActiveRecord::Base.connection.select_value("SELECT CONNECTION_ID()")
        results << Collaborator::UpdateService.new(
          seller: User.find(@seller.id),
          collaborator_id: collaborator.external_id,
          params: {
            apply_to_all_products: false,
            percent_commission: nil,
            dont_show_as_co_creator: false,
            products: [{ id: @product.external_id, percent_commission: 40, dont_show_as_co_creator: false }]
          }
        ).process
      rescue StandardError => error
        errors << error
      end
    end
    process_id = Timeout.timeout(10) { updater_connection_id.pop }
    wait_for_row_lock(process_id:, table: "links")

    expect(updater).to be_alive
    expect(results).to be_empty

    release_first << true
    [publisher, updater].each { expect(_1.join(10)).to be_present }

    expect(errors).to be_empty
    expect(2.times.map { results.pop }).to contain_exactly(:published, { success: true })
    expect(@product.reload).to be_published.and be_is_collab
    expect(@product).to be_transcode_videos_on_purchase
    expect(ProductAffiliate.where(affiliate: collaborator, product: @product).count).to eq(1)
    expect(ProductAffiliate.where(affiliate: @affiliate, product: @product)).to be_empty
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_first << true if defined?(release_first) && release_first
    [publisher, updater].compact.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
    ProductAffiliate.where(affiliate_id: collaborator&.id).delete_all
    AudienceMember.where(seller_id: @seller&.id, email: collaborator_user&.email).delete_all
    Affiliate.where(id: collaborator&.id).delete_all
    UserComplianceInfo.where(user_id: collaborator_user&.id).delete_all
    User.where(id: collaborator_user&.id).delete_all
  end

  it "serializes a direct affiliate edit after a collaborator locks the product" do
    assignment = ProductAffiliate.create!(affiliate: @affiliate, product: @product, affiliate_basis_points: 10_00)
    collaborator_user = create(:affiliate_user, username: "pad#{SecureRandom.hex(8)}")
    collaborator = create(:collaborator, seller: @seller, affiliate_user: collaborator_user, affiliate_basis_points: 40_00)
    collaborator_lock = Queue.new
    release_collaborator = Queue.new
    editor_connection_id = Queue.new
    results = Queue.new
    errors = Queue.new
    collaborator_writer = nil
    direct_affiliate_editor = nil

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:product_affiliate_collaborator_writer]
      next unless payload[:sql].include?("FROM `links`") && payload[:sql].include?("FOR UPDATE")

      Thread.current[:product_affiliate_collaborator_writer] = false
      collaborator_lock << true
      release_collaborator.pop
    end

    collaborator_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:product_affiliate_collaborator_writer] = true
        results << Collaborator::UpdateService.new(
          seller: User.find(@seller.id),
          collaborator_id: collaborator.external_id,
          params: {
            apply_to_all_products: false,
            percent_commission: nil,
            dont_show_as_co_creator: false,
            products: [{ id: @product.external_id, percent_commission: 40, dont_show_as_co_creator: false }]
          }
        ).process
      rescue StandardError => error
        errors << error
      ensure
        Thread.current[:product_affiliate_collaborator_writer] = false
      end
    end
    Timeout.timeout(10) { collaborator_lock.pop }

    direct_affiliate_editor = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        editor_connection_id << ActiveRecord::Base.connection.select_value("SELECT CONNECTION_ID()")
        affiliate = DirectAffiliate.find(@affiliate.id)
        affiliate.product_affiliates.to_a.sole.assign_attributes(affiliate_basis_points: 20_00)
        results << affiliate.save
      rescue StandardError => error
        errors << error
      end
    end
    process_id = Timeout.timeout(10) { editor_connection_id.pop }
    wait_for_row_lock(process_id:, table: "links")

    expect(direct_affiliate_editor).to be_alive
    expect(results).to be_empty

    release_collaborator << true
    [collaborator_writer, direct_affiliate_editor].each { expect(_1.join(10)).to be_present }

    expect(errors).to be_empty
    expect(2.times.map { results.pop }).to contain_exactly({ success: true }, false)
    expect(@product.reload).to be_is_collab
    expect(ProductAffiliate.where(affiliate: collaborator, product: @product).count).to eq(1)
    expect(ProductAffiliate.where(affiliate: @affiliate, product: @product)).to be_empty
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_collaborator << true if defined?(release_collaborator) && release_collaborator
    [collaborator_writer, direct_affiliate_editor].compact.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
    ProductAffiliate.where(id: assignment&.id).delete_all
    ProductAffiliate.where(affiliate_id: collaborator&.id).delete_all
    AudienceMember.where(seller_id: @seller&.id, email: collaborator_user&.email).delete_all
    Affiliate.where(id: collaborator&.id).delete_all
    UserComplianceInfo.where(user_id: collaborator_user&.id).delete_all
    User.where(id: collaborator_user&.id).delete_all
  end

  it "revalidates a direct assignment after a collaborator locks the product" do
    collaborator_user = create(:affiliate_user, username: "pae#{SecureRandom.hex(8)}")
    collaborator = create(:collaborator, seller: @seller, affiliate_user: collaborator_user, affiliate_basis_points: 40_00)
    collaborator_lock = Queue.new
    release_collaborator = Queue.new
    direct_writer_connection_id = Queue.new
    results = Queue.new
    errors = Queue.new
    collaborator_writer = nil
    direct_affiliate_writer = nil

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:product_affiliate_collaborator_writer]
      next unless payload[:sql].include?("FROM `links`") && payload[:sql].include?("FOR UPDATE")

      Thread.current[:product_affiliate_collaborator_writer] = false
      collaborator_lock << true
      release_collaborator.pop
    end

    collaborator_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:product_affiliate_collaborator_writer] = true
        results << Collaborator::UpdateService.new(
          seller: User.find(@seller.id),
          collaborator_id: collaborator.external_id,
          params: {
            apply_to_all_products: false,
            percent_commission: nil,
            dont_show_as_co_creator: false,
            products: [{ id: @product.external_id, percent_commission: 40, dont_show_as_co_creator: false }]
          }
        ).process
      rescue StandardError => error
        errors << error
      ensure
        Thread.current[:product_affiliate_collaborator_writer] = false
      end
    end
    Timeout.timeout(10) { collaborator_lock.pop }

    direct_affiliate_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        direct_writer_connection_id << ActiveRecord::Base.connection.select_value("SELECT CONNECTION_ID()")
        ProductAffiliate.create!(affiliate: Affiliate.find(@affiliate.id), product: Link.find(@product.id), affiliate_basis_points: 10_00)
        results << :direct_affiliate_created
      rescue StandardError => error
        errors << error
      end
    end
    process_id = Timeout.timeout(10) { direct_writer_connection_id.pop }
    wait_for_row_lock(process_id:, table: "links")

    expect(direct_affiliate_writer).to be_alive
    expect(results).to be_empty

    release_collaborator << true
    [collaborator_writer, direct_affiliate_writer].each { expect(_1.join(10)).to be_present }

    expect(results.pop).to eq(success: true)
    expect(errors.size).to eq(1)
    expect(errors.pop).to be_a(ActiveRecord::RecordInvalid)
    expect(@product.reload).to be_is_collab
    expect(ProductAffiliate.where(affiliate: collaborator, product: @product).count).to eq(1)
    expect(ProductAffiliate.where(affiliate: @affiliate, product: @product)).to be_empty
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_collaborator << true if defined?(release_collaborator) && release_collaborator
    [collaborator_writer, direct_affiliate_writer].compact.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
    ProductAffiliate.where(affiliate_id: collaborator&.id).delete_all
    AudienceMember.where(seller_id: @seller&.id, email: collaborator_user&.email).delete_all
    Affiliate.where(id: collaborator&.id).delete_all
    UserComplianceInfo.where(user_id: collaborator_user&.id).delete_all
    User.where(id: collaborator_user&.id).delete_all
  end

  it "reloads collaborator assignments after locking their complete product set" do
    collaborator_user = create(:affiliate_user, username: "paf#{SecureRandom.hex(8)}")
    collaborator = create(:collaborator, seller: @seller, affiliate_user: collaborator_user, affiliate_basis_points: 40_00)
    ProductAffiliate.create!(affiliate: collaborator, product: @product, affiliate_basis_points: 40_00)
    added_product = create(:product, user: @seller)
    initial_product_read = Queue.new
    release_updater = Queue.new
    results = Queue.new
    errors = Queue.new
    updater = nil

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      next unless Thread.current[:product_affiliate_set_updater]
      next unless payload[:sql].include?("FROM `affiliates_links`")
      next if payload[:sql].include?("FOR UPDATE")

      Thread.current[:product_affiliate_set_updater] = false
      initial_product_read << true
      release_updater.pop
    end

    updater = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:product_affiliate_set_updater] = true
        results << Collaborator::UpdateService.new(
          seller: User.find(@seller.id),
          collaborator_id: collaborator.external_id,
          params: {
            apply_to_all_products: false,
            percent_commission: nil,
            dont_show_as_co_creator: false,
            products: [{ id: @product.external_id, percent_commission: 40, dont_show_as_co_creator: false }]
          }
        ).process
      rescue StandardError => error
        errors << error
      ensure
        Thread.current[:product_affiliate_set_updater] = false
      end
    end
    Timeout.timeout(10) { initial_product_read.pop }

    ProductAffiliate.create!(affiliate: collaborator.reload, product: added_product, affiliate_basis_points: 40_00)
    release_updater << true
    expect(updater.join(10)).to be_present

    expect(errors).to be_empty
    expect(results.pop).to eq(success: true)
    expect(ProductAffiliate.where(affiliate: collaborator).pluck(:link_id)).to contain_exactly(@product.id)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_updater << true if defined?(release_updater) && release_updater
    if updater && !updater.join(1)
      updater.kill
      updater.join
    end
    ProductAffiliate.where(affiliate_id: collaborator&.id).delete_all
    AudienceMember.where(seller_id: @seller&.id, email: collaborator_user&.email).delete_all
    Affiliate.where(id: collaborator&.id).delete_all
    Price.where(link_id: added_product&.id).delete_all
    Link.where(id: added_product&.id).delete_all
    UserComplianceInfo.where(user_id: collaborator_user&.id).delete_all
    User.where(id: collaborator_user&.id).delete_all
  end

  it "returns the existing assignment after waiting with an old snapshot" do
    first_lock = Queue.new
    release_first = Queue.new
    second_snapshot = Queue.new
    results = Queue.new
    errors = Queue.new

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      if Thread.current[:product_affiliate_first_writer] && sql.include?("FROM `affiliates`") && sql.include?("FOR UPDATE")
        Thread.current[:product_affiliate_first_writer] = false
        first_lock << true
        release_first.pop
      end
    end

    first_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Thread.current[:product_affiliate_first_writer] = true
        results << ProductAffiliate.create_if_missing!(affiliate: Affiliate.find(@affiliate.id), product: Link.find(@product.id))
      rescue StandardError => error
        errors << error
      ensure
        Thread.current[:product_affiliate_first_writer] = false
      end
    end
    Timeout.timeout(10) { first_lock.pop }

    second_writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ProductAffiliate.transaction do
          ProductAffiliate.where(affiliate_id: @affiliate.id, link_id: @product.id).exists?
          second_snapshot << true
          results << ProductAffiliate.create_if_missing!(affiliate: Affiliate.find(@affiliate.id), product: Link.find(@product.id))
        end
      rescue StandardError => error
        errors << error
      end
    end
    Timeout.timeout(10) { second_snapshot.pop }
    sleep 0.1

    expect(second_writer).to be_alive

    release_first << true
    [first_writer, second_writer].each { expect(_1.join(10)).to be_present }

    expect(errors).to be_empty
    expect(2.times.map { results.pop }).to contain_exactly(true, false)
    expect(ProductAffiliate.where(affiliate_id: @affiliate.id, link_id: @product.id).count).to eq(1)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    release_first << true if defined?(release_first) && release_first
    [first_writer, second_writer].compact.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end

  it "recreates an assignment after an old snapshot sees the deleted row" do
    assignment = ProductAffiliate.create!(affiliate: @affiliate, product: @product)
    snapshot_ready = Queue.new
    deletion_done = Queue.new
    results = Queue.new
    errors = Queue.new

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ProductAffiliate.transaction do
          results << ProductAffiliate.where(id: assignment.id).exists?
          snapshot_ready << true
          deletion_done.pop
          results << ProductAffiliate.create_if_missing!(affiliate: Affiliate.find(@affiliate.id), product: Link.find(@product.id))
        end
      rescue StandardError => error
        errors << error
      end
    end
    Timeout.timeout(10) { snapshot_ready.pop }

    ProductAffiliate.find(assignment.id).destroy!
    deletion_done << true
    expect(writer.join(10)).to be_present

    raise errors.pop unless errors.empty?
    expect(2.times.map { results.pop }).to eq([true, true])
    expect(ProductAffiliate.where(affiliate_id: @affiliate.id, link_id: @product.id).count).to eq(1)
  ensure
    deletion_done << true if defined?(deletion_done) && deletion_done
    if writer && !writer.join(1)
      writer.kill
      writer.join
    end
  end

  it "allows concurrent checks for an existing assignment" do
    ProductAffiliate.create!(affiliate: @affiliate, product: @product)
    first_read = Queue.new
    release_first = Queue.new
    second_read = Queue.new
    results = Queue.new
    errors = Queue.new

    first_reader = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ProductAffiliate.transaction do
          results << ProductAffiliate.create_if_missing!(affiliate: Affiliate.find(@affiliate.id), product: Link.find(@product.id))
          first_read << true
          release_first.pop
        end
      rescue StandardError => error
        errors << error
      end
    end
    Timeout.timeout(10) { first_read.pop }

    second_reader = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ProductAffiliate.transaction do
          results << ProductAffiliate.create_if_missing!(affiliate: Affiliate.find(@affiliate.id), product: Link.find(@product.id))
          second_read << true
        end
      rescue StandardError => error
        errors << error
      end
    end

    Timeout.timeout(2) { second_read.pop }
    release_first << true
    [first_reader, second_reader].each { expect(_1.join(10)).to be_present }

    expect(errors).to be_empty
    expect(2.times.map { results.pop }).to eq([false, false])
  ensure
    release_first << true if defined?(release_first) && release_first
    [first_reader, second_reader].compact.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end
end
