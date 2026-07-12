# frozen_string_literal: true

# Permanent QA seed tasks for preview apps (https://github.com/antiwork/gumroad/issues/5806).
#
# Before these existed, seeding edge-case state on a preview app (a backdated purchase to force a
# subscription renewal, a card with no e-mandate, a dead Sidekiq job) meant shipping temporary
# param-gated hooks in the PR itself, marked "TEMP: revert before merge" — extra commits, review
# noise, and a real risk of the hook leaking into main. These tasks are reviewed once and reused
# forever instead.
#
# Run them through the preview app's Rails console (see "Deploying to a preview app" in
# docs/deploying.md). The deployment repo's console.sh takes the branch via the BRANCH env var
# and needs -w for a writable connection (these tasks write; the default is a read-only replica):
#
#   cd nomad/staging/deploy_branch && BRANCH=<branch name> ./console.sh -w
#   # then, at the console prompt:
#   system 'bundle exec rake "preview_qa:backdate_purchase[<purchase external_id>]"'
#
# These tasks mutate data, so they only exist where mutating data is safe: preview apps,
# development, and the test suite. Production is obviously off-limits, but so is shared staging
# (staging.gumroad.com) — it runs the same staging Rails env as preview apps and is shared by QA
# and reviewers, so doctoring records there would trample other people's testing. Preview apps
# are told apart from shared staging by ENV["BRANCH_DEPLOYMENT"], the same flag the rest of the
# app uses for per-branch deploys (see config/domain.rb and
# config/initializers/prefix_for_branch_apps_es_index.rb). The guard is intentionally
# belt-and-braces: the whole namespace is skipped when the file loads in a disallowed
# environment, and each task re-checks at run time in case the file is ever loaded by other means.

module PreviewQa
  module_function

  def safe_environment?
    return true if Rails.env.development? || Rails.env.test?
    Rails.env.staging? && ENV["BRANCH_DEPLOYMENT"] == "true"
  end

  def ensure_safe_environment!
    abort "preview_qa tasks mutate data and only run on preview apps, development, or the test suite." unless safe_environment?
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
  #
  # Heads-up: the literal strings "nil" and "null" become Ruby nil, so there is no way to pass
  # those exact strings through to a worker. That trade-off is fine for a QA convenience tool —
  # if a worker ever needs the string "nil", run it from the console instead of this task.
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

