# frozen_string_literal: true

module StripeMerchantAccountHelper
  # How long we are willing to wait for Stripe to finish verifying a freshly
  # created test account, in seconds. Unchanged from when this helper polled on
  # a fixed 10-second interval (12 attempts x 10s): a genuinely slow account
  # still gets the full two minutes before we give up.
  #
  # Note the budget now includes the time spent in the Account.retrieve requests
  # themselves, where the old loop counted only its own sleeping. In practice
  # that is a couple of seconds of the two minutes.
  CAPABILITIES_WAIT_BUDGET = 120

  # How long to wait before each successive poll when we are really talking to
  # Stripe. The old loop slept a flat 10 seconds, so an account that verified in
  # under a second still cost ten; the suite spent about 7.5 minutes per CI run
  # sitting in these sleeps. The first gap here is 1 second, which is what buys
  # that time back.
  #
  # Everything after the first gap lands back on the old 10-second grid
  # (polls at t = 1, 10, 20, 30, 40, 50, 70, 90, 120) and only gets sparser in
  # the tail, past the ~30 seconds the old comment here described as the typical
  # US-account delay. Deliberately NOT an exponential backoff: every CI shard
  # shares ONE Stripe test account, so request volume against it — not just wall
  # clock — is a constraint, and polling faster or on a coarser grid would bring
  # back the rate-limit errors #6489 had to make non-fatal. Staying on the grid
  # means this schedule costs at most ONE extra request than the old loop at any
  # verification time (the 1-second probe), never notices a verification later
  # than the old loop would have inside the first 50 seconds, and makes fewer
  # requests overall in the worst case — 10 rather than 13 for an account that
  # never verifies at all.
  CAPABILITIES_POLL_SCHEDULE = [1, 9, 10, 10, 10, 10, 20, 20, 30].freeze

  # The cassette path replays recorded responses and never sleeps, so it is
  # bounded by an attempt count rather than by elapsed time. Also used by the
  # Minitest suite's own replay loop in test/models/purchase_test.rb.
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

    # We assume that all required fields have been provided. Stripe still takes
    # a few seconds to verify a test account (this delay seems to only happen
    # for US-based accounts), so poll until it does.
    deadline = monotonic_now + CAPABILITIES_WAIT_BUDGET
    attempts = 0

    until stripe_account.charges_enabled
      if hitting_stripe_api?
        remaining = deadline - monotonic_now
        break if remaining <= 0

        # The schedule sums to exactly CAPABILITIES_WAIT_BUDGET, so this `min`
        # is normally a no-op — it is here so that editing the schedule can
        # never accidentally extend the two-minute ceiling.
        nap = [CAPABILITIES_POLL_SCHEDULE.fetch(attempts, CAPABILITIES_POLL_SCHEDULE.last), remaining].min
        sleep nap
        log_capabilities_wait("VCR off: sleeping for #{format('%g', nap.round(2))} seconds")
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
