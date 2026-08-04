# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe LastReadCommunityChatMessage, ".set! concurrency" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    @reader = create(:user)
    @product = create(:product, user: @seller)
    @community = create(:community, seller: @seller, resource: @product)
    @first_message = create(:community_chat_message, community: @community, user: @seller, created_at: 3.minutes.ago)
    @older_message = create(:community_chat_message, community: @community, user: @seller, created_at: 2.minutes.ago)
    @newer_message = create(:community_chat_message, community: @community, user: @seller, created_at: 1.minute.ago)
    create(
      :last_read_community_chat_message,
      user: @reader,
      community: @community,
      community_chat_message: @first_message
    )
  end

  after do
    @community.destroy!
    @product.destroy!
    RefundPolicy.where(seller_id: @seller.id).delete_all
    @reader.destroy!
    @seller.destroy!
  end

  it "keeps the newest marker when concurrent updates finish out of order" do
    ready = Queue.new
    initial_reads = Queue.new
    read_resumed = Queue.new
    releases = {
      @older_message.id => Queue.new,
      @newer_message.id => Queue.new,
    }
    read_releases = {
      @older_message.id => Queue.new,
      @newer_message.id => Queue.new,
    }
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      message_id = Thread.current[:last_read_message_id]
      next unless message_id && payload[:sql].include?("FROM `last_read_community_chat_messages`") &&
        !payload[:sql].include?("FOR UPDATE")

      Thread.current[:last_read_message_id] = nil
      initial_reads << message_id
      read_releases.fetch(message_id).pop
      read_resumed << message_id
    end
    allow_any_instance_of(described_class).to receive(:update!).and_wrap_original do |method, attributes|
      message_id = attributes[:community_chat_message_id] || attributes.fetch(:community_chat_message).id
      ready << message_id
      releases.fetch(message_id).pop
      method.call(attributes)
    end

    errors = Queue.new
    threads = {}
    start_update = lambda do |message|
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:last_read_message_id] = message.id
          described_class.set!(
            user_id: @reader.id,
            community_id: @community.id,
            community_chat_message_id: message.id
          )
        rescue => e
          errors << e
        end
      end
      threads[message.id] = thread
    end

    start_update.call(@older_message)
    start_update.call(@newer_message)
    expect(2.times.map { Timeout.timeout(10) { initial_reads.pop } }).to contain_exactly(
      @older_message.id,
      @newer_message.id
    )

    read_releases.fetch(@older_message.id) << true
    expect(Timeout.timeout(10) { read_resumed.pop }).to eq(@older_message.id)
    expect(Timeout.timeout(10) { ready.pop }).to eq(@older_message.id)
    read_releases.fetch(@newer_message.id) << true
    expect(Timeout.timeout(10) { read_resumed.pop }).to eq(@newer_message.id)

    second_update_reached_write = begin
      Timeout.timeout(1) { ready.pop }
    rescue Timeout::Error
      nil
    end

    if second_update_reached_write
      expect(second_update_reached_write).to eq(@newer_message.id)
      releases.fetch(@newer_message.id) << true
      expect(threads.fetch(@newer_message.id).join(10)).to be_present
      releases.fetch(@older_message.id) << true
    else
      releases.fetch(@older_message.id) << true
      expect(Timeout.timeout(10) { ready.pop }).to eq(@newer_message.id)
      releases.fetch(@newer_message.id) << true
    end
    threads.each_value { expect(_1.join(10)).to be_present }

    expect(errors.size).to eq(0), -> { errors.size.times.map { errors.pop.full_message }.join("\n") }
    expect(described_class.find_by!(user: @reader, community: @community).community_chat_message_id).to eq(@newer_message.id)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    read_releases&.each_value { _1 << true }
    releases&.each_value { _1 << true }
    threads&.each_value do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end

  it "creates one newest marker when the first updates are concurrent" do
    described_class.delete_all
    ready = Queue.new
    release = Queue.new
    allow(described_class).to receive(:create!).and_wrap_original do |method, *args|
      ready << true
      release.pop
      method.call(*args)
    end

    errors = Queue.new
    threads = [@older_message, @newer_message].map do |message|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          described_class.set!(
            user_id: @reader.id,
            community_id: @community.id,
            community_chat_message_id: message.id
          )
        rescue => e
          errors << e
        end
      end
    end

    2.times { Timeout.timeout(10) { ready.pop } }
    2.times { release << true }
    threads.each { expect(_1.join(10)).to be_present }

    expect(errors.size).to eq(0), -> { errors.size.times.map { errors.pop.full_message }.join("\n") }
    expect(described_class.where(user: @reader, community: @community).count).to eq(1)
    expect(described_class.find_by!(user: @reader, community: @community).community_chat_message_id).to eq(@newer_message.id)
  ensure
    2.times { release << true } if defined?(release) && release
    threads&.each do |thread|
      next if thread.join(1)

      thread.kill
      thread.join
    end
  end
end
