# frozen_string_literal: true

require "spec_helper"

describe RecurringChargeReminderWorker, :vcr do
  include ManageSubscriptionHelpers

  before do
    setup_subscription
    travel_to @subscription.end_time_of_subscription - 6.days
    allow_any_instance_of(Subscription).to receive(:send_renewal_reminders?).and_return(true)
  end

  it "sends a reminder email about an upcoming charge" do
    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  it "does not send a reminder if the subscription is no longer alive" do
    @subscription.update!(failed_at: 1.day.ago)

    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  it "does not send a reminder if the subscription is pending cancellation" do
    @subscription.update!(cancelled_at: 1.day.from_now)

    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  it "does not send a reminder for a fixed-length subscription that has had its last charge" do
    @subscription.update!(charge_occurrence_count: 1)
    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  it "does not send a reminder if `send_renewal_reminders?` is false" do
    allow_any_instance_of(Subscription).to receive(:send_renewal_reminders?).and_return(false)

    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  it "does not send a reminder for a subscription still in a free trial" do
    @subscription.update!(free_trial_ends_at: 1.week.from_now)
    expect do
      RecurringChargeReminderWorker.new.perform(@subscription.id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  it "does not send a reminder while an Indian card mandate update is required",
     vcr: { cassette_name: "RecurringChargeReminderWorker/does_not_send_a_reminder_if_the_subscription_is_no_longer_alive" } do
    @subscription.update!(renewal_disabled_due_to_indian_card_mandate: true)
    allow_any_instance_of(Subscription).to receive(:india_card_mandate_reliability_enabled?).and_return(true)

    expect do
      described_class.new.perform(@subscription.id)
    end.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id)
  end

  # Every example here makes the same Stripe calls in setup_subscription, so they share one cassette.
  describe "advance notice for renewals of 12+ months",
           vcr: { cassette_name: "RecurringChargeReminderWorker/advance_notice_for_renewals_of_12_months/sends_the_advance_notice_once" } do
    before do
      allow_any_instance_of(Subscription).to receive(:recurrence).and_return("yearly")
      travel_to @subscription.end_time_of_subscription - 29.days
    end

    def perform_advance
      described_class.new.perform(@subscription.id, described_class::ADVANCE)
    end

    it "sends the advance notice once" do
      expect do
        2.times { perform_advance }
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id).once
    end

    it "sends one advance notice for each renewal" do
      perform_advance
      next_renewal = @subscription.end_time_of_subscription + 1.year
      allow_any_instance_of(Subscription).to receive(:end_time_of_subscription).and_return(next_renewal)
      travel_to next_renewal - 29.days

      expect do
        2.times { perform_advance }
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).with(@subscription.id).once
    end

    it "skips a job scheduled for an earlier renewal date" do
      travel_to @subscription.end_time_of_subscription - 44.days

      expect { perform_advance }.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder)

      travel_to @subscription.end_time_of_subscription - 29.days
      expect { perform_advance }.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).once
    end

    it "skips a job whose subscription has since moved to a period under 12 months" do
      renews_at = @subscription.end_time_of_subscription
      allow_any_instance_of(Subscription).to receive(:recurrence).and_call_original
      allow_any_instance_of(Subscription).to receive(:end_time_of_subscription).and_return(renews_at)
      expect(@subscription.reload.recurrence).to eq(BasePrice::Recurrence::QUARTERLY)

      expect { perform_advance }.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder)
    end

    it "keeps a failed enqueue retryable" do
      allow(CustomerLowPriorityMailer).to receive(:subscription_renewal_reminder).and_raise(RuntimeError, "redis down")

      expect { perform_advance }.to raise_error(RuntimeError, "redis down")
      allow(CustomerLowPriorityMailer).to receive(:subscription_renewal_reminder).and_call_original

      expect { perform_advance }.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).once
    end

    it "treats an enqueue that returns nothing as a failure so a retry can send" do
      allow_any_instance_of(ActionMailer::MessageDelivery).to receive(:deliver_later).and_return(nil)

      expect { perform_advance }.to raise_error(described_class::EmailNotEnqueuedError)
      allow_any_instance_of(ActionMailer::MessageDelivery).to receive(:deliver_later).and_call_original

      expect { perform_advance }.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).once
    end

    it "retries a marker failure after the email was accepted, at the cost of one duplicate" do
      allow(SentEmailInfo).to receive(:set_key!).and_raise("marker unavailable")

      expect do
        expect { perform_advance }.to raise_error("marker unavailable")
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).once

      allow(SentEmailInfo).to receive(:set_key!).and_call_original
      expect do
        2.times { perform_advance }
      end.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).once
    end

    it "skips the advance notice once the final reminder is due" do
      travel_to @subscription.end_time_of_subscription - 6.days

      expect { perform_advance }.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder)
    end

    it "keeps the existing guards" do
      @subscription.update!(failed_at: 1.day.ago)

      expect { perform_advance }.not_to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder)
    end

    context "with runtime uniqueness enabled" do
      around do |example|
        SidekiqUniqueJobs.use_config(enabled: true) { example.run }
      end

      def run_job(job, queue)
        SidekiqUniqueJobs::Middleware::Server.new.call(described_class.new, job, queue) do
          described_class.new.perform(*job.fetch("args"))
        end
      end

      it "serializes overlapping copies of an advance job across queues without sending twice" do
        described_class.clear
        described_class.perform_async(@subscription.id, described_class::ADVANCE)
        described_class.set(queue: "low").perform_async(@subscription.id, described_class::ADVANCE)
        described_class.perform_async(@subscription.id)
        first_job, second_job, final_reminder_job = described_class.jobs
        checked_overlap = false

        allow(MailDeliveryJob.queue_adapter).to receive(:enqueue).and_wrap_original do |original, job|
          unless checked_overlap
            checked_overlap = true
            expect { run_job(second_job, "low") }.to raise_error(SidekiqUniqueJobs::Conflict)
            expect { run_job(final_reminder_job, "default") }.not_to raise_error
          end
          original.call(job)
        end

        expect { run_job(first_job, "default") }.to have_enqueued_mail(CustomerLowPriorityMailer, :subscription_renewal_reminder).twice
        expect { run_job(second_job, "low") }.not_to have_enqueued_mail(CustomerLowPriorityMailer)
      end
    end
  end
end
