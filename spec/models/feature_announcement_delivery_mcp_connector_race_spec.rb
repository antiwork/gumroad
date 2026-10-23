# frozen_string_literal: true

require "spec_helper"
require "timeout"

# The mcp_connector campaign reads its creator audience with no stub, so these races run the whole
# gate against writers on separate connections, in both orders.
describe FeatureAnnouncementDelivery, "mcp_connector races", :aggregate_failures do
  self.use_transactional_tests = false

  before do
    ActionMailer::Base.deliveries.clear
    @user = create(:user, email: "mcp-race@example.com")
    FeatureAnnouncementSubscription.update_from_settings!(@user, subscribed: true, rendered_version: 0)
  end

  after do
    next if @user.nil?

    product_ids = Link.where(user_id: @user.id).ids
    FeatureAnnouncementDelivery.where(user_id: @user.id).delete_all
    FeatureAnnouncementSubscription.where(user_id: @user.id).delete_all
    Link.where(id: product_ids).delete_all
    @user.destroy!
    delete_leftovers(user_ids: [@user.id], product_ids:)
  end

  def in_thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  def lock_waits = ActiveRecord::Base.connection.uncached { ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM performance_schema.data_lock_waits") }.to_i

  def announcement = FeatureAnnouncementMailer.announcement(campaign: "mcp_connector", user_id: @user.id, email: @user.email)

  def delivery = FeatureAnnouncementDelivery.find_by!(campaign: "mcp_connector", user_id: @user.id)

  def make_creator! = create(:product, user: @user)

  # The writer commits only after the real delivery is waiting on its locks.
  def deliver_behind(&write)
    locked = Queue.new
    holder = in_thread do
      ApplicationRecord.transaction do
        instance_exec(&write)
        locked << true
        Timeout.timeout(10) { sleep 0.05 until lock_waits > 0 }
      end
    end
    Timeout.timeout(10) { locked.pop }
    announcement.deliver_now
    holder.value
  ensure
    holder&.join(15)
  end

  # The writer starts while the provider handoff is in progress.
  def write_during_handoff(&write)
    in_smtp = Queue.new
    release = Queue.new
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_wrap_original do |original, *args|
      in_smtp << true
      release.pop
      original.call(*args)
    end
    sender = in_thread { announcement.deliver_now }
    Timeout.timeout(10) { in_smtp.pop }
    writer = in_thread { instance_exec(&write) }
    Timeout.timeout(10) { sleep 0.05 until lock_waits > 0 }
    expect(writer).to be_alive
    expect(delivery.state).to eq("claimed")
    release << true
    sender.value
    writer.value
  ensure
    release&.push(true)
    sender&.join(15)
    writer&.join(15)
  end

  it "delivers to an account that became a creator while the handoff waited" do
    deliver_behind do
      User.lock.find(@user.id)
      make_creator!
    end

    expect(delivery.state).to eq("delivered")
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([["mcp-race@example.com"]])
  end

  context "with a creator" do
    before { make_creator! }

    {
      "an opt-out" => [-> { FeatureAnnouncementSubscription.unsubscribe!(@user, source: "unsubscribe_link") }, "not_subscribed"],
      "a suspension" => [-> { User.find(@user.id).update!(user_risk_state: "suspended_for_tos_violation") }, "account_inactive"],
      "a pending email change" => [-> { User.where(id: @user.id).update_all(unconfirmed_email: "mcp-race-new@example.com") }, "email_change_pending"],
    }.each do |name, (write, reason)|
      it "skips the message when #{name} commits while the handoff waits" do
        deliver_behind(&write)

        expect(delivery.attributes.slice("state", "reason")).to eq("state" => "skipped", "reason" => reason)
        expect(ActionMailer::Base.deliveries).to be_empty
      end

      it "makes #{name} that starts during the handoff wait until the provider has the message" do
        write_during_handoff(&write)

        expect(delivery.state).to eq("delivered")
        expect(ActionMailer::Base.deliveries.size).to eq(1)
      end
    end
  end
end
