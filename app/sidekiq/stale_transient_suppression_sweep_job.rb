# frozen_string_literal: true

# Nightly sweep that clears STALE, TRANSIENT suppression entries from
# SendGrid's bounce/block lists (gumroad-private#1210): one transient bounce
# otherwise silently blocks every future email to that address. The retry
# pipeline for NEW failures never landed (antiwork/gumroad#6073), so this
# sweep is the only thing clearing the backlog.
class StaleTransientSuppressionSweepJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  # Lists swept. Deliverability lists ONLY — spam_reports and unsubscribes
  # are consent signals and must never be auto-cleared.
  SWEPT_LISTS = [:bounces, :blocks].freeze

  # Entries younger than this may still be inside the condition that caused
  # them. Entries older than the lookback are ancient enough that the
  # user-activity signal (a login since suppression) gets weaker and the list
  # volume gets bigger — bound the scan window instead of paging through years.
  MIN_SUPPRESSION_AGE = 3.days
  LOOKBACK_WINDOW = 60.days

  # Reputation guardrail: the absolute ceiling of clears per nightly run. Split evenly across
  # subusers, so on a heavy night the first subuser in the fixed sweep order can't consume the
  # whole cap and starve the later ones night after night.
  MAX_CLEARS_PER_RUN = 200

  # SendGrid paginates the bounce/block list endpoints via limit/offset
  # query params. PAGE_SIZE is how many entries we request per page;
  # MAX_PAGES_PER_LIST bounds the requests per subuser+list so a
  # surprisingly huge list (mass-bounce incident) or a misbehaving API
  # can't turn one nightly run into an unbounded crawl — anything beyond
  # the bound is picked up on subsequent nights.
  PAGE_SIZE = 500
  MAX_PAGES_PER_LIST = 20

  def perform
    cleared = 0
    # This job has never run against production SendGrid, so a "cleared 0" night must be
    # readable: scanned/transient/active distinguish an empty window from entries that were
    # all permanent from entries whose owners never signed in. Those imply different follow-ups.
    scanned = 0
    transient = 0
    active = 0
    subuser_api_keys = EmailSuppressionManager.subuser_api_keys

    # Split the run cap evenly (see MAX_CLEARS_PER_RUN); the outer max keeps
    # the budget at 1 even if subusers ever outnumber the cap.
    per_subuser_budget = [MAX_CLEARS_PER_RUN / subuser_api_keys.size, 1].max

    subuser_api_keys.each do |subuser, api_key|
      next if api_key.blank?

      subuser_cleared = 0

      SWEPT_LISTS.each do |list|
        break if subuser_cleared >= per_subuser_budget

        candidates(subuser, api_key, list).each do |entry|
          if subuser_cleared >= per_subuser_budget
            log("per-subuser clear budget (#{per_subuser_budget}) reached for #{subuser}, moving on; remaining entries will be considered tomorrow")
            break
          end

          scanned += 1
          transient += 1 if transient_reason?(entry)
          active += 1 if signed_in_since_suppression?(entry)
          next unless clearable?(entry)

          status_code = sendgrid(api_key).client.suppression.public_send(list)._(entry[:email]).delete.status_code
          if (200..299).cover?(status_code.to_i)
            cleared += 1
            subuser_cleared += 1
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

    log("sweep complete: scanned #{scanned} in-window suppression(s), #{transient} transient, #{active} with an owner who signed in since, cleared #{cleared}")
  end

  private
    # Suppression entries in the [LOOKBACK_WINDOW.ago, MIN_SUPPRESSION_AGE.ago]
    # creation window for one subuser+list. SendGrid returns an array of
    # { created:, email:, reason:, status: } hashes, paginated via
    # limit/offset — we collect every page up front (bounded by
    # MAX_PAGES_PER_LIST) so that deleting entries while we iterate can't
    # shift offset-based pagination and skip candidates mid-run.
    def candidates(subuser, api_key, list)
      entries = []
      offset = 0
      exhausted_page_bound = true
      MAX_PAGES_PER_LIST.times do
        page = fetch_page(api_key, list, offset:)
        entries.concat(page.select { |entry| entry.is_a?(Hash) && entry[:email].present? })
        if page.size < PAGE_SIZE
          # A short page means we reached the end of the list.
          exhausted_page_bound = false
          break
        end
        offset += PAGE_SIZE
      end
      if exhausted_page_bound
        # Every allowed page came back full, so the list extends beyond the bound. Whether the
        # unscanned tail is ever reached depends on SendGrid's return order, which this job has
        # not yet observed against the real API — so log it loudly rather than assume it drains.
        log("page bound (#{MAX_PAGES_PER_LIST} pages) reached for #{list} (subuser: #{subuser}); the remainder of the list was NOT scanned this run")
      end
      entries
    end

    # One page of a suppression list. Raises on a non-2xx status or an
    # unexpected body shape (e.g. SendGrid's structured auth/rate-limit error
    # JSON, which arrives without the client raising) so the per-list rescue
    # in #perform notifies ErrorNotifier instead of the failure silently
    # looking like an empty, successfully-fetched list.
    def fetch_page(api_key, list, offset:)
      response = sendgrid(api_key).client.suppression.public_send(list).get(
        query_params: {
          start_time: LOOKBACK_WINDOW.ago.to_i,
          end_time: MIN_SUPPRESSION_AGE.ago.to_i,
          limit: PAGE_SIZE,
          offset:,
        }
      )
      status_code = response.status_code.to_i
      raise "SendGrid #{list} list request failed (status: #{status_code})" unless (200..299).cover?(status_code)

      parsed = response.parsed_body
      raise "Unexpected SendGrid #{list} response shape: #{parsed.class}" unless parsed.is_a?(Array)

      parsed
    end

    def clearable?(entry)
      transient_reason?(entry) && signed_in_since_suppression?(entry)
    end

    def transient_reason?(entry)
      TransientEmailFailureClassifier.new(reason: entry[:reason]).transient?
    end

    # Login activity after the suppression was created is the "user is
    # since active" signal from the issue: the person behind the address
    # demonstrably uses the account, so the one-time delivery failure is
    # almost certainly resolved. Users who never came back stay suppressed.
    def signed_in_since_suppression?(entry)
      suppressed_at = entry[:created] ? Time.zone.at(entry[:created]) : nil
      return false if suppressed_at.nil?
      # MIN_SUPPRESSION_AGE is also the end_time query param; re-check it here so a
      # mishandled param can't clear a suppression that is still fresh enough to recur.
      return false if suppressed_at > MIN_SUPPRESSION_AGE.ago

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
