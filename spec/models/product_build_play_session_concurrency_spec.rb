# frozen_string_literal: true

require "spec_helper"
require "timeout"

describe ProductBuildPlaySession, "beats from separate connections" do
  self.use_transactional_tests = false

  let(:start) { Time.utc(2026, 11, 3, 12, 0, 0) }

  before do
    @seller = create(:user)
    @product = create(:product, user: @seller)
    @build = create(:product_build, :live, product: @product)
    @purchase = create(:purchase, link: @product)
    @session = described_class.start!(product_build: @build, purchase: @purchase, at: start)
  end

  after do
    described_class.where(purchase_id: @purchase&.id).delete_all
    Purchase.where(id: @purchase&.id).delete_all
    AudienceMember.where(seller_id: @seller&.id).delete_all
    ProductBuild.where(id: @build&.id).delete_all
    Price.where(link_id: @product&.id).delete_all
    Link.where(id: @product&.id).delete_all
    Affiliate.where(affiliate_user_id: @seller&.id).delete_all
    @seller&.destroy!
  end

  # Each beat loads its session on its own connection, as the controller does, and waits for `go` before beating.
  def beats_loaded_first(beats)
    loaded = Queue.new
    go = Queue.new
    threads = beats.map do |session_id, at|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          loaded_session = described_class.find(session_id)
          loaded << true
          next unless go.pop

          loaded_session.heartbeat!(at).id
        end
      end
    end
    Timeout.timeout(10) { beats.size.times { loaded.pop } }
    yield if block_given?
    beats.size.times { go << true }
    Timeout.timeout(20) { threads.map(&:value) }
  ensure
    # A failure before the release would leave the workers waiting on `go` while holding connections;
    # closing it wakes them with nil, and they return without beating. A join re-raises a worker's
    # error, so each one is rescued to keep waiting for the rest while the original failure propagates.
    go&.close
    threads&.each do |thread|
      thread.join(20)
    rescue StandardError
      nil
    end
  end

  # Holds each beat inside the replacement's insert long enough for the other to arrive, so without the
  # row lock both would start one.
  def slow_start!
    allow(described_class).to receive(:start!).and_wrap_original do |original, **kwargs|
      sleep 0.3
      original.call(**kwargs)
    end
  end

  it "starts one replacement when beats on separate connections both find the session expired" do
    slow_start!

    resumed_ids = beats_loaded_first([[@session.id, start + 1.hour], [@session.id, start + 1.hour + 1.second]])

    expect(resumed_ids.uniq.size).to eq(1)
    expect(described_class.where(purchase_id: @purchase.id).count).to eq(2)
    expect(described_class.find(resumed_ids.first).last_heartbeat_at).to eq(start + 1.hour + 1.second)
  end

  it "extends the session when a beat committed after it was loaded keeps it open" do
    resumed_ids = beats_loaded_first([[@session.id, start + 2.minutes + 10.seconds]]) do
      described_class.find(@session.id).heartbeat!(start + 1.minute + 50.seconds)
    end

    expect(resumed_ids).to eq([@session.id])
    expect(described_class.where(purchase_id: @purchase.id).count).to eq(1)
    expect(@session.reload.last_heartbeat_at).to eq(start + 2.minutes + 10.seconds)
  end

  it "starts one session after an expired replacement when its old and new grants beat at once" do
    replacement = @session.heartbeat!(start + 1.hour)
    slow_start!

    resumed_ids = beats_loaded_first([[@session.id, start + 2.hours], [replacement.id, start + 2.hours + 1.second]])

    expect(resumed_ids.uniq.size).to eq(1)
    expect(replacement.reload.replacement_id).to eq(resumed_ids.first)
    expect(described_class.where(purchase_id: @purchase.id).count).to eq(3)
  end
end
