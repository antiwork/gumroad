# frozen_string_literal: true

# Which weekday each payout rail is actually paid out on.
#
# Payouts are not one weekly run: `config/sidekiq_schedule.yml` splits them into several
# `PerformPayoutsUpToDelayDaysAgoWorker` jobs that fire on different weekdays, and each job
# only pays the sellers belonging to its rail (a list of bank account types, PayPal, or
# Stripe Connect). A seller on a Philippine bank account is therefore paid on Tuesday, one
# on a UK bank account on Wednesday, a US bank account on Thursday, and PayPal on Friday.
#
# That mapping used to exist only inside the cron file, so anything that wanted to tell a
# seller WHEN they would be paid had to assume a single weekly cycle and got it wrong for
# every non-Friday rail (see User::PayoutSchedule). This class makes the mapping readable by
# the app, deriving it from the very same schedule file that fires the jobs so the two can't
# drift: add a bank account type to a cron bucket and the projected date follows
# automatically.
class PayoutRailSchedule
  PAYOUT_WORKER_CLASS = "PerformPayoutsUpToDelayDaysAgoWorker"

  # Rails that have no entry in the schedule fall back to Friday: that is the weekday of the
  # catch-all PayPal and Stripe Connect runs, and it is what every seller was projected onto
  # before this mapping existed, so an unmapped rail behaves exactly as it did before.
  DEFAULT_WEEKDAY = :friday

  WEEKDAYS = %i[sunday monday tuesday wednesday thursday friday saturday].freeze

  class << self
    # Weekday the given bank account type is paid out on, e.g. "UkBankAccount" => :wednesday.
    def weekday_for_bank_account_type(bank_account_type)
      schedule[:bank_account_types][bank_account_type] || DEFAULT_WEEKDAY
    end

    def paypal_weekday
      schedule[:paypal] || DEFAULT_WEEKDAY
    end

    # Sellers paying with their own Stripe account (Stripe Connect) are paid by the job that
    # passes no bank account types, since that run is narrowed to Connect accounts in SQL.
    def stripe_connect_weekday
      schedule[:stripe_connect] || DEFAULT_WEEKDAY
    end

    def reset_cache!
      @schedule = nil
    end

    private
      def schedule
        @schedule ||= build_schedule
      end

      def build_schedule
        result = { bank_account_types: {}, paypal: nil, stripe_connect: nil }

        YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml")).each_value do |entry|
          next unless entry["class"] == PAYOUT_WORKER_CLASS

          weekday = weekday_from_cron(entry["cron"])
          next if weekday.nil?

          # The worker takes (processor_type, bank_account_types = nil). A bare string means
          # "every seller on this processor"; an array means the processor plus the list of
          # bank account types this run is responsible for.
          processor_type, bank_account_types = Array(entry["args"])

          case processor_type
          when PayoutProcessorType::PAYPAL
            result[:paypal] = weekday
          when PayoutProcessorType::STRIPE
            if bank_account_types.present?
              Array(bank_account_types).each { |type| result[:bank_account_types][type] = weekday }
            else
              result[:stripe_connect] = weekday
            end
          end
        end

        result
      end

      # The schedule's cron expressions are in UTC and may carry a trailing comment, e.g.
      # `0 10 * * 2 # UTC 10:00 TUE`. A payout job runs on exactly one weekday; if a cron
      # ever names several, take the earliest so we never promise a seller a date that is
      # later than a run they are actually included in.
      def weekday_from_cron(cron)
        return nil if cron.blank?

        parsed = Fugit::Cron.parse("#{cron.sub(/#.*/, '').strip} UTC")
        weekday_numbers = parsed&.weekdays&.flatten&.compact
        return nil if weekday_numbers.blank?

        WEEKDAYS[weekday_numbers.min % WEEKDAYS.size]
      end
  end
end
