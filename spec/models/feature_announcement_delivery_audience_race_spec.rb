# frozen_string_literal: true

require "spec_helper"
require "timeout"

# The handoff gate can wait on the seller's row. If the seller stops qualifying for the campaign meanwhile,
# the provider must not get the message.
describe FeatureAnnouncementDelivery, "audience changes while the handoff waits", :aggregate_failures do
  self.use_transactional_tests = false

  before do
    @seller, @product = create_piracy_seller_with_product
    @seller.update_columns(email: "audience-race-seller@example.com")
    FeatureAnnouncementSubscription.update_from_settings!(@seller, subscribed: true, rendered_version: 0)
    ActionMailer::Base.deliveries.clear
  end

  after do
    FeatureAnnouncementDelivery.where(user_id: @seller.id).delete_all
    FeatureAnnouncementSubscription.where(user_id: @seller.id).delete_all
    Purchase.where(link_id: @product.id).delete_all
    Payment.where(user_id: @seller.id).delete_all
    UserComplianceInfo.where(user_id: @seller.id).delete_all
    AudienceMember.where(seller_id: @seller.id).delete_all
    Price.where(link_id: @product.id).delete_all
    Link.where(id: @product.id).delete_all
    @seller.destroy!
    delete_leftovers(user_ids: [@seller.id])
  end

  def in_thread(&block) = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }

  def finish(*threads)
    threads.compact.each { _1.join(15) }
  rescue Timeout::Error, StandardError
    nil
  end

  def lock_waits = ActiveRecord::Base.connection.uncached { ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM performance_schema.data_lock_waits") }.to_i

  def delivery = FeatureAnnouncementDelivery.find_by(campaign: "piracy_reports", user_id: @seller.id)

  # Holds the seller's row (a Settings save does the same) while the real delivery waits on it, applies the
  # change from a third connection, then lets the delivery go on.
  def deliver_while_waiting(&change)
    locked = Queue.new
    release = Queue.new
    holder = in_thread do
      ApplicationRecord.transaction do
        User.lock.find(@seller.id)
        locked << true
        Timeout.timeout(20) { release.pop }
      end
    end
    Timeout.timeout(10) { locked.pop }
    sending = in_thread { FeatureAnnouncementMailer.announcement(campaign: "piracy_reports", user_id: @seller.id, email: @seller.email).deliver_now }
    Timeout.timeout(10) { sleep 0.05 until lock_waits > 0 }
    in_thread(&change).value
    release << true
    holder.value
    sending.value
  ensure
    finish(holder, sending)
  end

  {
    "its only qualifying product stops being sold" => -> { @product.update!(purchase_disabled_at: Time.current) },
    "the product's only sale stops counting as successful" => -> { Purchase.where(link_id: @product.id).update_all(purchase_state: "failed") },
    "the seller no longer has a completed payout" => -> { Payment.where(user_id: @seller.id).update_all(state: "failed") },
  }.each do |name, change|
    it "skips the message without reaching the provider when #{name}" do
      deliver_while_waiting { instance_exec(&change) }

      expect(delivery.attributes.slice("state", "reason")).to eq("state" => "skipped", "reason" => "not_in_audience")
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  it "still delivers once the wait ends when nothing about the seller changed" do
    deliver_while_waiting { nil }

    expect(delivery.state).to eq("delivered")
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([[@seller.email]])
  end
end
