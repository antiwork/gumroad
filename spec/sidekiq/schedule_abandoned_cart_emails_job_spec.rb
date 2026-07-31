# frozen_string_literal: true

require "spec_helper"

describe ScheduleAbandonedCartEmailsJob do
  describe "#perform" do
    let(:seller1) { create(:user) }
    let!(:seller1_payment) { create(:payment_completed, user: seller1) }
    let!(:seller1_product1) { create(:product, user: seller1) }
    let!(:seller1_product2) { create(:product, user: seller1) }
    let(:seller1_product2_variant_category) { create(:variant_category, link: seller1_product2) }
    let!(:seller1_product2_variant1) { create(:variant, variant_category: seller1_product2_variant_category) }
    let!(:seller1_product2_variant2) { create(:variant, variant_category: seller1_product2_variant_category) }
    let!(:seller1_abandoned_cart_workflow) { create(:abandoned_cart_workflow, seller: seller1, published_at: 1.day.ago, bought_products: [seller1_product1.unique_permalink], bought_variants: [seller1_product2_variant1.external_id]) }
    let(:seller2) { create(:user) }
    let!(:seller2_payment) { create(:payment_completed, user: seller2) }
    let!(:seller2_product1) { create(:product, user: seller2) }
    let!(:seller2_product2) { create(:product, user: seller2) }
    let!(:seller2_abandoned_cart_workflow) { create(:abandoned_cart_workflow, seller: seller2, published_at: 1.day.ago, bought_products: [seller2_product1.unique_permalink]) }

    context "when there are no abandoned carts" do
      it "does not schedule any emails" do
        create(:cart)
        expect { described_class.new.perform }.not_to have_enqueued_mail(CustomerMailer, :abandoned_cart)
      end
    end

    context "when there are abandoned carts" do
      context "when there are no matching abandoned cart workflows" do
        it "does not schedule any emails" do
          cart = create(:cart, updated_at: 2.days.ago)
          create(:cart_product, cart:, product: seller1_product1)
          create(:cart_product, cart:)
          seller1_abandoned_cart_workflow.unpublish!

          expect { described_class.new.perform }.not_to have_enqueued_mail(CustomerMailer, :abandoned_cart)
        end
      end

      context "when there are matching abandoned cart workflows" do
        let(:cart1) { create(:cart) }
        let!(:cart1_product1) { create(:cart_product, cart: cart1, product: seller1_product1) }
        let!(:cart1_product2) { create(:cart_product, cart: cart1, product: seller1_product2, option: seller1_product2_variant1) }
        let!(:cart1_product3) { create(:cart_product, cart: cart1, product: seller2_product2) }
        let(:cart2) { create(:cart) }
        let!(:cart2_product1) { create(:cart_product, cart: cart2, product: seller2_product1) }
        let!(:cart2_product2) { create(:cart_product, cart: cart2, product: seller1_product2, option: seller1_product2_variant2) }
        let(:cart3) { create(:cart) }
        let!(:cart3_product1) { create(:cart_product, cart: cart3, product: seller1_product2) }
        let(:guest_cart1) { create(:cart, :guest, email: "guest1@example.com") }
        let!(:guest_cart1_product1) { create(:cart_product, cart: guest_cart1, product: seller1_product1) }
        let!(:guest_cart1_product2) { create(:cart_product, cart: guest_cart1, product: seller1_product2, option: seller1_product2_variant1) }
        let(:guest_cart2) { create(:cart, :guest, email: "") } # ignores this guest cart due to absence of email
        let!(:guest_cart2_product1) { create(:cart_product, cart: guest_cart2, product: seller2_product1) }
        let(:guest_cart3) { create(:cart, :guest, email: "guest3@example.com") }
        let!(:guest_cart3_product1) { create(:cart_product, cart: guest_cart3, product: seller1_product2) }
        let!(:guest_cart4) { create(:cart, :guest, email: "guest4@example.com") }

        before do
          cart1.update!(updated_at: 2.days.ago)
          cart2.update!(updated_at: 25.hours.ago)
          cart3.update!(updated_at: 21.hours.ago)
          guest_cart1.update!(updated_at: 2.days.ago)
          guest_cart2.update!(updated_at: 25.hours.ago)
          guest_cart3.update!(updated_at: 21.hours.ago)
          guest_cart4.update!(updated_at: 2.days.ago)
        end

        it "schedules emails for the matching abandoned carts belonging to both logged-in users and guest carts" do
          expect do
            described_class.new.perform
          end.to have_enqueued_mail(CustomerMailer, :abandoned_cart).exactly(3).times
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart1.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart2.id, { seller2_abandoned_cart_workflow.id => [seller2_product1.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(guest_cart1.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id] }.stringify_keys)
        end

        it "schedules the same emails when every cart id crosses a scan batch boundary" do
          # The abandoned-cart scan walks each day's window in id-ordered keyset batches
          # (gumroad-private#1198). Shrinking the batch size to 1 forces every cart onto its
          # own batch, proving the batched walk finds exactly the carts the unbatched scan did.
          stub_const("#{described_class}::SCAN_BATCH_SIZE", 1)

          expect do
            described_class.new.perform
          end.to have_enqueued_mail(CustomerMailer, :abandoned_cart).exactly(3).times
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart1.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart2.id, { seller2_abandoned_cart_workflow.id => [seller2_product1.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(guest_cart1.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id] }.stringify_keys)
        end
      end

      context "when there are multiple matching abandoned cart workflows for a cart" do
        let(:cart) { create(:cart) }
        let!(:cart_product1) { create(:cart_product, cart: cart, product: seller1_product1) }
        let!(:cart_product2) { create(:cart_product, cart: cart, product: seller1_product2, option: seller1_product2_variant1) }
        let!(:cart_product3) { create(:cart_product, cart: cart, product: seller2_product1) }
        let!(:cart_product4) { create(:cart_product, cart: cart, product: seller2_product2) }
        let(:guest_cart) { create(:cart, :guest, email: "guest@example.com") }
        let!(:guest_cart_product1) { create(:cart_product, cart: guest_cart, product: seller1_product1) }
        let!(:guest_cart_product2) { create(:cart_product, cart: guest_cart, product: seller1_product2, option: seller1_product2_variant1) }
        let!(:guest_cart_product3) { create(:cart_product, cart: guest_cart, product: seller2_product1) }
        let!(:guest_cart_product4) { create(:cart_product, cart: guest_cart, product: seller2_product2) }

        before do
          cart.update!(updated_at: 2.days.ago)
          guest_cart.update!(updated_at: 2.days.ago)
        end

        it "schedules only one email for each of the corresponding carts" do
          expect do
            described_class.new.perform
          end.to have_enqueued_mail(CustomerMailer, :abandoned_cart).exactly(2).times
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(cart.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id], seller2_abandoned_cart_workflow.id => [seller2_product1.id] }.stringify_keys)
            .and have_enqueued_mail(CustomerMailer, :abandoned_cart).with(guest_cart.id, { seller1_abandoned_cart_workflow.id => [seller1_product1.id, seller1_product2.id], seller2_abandoned_cart_workflow.id => [seller2_product1.id] }.stringify_keys)
        end
      end
    end

    context "when seller is not eligible for abandoned cart workflows" do
      let(:cart) { create(:cart) }
      let!(:cart_product) { create(:cart_product, cart: cart, product: seller1_product1) }
      let(:guest_cart) { create(:cart, :guest, email: "guest@example.com") }
      let!(:guest_cart_product) { create(:cart_product, cart: guest_cart, product: seller1_product1) }

      before do
        cart.update!(updated_at: 2.days.ago)
        guest_cart.update!(updated_at: 2.days.ago)
        allow_any_instance_of(User).to receive(:eligible_for_abandoned_cart_workflows?).and_return(false)
      end

      it "does not schedule any abandoned cart emails" do
        expect do
          described_class.new.perform
        end.not_to have_enqueued_mail(CustomerMailer, :abandoned_cart)
      end
    end
  end

  describe "retries-exhausted alerting" do
    it "reports to Sentry when retries are exhausted" do
      # The job failed silently every day for 3.5 months (gumroad-private#1198) because
      # dead-set failures produced no signal; this locks in the explicit alert.
      exception = WithMaxExecutionTime::QueryTimeoutError.new("maximum statement execution time exceeded")
      expect(ErrorNotifier).to receive(:notify).with(
        a_string_including("ScheduleAbandonedCartEmailsJob exhausted retries"),
        hash_including(exception_class: "WithMaxExecutionTime::QueryTimeoutError", exception_message: exception.message)
      )

      described_class.sidekiq_retries_exhausted_block.call(
        { "class" => described_class.name, "args" => [], "enqueued_at" => Time.current.to_f },
        exception
      )
    end
  end

  describe "lock configuration" do
    # A SIGKILL leaves the `until_executed` digest behind, and this job's digest is constant
    # because it takes no arguments — so with no expiry a single strand mutes it forever
    # (gumroad-private#1576). Both bounds matter, so assert the invariants rather than the literal.
    it "bounds its until_executed lock with a TTL that outlasts an attempt but not the schedule" do
      opts = described_class.sidekiq_options

      expect(opts["lock"].to_sym).to eq(:until_executed)
      expect(opts["lock_ttl"]).to eq(described_class::LOCK_TTL.to_i)
      expect(opts["lock_ttl"]).to be > described_class::ATTEMPT_TIME_BUDGET.to_i
      expect(opts["lock_ttl"]).to be < 1.day.to_i
    end

    # The lock only prevents concurrency while the attempt holding it is still alive, so the
    # attempt must be the shorter of the two bounds. SCAN_TIME_BUDGET caps one statement, not
    # the attempt, hence the separate ceiling.
    it "keeps the attempt budget under the lock TTL and above a single statement budget" do
      expect(described_class::ATTEMPT_TIME_BUDGET).to be > described_class::SCAN_TIME_BUDGET
      expect(described_class::ATTEMPT_TIME_BUDGET).to be < described_class::LOCK_TTL
    end

    # Ordering alone is not enough, and headroom between the constants is not the guarantee it
    # looks like: the TTL is anchored at acquire, which for a first attempt is enqueue time, so any
    # fixed gap is just a bet on :low queue latency. The real bound is read from the live lock —
    # see the "lock-derived deadline" examples — and the margin is what that read holds back.
    it "keeps the safety margin smaller than the attempt budget it is subtracted from" do
      expect(described_class::LOCK_SAFETY_MARGIN).to be_positive
      expect(described_class::LOCK_SAFETY_MARGIN).to be < described_class::ATTEMPT_TIME_BUDGET
    end
  end

  describe "lock-derived deadline" do
    let(:job) { described_class.new }
    let(:digest) { "uniquejobs:abandoned-cart-probe" }

    before do
      allow(SidekiqUniqueJobs::Job).to receive(:prepare) { |item| item["lock_digest"] = digest }
    end

    # `and_yield` would yield but return nil, so the block's value never reaches the caller —
    # which reads exactly like a PTTL of nil and silently exercises the fallback instead.
    def stub_pttl(value)
      conn = instance_double(Redis)
      allow(conn).to receive(:pttl).with(digest).and_return(value)
      allow(Sidekiq).to receive(:redis) { |&block| block.call(conn) }
    end

    # The hazard Greptile proved against real Redis: `lock_ttl` starts at enqueue, and the server
    # reuses that lock without refreshing it, so a long :low-queue delay leaves less lock life than
    # ATTEMPT_TIME_BUDGET. Trusting the constant would run the tail of the attempt unlocked, and
    # the next daily enqueue could then take the same digest and email carts twice.
    it "ends the attempt inside the lock when queue delay left less life than the budget" do
      stub_pttl(6.hours.in_milliseconds)

      travel_to Time.current do
        expect(job.send(:attempt_deadline)).to eq(Time.current + 6.hours - described_class::LOCK_SAFETY_MARGIN)
      end
    end

    it "still honours the attempt budget when the lock has more life than the budget" do
      stub_pttl(23.hours.in_milliseconds)

      travel_to Time.current do
        expect(job.send(:attempt_deadline)).to eq(Time.current + described_class::ATTEMPT_TIME_BUDGET)
      end
    end

    # A digest with no expiry is the orphaned lock of gumroad-private#1576. It cannot expire
    # mid-run, so there is nothing to clamp to and the constant is the correct ceiling. `-1` is
    # Redis's no-expiry answer and `-2` its no-key answer (uniqueness disabled, as in test).
    [-1, -2].each do |pttl|
      it "falls back to the attempt budget when PTTL returns #{pttl}" do
        stub_pttl(pttl)

        travel_to Time.current do
          expect(job.send(:attempt_deadline)).to eq(Time.current + described_class::ATTEMPT_TIME_BUDGET)
        end
      end
    end

    # Reading the TTL is a tightening, not a dependency: a Redis hiccup must not take down the
    # day's abandoned-cart emails platform-wide, which is the exact failure gumroad-private#1198
    # was about. All four classes are needed — Sidekiq 7 talks redis-client, so neither
    # RedisClient::Error nor the pool's checkout timeout is a Redis::BaseError.
    [
      [Redis::CannotConnectError, "no connection"],
      [RedisClient::ConnectionError, "connection reset"],
      [ConnectionPool::TimeoutError, "waited 5 sec"],
      [SidekiqUniqueJobs::UniqueJobsError, "lock unavailable"],
    ].each do |error_class, message|
      it "falls back to the attempt budget when the lock read raises #{error_class}" do
        allow(Sidekiq).to receive(:redis).and_raise(error_class, message)

        travel_to Time.current do
          expect(job.send(:attempt_deadline)).to eq(Time.current + described_class::ATTEMPT_TIME_BUDGET)
        end
      end
    end

    # A retry can be handed a lock with almost nothing left. There is no safe amount of work then,
    # so the attempt must decline rather than start work it will finish unlocked — and it must say
    # why, or this looks like an instant unexplained failure in Sidekiq.
    it "declines the attempt and alerts when less lock life remains than the safety margin" do
      stub_pttl((described_class::LOCK_SAFETY_MARGIN - 5.minutes).in_milliseconds)

      expect(ErrorNotifier).to receive(:notify).with(
        a_string_including("too little unique-lock life left to run safely"),
        hash_including(lock_safety_margin: described_class::LOCK_SAFETY_MARGIN.inspect)
      )

      travel_to Time.current do
        expect(job.send(:attempt_deadline)).to be <= Time.current
      end
    end
  end

  describe "attempt time budget" do
    let(:seller) { create(:user) }
    let!(:seller_payment) { create(:payment_completed, user: seller) }
    let!(:product) { create(:product, user: seller) }
    let!(:workflow) { create(:abandoned_cart_workflow, seller:, published_at: 1.day.ago, bought_products: [product.unique_permalink]) }
    let(:cart) { create(:cart) }
    let!(:cart_product) { create(:cart_product, cart:, product:) }

    before { cart.update!(updated_at: 2.days.ago) }

    it "aborts rather than running past the point where its unique lock can expire" do
      # An attempt that outlives LOCK_TTL lets the next day's enqueue take the same digest and
      # run concurrently; the sent_abandoned_cart_emails dedupe is a check-then-write with no
      # unique index, so two live copies could email one cart twice. Fail instead.
      # The first read sets the deadline, so only later reads advance past it.
      started_at = Time.current
      reads = 0
      allow(Time).to receive(:current) do
        reads += 1
        reads == 1 ? started_at : started_at + described_class::ATTEMPT_TIME_BUDGET + 1.minute
      end

      expect do
        described_class.new.perform
      end.to raise_error(described_class::AttemptTimeBudgetExceeded, /cannot outlive its unique lock/)
    end

    it "does not abort a run that finishes within the budget" do
      expect { described_class.new.perform }.to have_enqueued_mail(CustomerMailer, :abandoned_cart)
    end

    it "stops before hydrating a scanned batch of carts once the deadline has passed" do
      # The scan and the hydration that follows it are separate unbounded loops over the same
      # platform-scale window, so a check on the scan alone leaves the hydration free to run past
      # the deadline. Cross the deadline as a NON-EMPTY scan returns, so the next check reached is
      # the hydration one rather than the following day window's, and assert nothing is hydrated —
      # `Cart.includes` is only called from the hydration loop.
      job = described_class.new
      allow(job).to receive(:abandoned_cart_ids).and_wrap_original do |original, window|
        original.call(window).tap do |ids|
          travel described_class::ATTEMPT_TIME_BUDGET + 1.minute if ids.any?
        end
      end

      expect(Cart).not_to receive(:includes)

      expect { job.perform }.to raise_error(described_class::AttemptTimeBudgetExceeded)
    end

    it "stops mid-way through the mail enqueue loop instead of raising into a duplicating retry" do
      # The enqueue loop is per-cart and platform-wide, so it can be the part that runs long.
      # It must not raise: sent_abandoned_cart_emails rows are written when the mailer jobs run,
      # not at enqueue time, so a retry would rediscover the carts already enqueued here and
      # email them twice. Stop cleanly, alert, and leave the rest for the next daily run.
      second_cart = create(:cart)
      create(:cart_product, cart: second_cart, product:)
      second_cart.update!(updated_at: 2.days.ago)

      real_mailer = CustomerMailer.method(:abandoned_cart)
      enqueued = 0
      allow(CustomerMailer).to receive(:abandoned_cart) do |*args|
        enqueued += 1
        travel described_class::ATTEMPT_TIME_BUDGET + 1.minute if enqueued == 1
        real_mailer.call(*args)
      end

      expect(ErrorNotifier).to receive(:notify).with(
        a_string_including("stopped mid-enqueue after exceeding its attempt budget"),
        hash_including(carts_enqueued: 1, carts_remaining: 1)
      )

      expect { described_class.new.perform }.not_to raise_error
      expect(enqueued).to eq(1)
    end

    it "enqueues the oldest abandoned carts first so a stop can only defer the rest" do
      # The scan walks day windows newest-first, so the cart closest to aging out of
      # Cart::ABANDONED_IF_UPDATED_AFTER_AGO is discovered LAST. A stop in discovery order would
      # strand exactly the cart that has no window left to be rescanned in tomorrow.
      oldest_cart = create(:cart)
      create(:cart_product, cart: oldest_cart, product:)
      oldest_cart.update!(updated_at: (Cart::ABANDONED_IF_UPDATED_AFTER_AGO.to_i / 1.day.to_i).days.ago + 1.hour)

      enqueued_cart_ids = []
      real_mailer = CustomerMailer.method(:abandoned_cart)
      allow(CustomerMailer).to receive(:abandoned_cart) do |cart_id, *rest|
        enqueued_cart_ids << cart_id
        real_mailer.call(cart_id, *rest)
      end

      described_class.new.perform

      expect(enqueued_cart_ids.first).to eq(oldest_cart.id)
      expect(enqueued_cart_ids).to include(cart.id)
    end

    it "reports zero carts aging out when the stop lands outside the final window" do
      # `carts_remaining` alone cannot tell an operator whether the stop cost anyone their email.
      # Both carts here sit well inside the window, so the deferral is fully recoverable and the
      # alert must say so rather than implying loss.
      second_cart = create(:cart)
      create(:cart_product, cart: second_cart, product:)
      second_cart.update!(updated_at: 3.days.ago)

      real_mailer = CustomerMailer.method(:abandoned_cart)
      enqueued = 0
      allow(CustomerMailer).to receive(:abandoned_cart) do |*args|
        enqueued += 1
        travel described_class::ATTEMPT_TIME_BUDGET + 1.minute if enqueued == 1
        real_mailer.call(*args)
      end

      expect(ErrorNotifier).to receive(:notify).with(
        a_string_including("stopped mid-enqueue"),
        hash_including(carts_enqueued: 1, carts_remaining: 1, carts_aging_out: 0)
      )

      described_class.new.perform
    end
  end
end
