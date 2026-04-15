# frozen_string_literal: true

module Onetime
  class EnableMembershipRenewalReminders
    def self.perform(user_id:, dry_run: true)
      puts dry_run ? "DRY RUN MODE\n" : "LIVE MODE\n"

      seller = User.find_by(id: user_id) || User.find_by(external_id: user_id)
      unless seller
        puts "ERROR: User with ID #{user_id} not found"
        return
      end

      puts "Seller: #{seller.name} (#{seller.email})\n\n"

      if Feature.active?(:membership_renewal_reminders, seller)
        puts "Feature already enabled"
      else
        unless dry_run
          Feature.activate_user(:membership_renewal_reminders, seller)
        end
        puts "Feature flag: #{dry_run ? 'Would enable' : 'Enabled'} membership_renewal_reminders"
      end

      puts "\n"

      scheduled_jobs = Set.new
      Sidekiq::ScheduledSet.new.scan("RecurringChargeReminderWorker") do |job|
        scheduled_jobs.add(job.args.first)
      end

      scheduled = 0
      errors = 0

      Subscription.where(seller_id: seller.id)
                  .active
                  .find_each do |subscription|
        next unless subscription.alive?(include_pending_cancellation: false)
        next if subscription.in_free_trial?
        next if subscription.charges_completed?

        begin
          renewal_time = subscription.end_time_of_subscription
          reminder_lead_time = BasePrice::Recurrence.renewal_reminder_email_days(subscription.recurrence)

          # Skip if renewal is in the past or too close or already scheduled
          if renewal_time <= Time.current || (renewal_time - Time.current) < reminder_lead_time || scheduled_jobs.include?(subscription.id)
            next
          end

          puts "\nSubscription #{subscription.id}"
          puts "  Customer: #{subscription.email}"
          puts "  Next renewal: #{renewal_time.strftime('%Y-%m-%d %H:%M')}"
          puts "  Reminder at: #{subscription.send_renewal_reminder_at.strftime('%Y-%m-%d %H:%M')}"
          puts "  Action: #{dry_run ? 'Would schedule' : 'Scheduled'} RecurringChargeReminderWorker"

          unless dry_run
            subscription.schedule_renewal_reminder
          end
          scheduled += 1
        rescue => e
          puts "  ERROR: #{e.message}"
          errors += 1
        end
      end

      puts "\n\nScheduled: #{scheduled}"
      puts "Errors: #{errors}"
      puts "\n#{dry_run ? 'DRY RUN - No changes made' : 'Changes applied'}"
    end
  end
end
