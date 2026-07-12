# frozen_string_literal: true

# Permanent QA seed tasks for preview apps (https://github.com/antiwork/gumroad/issues/5806).
#
# Before these existed, seeding edge-case state on a preview app (a backdated purchase to force a
# subscription renewal, a card with no e-mandate, a dead Sidekiq job) meant shipping temporary
# param-gated hooks in the PR itself, marked "TEMP: revert before merge" — extra commits, review
# noise, and a real risk of the hook leaking into main. These tasks are reviewed once and reused
# forever instead.
#
# Run them through the preview app's Rails console one-shot path (see "Deploying to a preview app"
# in docs/deploying.md), for example:
#
#   COMMAND='Rake::Task["preview_qa:backdate_purchase"].invoke("<purchase external_id>")' ./console.sh -w <branch>
#
# Every task hard-aborts in production; the guard is intentionally belt-and-braces (the whole
# namespace is skipped when the file loads in production, and each task re-checks at run time in
# case the file is ever loaded by other means).

module PreviewQa
  module_function

  def ensure_not_production!
    abort "preview_qa tasks are for preview/staging QA only and cannot run in production." if Rails.env.production?
  end

  # Accepts either a numeric database id or an external_id, so you can paste whichever
  # identifier you have on hand (URLs and admin pages expose external ids).
  def find_record!(klass, identifier)
    identifier = identifier.to_s.strip
    abort "Missing #{klass.name} identifier." if identifier.blank?

    record = if identifier.match?(/\A\d+\z/)
      klass.find_by(id: identifier)
    end
    record ||= klass.find_by_external_id(identifier)
    abort "Could not find #{klass.name} with id or external_id #{identifier.inspect}." if record.nil?
    record
  end

  # Resolves a worker class name and verifies it is actually a Sidekiq job, so the run_worker
  # task can't be used to instantiate and call arbitrary application classes.
  def worker_class!(name)
    abort "Missing worker class name (e.g. preview_qa:run_worker[RecurringChargeWorker,123])." if name.blank?

    klass = name.to_s.safe_constantize
    unless klass.is_a?(Class) && klass.include?(Sidekiq::Job)
      abort "#{name.inspect} is not a Sidekiq worker class."
    end
    klass
  end

  # Rake passes every argument as a string; workers usually expect integer ids and booleans.
  # Casts the obvious scalar types and leaves everything else as a string.
  def cast_argument(value)
    case value
    when /\A-?\d+\z/ then Integer(value)
    when /\A-?\d+\.\d+\z/ then Float(value)
    when "true" then true
    when "false" then false
    when "nil", "null" then nil
    else value
    end
  end
end

unless Rails.env.production?
  namespace :preview_qa do
    desc "Backdate a purchase's created_at/succeeded_at by N days (default: one billing period + 1 day for subscription purchases) so renewal paths can be exercised"
    task :backdate_purchase, [:purchase_id, :days] => :environment do |_task, args|
      PreviewQa.ensure_not_production!

      purchase = PreviewQa.find_record!(Purchase, args[:purchase_id])

      days = args[:days].presence&.to_i
      if days.nil? && purchase.subscription.present?
        # Default to just past the subscription's billing period, which is the common case:
        # make the subscription look overdue so RecurringChargeWorker will actually charge it.
        days = (purchase.subscription.period / 1.day).ceil + 1
      end
      abort "Pass a positive number of days (this purchase has no subscription to derive a billing period from)." if days.nil? || days <= 0

      backdated_to = days.days.ago
      # update_columns on purpose: this is a QA time-travel edit, and running the full
      # callback/validation stack against a doctored timestamp is exactly what we don't want.
      purchase.update_columns(
        created_at: backdated_to,
        succeeded_at: (backdated_to if purchase.succeeded_at.present?)
      )

      puts "Backdated purchase #{purchase.external_id} (id #{purchase.id}) by #{days} days: created_at/succeeded_at now #{backdated_to}."
    end

    desc "Remove the Stripe e-mandate linkage (stripe_setup_intent_id) from the card charged for a subscription, to QA the missing-mandate path for Indian cards"
    task :clear_mandate, [:subscription_id] => :environment do |_task, args|
      PreviewQa.ensure_not_production!

      subscription = PreviewQa.find_record!(Subscription, args[:subscription_id])
      credit_card = subscription.credit_card_to_charge
      abort "Subscription #{subscription.external_id} has no chargeable credit card." if credit_card.nil?

      json_data = (credit_card.json_data || {}).deep_stringify_keys
      removed = json_data.delete("stripe_setup_intent_id")
      if removed.nil?
        puts "Credit card #{credit_card.id} for subscription #{subscription.external_id} has no stripe_setup_intent_id; nothing to clear."
      else
        credit_card.update!(json_data:)
        puts "Cleared stripe_setup_intent_id #{removed.inspect} from credit card #{credit_card.id} (subscription #{subscription.external_id})."
      end
    end

    desc "Seed a job into the Sidekiq dead set (morgue), e.g. to QA dead-job alerting/UI. Usage: preview_qa:seed_dead_job[WorkerClass,arg1,arg2,...]"
    task :seed_dead_job, [:worker_class] => :environment do |_task, args|
      PreviewQa.ensure_not_production!

      worker_class = PreviewQa.worker_class!(args[:worker_class])
      job_args = args.extras.map { |value| PreviewQa.cast_argument(value) }

      now = Time.current.to_f
      payload = Sidekiq.dump_json(
        "class" => worker_class.name,
        "args" => job_args,
        "queue" => worker_class.get_sidekiq_options["queue"] || "default",
        "jid" => SecureRandom.hex(12),
        "created_at" => now,
        "enqueued_at" => now,
        "failed_at" => now,
        "retry_count" => 0,
        "error_class" => "RuntimeError",
        "error_message" => "Seeded by preview_qa:seed_dead_job for QA"
      )
      # notify_failure: false skips Sidekiq's death handlers — we want a corpse in the morgue,
      # not a real error-tracker alert.
      Sidekiq::DeadSet.new.kill(payload, notify_failure: false)

      puts "Seeded dead job #{worker_class.name}(#{job_args.map(&:inspect).join(', ')}) into the Sidekiq dead set."
    end

    desc "Run a Sidekiq worker inline (synchronously). Usage: preview_qa:run_worker[RecurringChargeWorker,123]"
    task :run_worker, [:worker_class] => :environment do |_task, args|
      PreviewQa.ensure_not_production!

      worker_class = PreviewQa.worker_class!(args[:worker_class])
      job_args = args.extras.map { |value| PreviewQa.cast_argument(value) }

      puts "Running #{worker_class.name}#perform(#{job_args.map(&:inspect).join(', ')}) inline..."
      worker_class.new.perform(*job_args)
      puts "Done."
    end
  end
end
