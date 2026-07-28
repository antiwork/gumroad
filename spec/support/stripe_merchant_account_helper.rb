# frozen_string_literal: true

module StripeMerchantAccountHelper
  # How long we are willing to wait for Stripe to finish verifying a freshly
  # created test account. Unchanged from when this helper polled on a fixed
  # 10-second interval (12 attempts x 10s): a genuinely slow account still gets
  # the full two minutes before we give up.
  CAPABILITIES_WAIT_BUDGET = 120

  # When we are really talking to Stripe we poll on an exponential backoff
  # instead of a fixed 10 seconds, so an account that verifies in under a second
  # costs us about a second rather than ten. Two properties matter here:
  #
  #   * The two-minute budget above is unchanged, so slow accounts are still
  #     waited out rather than failed fast.
  #   * The number of Stripe requests inside that budget goes DOWN, not up:
  #     1 + 2 + 4 + 8 + 16 + 32 + 32 + 25 seconds is eight polls where the fixed
  #     interval made twelve. Every spec shard in CI shares one Stripe test
  #     account, so simply shortening the fixed interval would multiply the
  #     request rate against that shared account and bring back the rate-limit
  #     errors we had to make non-fatal in #6489.
  INITIAL_CAPABILITIES_POLL_INTERVAL = 1
  MAX_CAPABILITIES_POLL_INTERVAL = 32

  # The cassette path replays recorded responses and never sleeps, so it is
  # bounded by an attempt count rather than by elapsed time.
  MAX_ATTEMPTS_TO_WAIT_FOR_CAPABILITIES = 12

  module_function

  def create_verified_stripe_account(params = {})
    default_params = DefaultAccountParamsBuilderService.new(country: params[:country]).perform
    stripe_account = Stripe::Account.create(default_params.deep_merge(params))

    ensure_charges_enabled(stripe_account.id)

    stripe_account
  end

  # Ensures that all requested capabilities for the account are active.
  # Each capability can have its own requirements (account fields to be provided and verified).
  def ensure_charges_enabled(stripe_account_id)
    stripe_account = Stripe::Account.retrieve(stripe_account_id)
    return if stripe_account.charges_enabled

    # We assume that all required fields have been provided.
    # Stripe takes a few seconds to verify a test account (this delay seems to
    # only happen for US-based accounts), so poll until it does.
    deadline = monotonic_now + CAPABILITIES_WAIT_BUDGET
    interval = INITIAL_CAPABILITIES_POLL_INTERVAL
    attempts = 0

    until stripe_account.charges_enabled
      if hitting_stripe_api?
        remaining = deadline - monotonic_now
        break if remaining <= 0

        # Never sleep past the budget: the last nap is trimmed so the total wait
        # is CAPABILITIES_WAIT_BUDGET, exactly as the old fixed loop was.
        nap = [interval, remaining].min
        sleep nap
        log_capabilities_wait("VCR off: sleeping for #{format('%g', nap.round(2))} seconds")
        interval = [interval * 2, MAX_CAPABILITIES_POLL_INTERVAL].min
      else
        # Fast-forward through the recorded cassette to save time.
        break if attempts >= MAX_ATTEMPTS_TO_WAIT_FOR_CAPABILITIES

        log_capabilities_wait("VCR on: fast-forwarding through the recorded cassette", VCR.current_cassette&.name)
      end

      attempts += 1
      stripe_account = Stripe::Account.retrieve(stripe_account_id)
    end

    raise "Timed out waiting for charges to become enabled for account. Check the required fields." unless stripe_account.charges_enabled
  end

  def upload_verification_document(stripe_account_id)
    stripe_person = Stripe::Account.list_persons(stripe_account_id)["data"].last

    Stripe::Account.update_person(
      stripe_account_id,
      stripe_person.id,
      verification: {
        document: {
          front: "file_identity_document_success"
        },
      })
  end

  # True when this spec run reaches the real Stripe API rather than replaying a
  # cassette, which is the only case where waiting costs wall-clock time.
  def hitting_stripe_api?
    !VCR.turned_on? || VCR.current_cassette&.recording? || false
  end

  # Kept for debugging flaky specs: prints which example is waiting and why.
  def log_capabilities_wait(message, cassette_name = nil)
    puts "*" * 100
    puts RSpec.current_example&.full_description
    puts RSpec.current_example&.location
    puts message
    puts cassette_name if cassette_name
    puts "*" * 100
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
