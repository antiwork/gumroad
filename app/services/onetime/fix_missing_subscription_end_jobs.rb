# frozen_string_literal: true

module Onetime
  class FixMissingSubscriptionEndJobs
    def self.perform(dry_run: true)
      puts dry_run ? "DRY RUN MODE\n" : "LIVE MODE\n"

      scheduled_jobs = Set.new
      Sidekiq::ScheduledSet.new.scan("EndSubscriptionWorker") do |job|
        scheduled_jobs.add(job.args.first)
      end

      past_due = 0
      future_scheduled = 0
      errors = 0
      processed = 0

      Subscription.where.not(charge_occurrence_count: nil)
                  .where(ended_at: nil)
                  .find_each do |subscription|
        next unless subscription.charges_completed?

        begin
          last_purchase = subscription.last_successful_charge
          should_end_at = last_purchase.succeeded_at + subscription.period

          puts "\nSubscription #{subscription.id} (#{subscription.external_id})"
          puts "  Last purchase id: #{last_purchase.id} (#{last_purchase.external_id})"
          puts "  Last charge: #{last_purchase.succeeded_at}"
          puts "  Should end: #{should_end_at}"

          if should_end_at <= Time.current
            puts "  Action: End subscription (past due)"
            unless dry_run
              subscription.with_lock do
                subscription.ended_at = should_end_at
                subscription.deactivate!
              end
            end
            past_due += 1
          elsif scheduled_jobs.include?(subscription.id)
            puts "  Action: Worker already scheduled (skipped)"
          else
            puts "  Action: Schedule EndSubscriptionWorker for #{should_end_at}"
            unless dry_run
              EndSubscriptionWorker.perform_at(should_end_at, subscription.id)
            end
            future_scheduled += 1
          end

          processed += 1
        rescue => e
          puts "  ERROR: #{e.message}"
          errors += 1
        end
      end

      puts "\n\nProcessed: #{processed}"
      puts "Past due ended: #{past_due}"
      puts "Future scheduled: #{future_scheduled}"
      puts "Errors: #{errors}"
      puts "\n#{dry_run ? 'DRY RUN - No changes made' : 'Changes applied'}"
    end
  end
end