if PreviewQa.safe_environment?
  namespace :preview_qa do
    desc "Backdate a purchase's created_at/succeeded_at by N days (default: one billing period + 1 day for subscription purchases) so renewal paths can be exercised"
    task :backdate_purchase, [:purchase_id, :days] => :environment do |_task, args|
      PreviewQa.ensure_safe_environment!

      purchase = PreviewQa.find_record!(Purchase, args[:purchase_id])

      days = args[:days].presence&.to_i
      if days.nil? && purchase.subscription&.recurrence.present?
        # Default to just past the subscription's billing period, which is the common case:
        # make the subscription look overdue so RecurringChargeWorker will actually charge it.
        # The recurrence check matters: a bare subscription without a price/recurrence (possible
        # for hand-built records in dev/test) can't have a billing period computed —
        # Subscription#period would raise — so those need an explicit days argument instead.
        days = (purchase.subscription.period / 1.day).ceil + 1
      end
      abort "Pass a positive number of days (this purchase #{purchase.subscription.present? ? "has a subscription with no recurrence" : "has no subscription"} to derive a billing period from)." if days.nil? || days <= 0

      purchases_to_shift = [purchase]
      if purchase.subscription.present?
        # Backdating only the named purchase is not enough once a subscription has renewal
        # charges: the different "is a renewal due?" code paths don't all look at the same
        # purchase. RecurringChargeWorker's own gate reads the latest successful purchase's
        # created_at, while Subscription#overdue_for_charge? (and the renewal scheduling
        # paths) read the newest succeeded_at across ALL successful, non-refunded charges.
        # A newer sibling charge left untouched would keep the subscription looking
        # not-yet-due to those paths. Shifting every successful charge by the same offset
        # keeps their relative order intact and makes the subscription overdue by every
        # code path.
        purchases_to_shift |= purchase.subscription.purchases.successful.to_a
      end

      offset = days.days
      purchases_to_shift.each do |record|
        # update_columns on purpose: this is a QA time-travel edit, and running the full
        # callback/validation stack against a doctored timestamp is exactly what we don't want.
        record.update_columns(
          created_at: record.created_at - offset,
          succeeded_at: (record.succeeded_at - offset if record.succeeded_at.present?)
        )
      end

      siblings = purchases_to_shift.size - 1
      sibling_note = siblings.positive? ? " (plus #{siblings} other successful charge(s) on its subscription)" : ""
      # Spell out when succeeded_at was untouched, so the output doesn't imply a purchase that
      # never succeeded now has a success timestamp.
      succeeded_at_note = purchase.succeeded_at.present? ? "" : " succeeded_at was nil and stays nil."
      puts "Backdated purchase #{purchase.external_id} (id #{purchase.id})#{sibling_note} by #{days} days.#{succeeded_at_note}"
    end

    desc "Remove the Stripe e-mandate linkage (stripe_setup_intent_id) from the card charged for a subscription, to QA the missing-mandate path for Indian cards"
    task :clear_mandate, [:subscription_id] => :environment do |_task, args|
      PreviewQa.ensure_safe_environment!

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
      PreviewQa.ensure_safe_environment!

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

    desc "Print a read-only snapshot of a subscription for QA verification: renewal timing, the charged card's mandate linkage, and recent purchases with charge ids"
    task :inspect_subscription, [:subscription_id] => :environment do |_task, args|
      PreviewQa.ensure_safe_environment!

      subscription = PreviewQa.find_record!(Subscription, args[:subscription_id])

      puts "Subscription #{subscription.external_id} (id #{subscription.id})"
      puts "  alive?: #{subscription.alive?}"
      puts "  cancelled_at: #{subscription.cancelled_at.inspect}  failed_at: #{subscription.failed_at.inspect}  ended_at: #{subscription.ended_at.inspect}"
      recurrence = subscription.recurrence
      if recurrence.present?
        puts "  recurrence: #{recurrence}  (period: #{(subscription.period / 1.day).round(2)} days)"
        puts "  free_trial_ends_at: #{subscription.free_trial_ends_at.inspect}" if subscription.free_trial_ends_at.present?
        puts "  last successful charge at: #{subscription.last_successful_charge_at.inspect}"
        puts "  end of current period: #{subscription.end_time_of_subscription.inspect}"
        puts "  overdue_for_charge?: #{subscription.overdue_for_charge?}"
      else
        # A subscription without a price/recurrence (possible for bare records in dev/test)
        # can't have its renewal timing computed — Subscription#period would raise. Note it
        # instead of crashing the whole snapshot.
        puts "  recurrence: none (cannot compute renewal timing)"
      end

      credit_card = subscription.credit_card_to_charge
      if credit_card.nil?
        puts "  card to charge: none"
      else
        puts "  card to charge: CreditCard #{credit_card.id} (#{credit_card.card_type} #{credit_card.visual})"
        puts "    stripe_setup_intent_id (e-mandate linkage): #{credit_card.stripe_setup_intent_id.inspect}"
        puts "    stripe_payment_intent_id: #{credit_card.stripe_payment_intent_id.inspect}"
      end

      puts "  recent purchases (newest first):"
      subscription.purchases.order(created_at: :desc).limit(10).each do |record|
        puts "    #{record.external_id} (id #{record.id})  state=#{record.purchase_state}  " \
             "succeeded_at=#{record.succeeded_at.inspect}  charge=#{record.stripe_transaction_id.inspect}  " \
             "#{record.formatted_total_price}"
      end
    end

    desc "Run a Sidekiq worker inline (synchronously). Usage: preview_qa:run_worker[RecurringChargeWorker,123]"
    task :run_worker, [:worker_class] => :environment do |_task, args|
      PreviewQa.ensure_safe_environment!

      worker_class = PreviewQa.worker_class!(args[:worker_class])
      job_args = args.extras.map { |value| PreviewQa.cast_argument(value) }

      puts "Running #{worker_class.name}#perform(#{job_args.map(&:inspect).join(', ')}) inline..."
      worker_class.new.perform(*job_args)
      puts "Done."
    end
  end
end
