# frozen_string_literal: true

require "spec_helper"

describe "mysql2 proxy free-trial reminder routing", :vcr do
  include_context "real mysql2 proxy pools"

  before do
    primary_setup do
      create(:merchant_account, user: nil) unless MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      @subscription = create(:free_trial_membership_purchase).subscription
    end
    replicate_record(@subscription)
    @digest = SentEmailInfo.mailer_key_digest("CustomerLowPriorityMailer", "free_trial_expiring_soon", @subscription.id)
  end

  it "does not enqueue a reminder whose completed marker has not reached a cold replica" do
    primary_setup { SentEmailInfo.set_key!(@digest) }
    expect(serving_pool).to eq("replica")
    reads = nil

    aggregate_failures do
      expect do
        reads = record_serving_reads { FreeTrialExpiringReminderWorker.new.perform(@subscription.id) }
      end.not_to have_enqueued_mail(CustomerLowPriorityMailer)

      marker_reads = reads.select { |sql, _| sql.include?("`sent_email_infos`") }
      expect(marker_reads).not_to be_empty
      expect(marker_reads.map(&:last).uniq).to eq(["primary"])
    end
    expect(serving_pool).to eq("replica")
  end

  it "enqueues once when sequential workers start with cold routing contexts" do
    reads = nil
    expect do
      FreeTrialExpiringReminderWorker.new.perform(@subscription.id)
      cold_write_context
      reads = record_serving_reads { FreeTrialExpiringReminderWorker.new.perform(@subscription.id) }
    end.to have_enqueued_mail(CustomerLowPriorityMailer, :free_trial_expiring_soon).with(@subscription.id).once

    marker_reads = reads.select { |sql, _| sql.include?("`sent_email_infos`") }
    expect(marker_reads.map(&:last).uniq).to eq(["primary"])
    expect(serving_pool).to eq("replica")
  end

  it "reads fresh eligibility and markers on primary without a SQL transaction or lock during enqueue" do
    allow(MailDeliveryJob.queue_adapter).to receive(:enqueue).and_wrap_original do |original, job|
      expect(ApplicationRecord.connection.open_transactions).to eq(0)
      expect(serving_pool).to eq("primary")
      original.call(job)
    end

    reads = record_serving_reads { FreeTrialExpiringReminderWorker.new.perform(@subscription.id) }

    %w[subscriptions sent_email_infos].each do |table|
      relevant = reads.select { |sql, _| sql.include?("`#{table}`") }
      expect(relevant).not_to be_empty
      expect(relevant.map(&:last).uniq).to eq(["primary"])
    end
    expect(reads.map(&:first).join).not_to include("FOR UPDATE")
    cold_write_context
    expect(serving_pool).to eq("replica")
  end

  it "unwinds the primary scope after enqueue failure without recording success" do
    allow(MailDeliveryJob.queue_adapter).to receive(:enqueue).and_raise("queue unavailable")

    expect do
      FreeTrialExpiringReminderWorker.new.perform(@subscription.id)
    end.to raise_error("queue unavailable")

    expect(serving_pool).to eq("replica")
    expect(primary_setup { SentEmailInfo.key_exists?(@digest) }).to be(false)
  end
end
