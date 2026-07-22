# frozen_string_literal: true

# Nightly sweep that clears STALE, TRANSIENT suppression entries from
# SendGrid's bounce/block lists (see gumroad-private#1210).
#
# Why: the ops runbook calls stale transient bounces "the #1 cause of the
# false 'I get nothing' report". A one-off failure (receiving server timed
# out, greylisting, DNS still propagating on a brand-new domain) lands the
# address on a suppression list, and SendGrid then silently drops every
# future email to it — long after the underlying condition resolved. The
# event-driven retry pipeline (TransientEmailFailureRetryScheduler) handles
# NEW failures; this sweep cleans up the backlog and anything the retries
# didn't cover.
#
# An entry is cleared only when ALL of these hold:
#   1. Its recorded reason classifies as :transient (fail-closed classifier —
#      hard bounces and unrecognized reasons are left alone).
#   2. It is older than MIN_SUPPRESSION_AGE (young entries belong to the
#      retry pipeline; clearing them here would fight its attempt caps).
#   3. The address belongs to a user who signed in AFTER the suppression was
#      created — live login activity is strong evidence the mailbox's owner
#      is real and active, so the transient failure has almost certainly
#      resolved.
#
# Guardrails: only the bounce/block deliverability lists are touched — never
# spam_reports or unsubscribes (consent surfaces). The run is bounded by
# MAX_CLEARS_PER_RUN so a mass-bounce incident can't turn into a mass-clear
# incident, and every clear is logged individually.
class StaleTransientSuppressionSweepJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  # Lists swept. Deliverability lists ONLY — spam_reports and unsubscribes
  # are consent signals and must never be auto-cleared.
  SWEPT_LISTS = [:bounces, :blocks].freeze

  # Entries younger than this are the retry pipeline's responsibility;
  # entries older than the lookback are ancient enough that the user-activity
  # signal (a login since suppression) gets weaker and the list volume gets
  # bigger — bound the scan window instead of paging through years.
  MIN_SUPPRESSION_AGE = 3.days
  LOOKBACK_WINDOW = 60.days

  # Reputation guardrail: the absolute ceiling of clears per nightly run.
  MAX_CLEARS_PER_RUN = 200

  def perform
    cleared = 0

    EmailSuppressionManager.subuser_api_keys.each do |subuser, api_key|
      next if api_key.blank?

      SWEPT_LISTS.each do |list|
        candidates(api_key, list).each do |entry|
          if cleared >= MAX_CLEARS_PER_RUN
            log("clear cap (#{MAX_CLEARS_PER_RUN}) reached, stopping; remaining entries will be considered tomorrow")
            return
          end

          next unless clearable?(entry)

          status_code = sendgrid(api_key).client.suppression.public_send(list)._(entry[:email]).delete.status_code
          if (200..299).cover?(status_code.to_i)
            cleared += 1
            log("cleared stale transient #{list} suppression for #{entry[:email]} (subuser: #{subuser}, suppressed: #{Time.zone.at(entry[:created]).iso8601}, reason: #{entry[:reason].inspect})")
          else
            log("failed to clear #{list} suppression for #{entry[:email]} (subuser: #{subuser}, status: #{status_code})")
          end
        end
      rescue => e
        # One subuser/list failing (auth, rate limit) shouldn't abort the
        # whole sweep — record and move on to the next list.
        ErrorNotifier.notify(e, subuser:, list:)
        log("error sweeping #{list} for subuser #{subuser}: #{e.message}")
      end
    end

    log("sweep complete: cleared #{cleared} stale transient suppression(s)")
  end

  private
    # Suppression entries in the [LOOKBACK_WINDOW.ago, MIN_SUPPRESSION_AGE.ago]
    # creation window for one subuser+list. SendGrid returns an array of
    # { created:, email:, reason:, status: } hashes.
    def candidates(api_key, list)
      response = sendgrid(api_key).client.suppression.public_send(list).get(
        query_params: {
          start_time: LOOKBACK_WINDOW.ago.to_i,
          end_time: MIN_SUPPRESSION_AGE.ago.to_i,
        }
      )
      parsed = response.parsed_body
      return [] unless parsed.is_a?(Array)

      parsed.select { |entry| entry.is_a?(Hash) && entry[:email].present? }
    end

    def clearable?(entry)
      return false unless TransientEmailFailureClassifier.new(event_type: nil, reason: entry[:reason]).transient?

      # Login activity after the suppression was created is the "user is
      # since active" signal from the issue: the person behind the address
      # demonstrably uses the account, so the one-time delivery failure is
      # almost certainly resolved. Users who never came back stay suppressed.
      suppressed_at = entry[:created] ? Time.zone.at(entry[:created]) : nil
      return false if suppressed_at.nil?

      user = User.alive.by_email(entry[:email]).last
      return false if user.nil?

      user.current_sign_in_at.present? && user.current_sign_in_at > suppressed_at
    end

    def sendgrid(api_key)
      SendGrid::API.new(api_key:)
    end

    def log(message)
      Rails.logger.info("[StaleTransientSuppressionSweep] #{message}")
    end
end
