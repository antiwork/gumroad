# frozen_string_literal: true

require "spec_helper"

describe "preview_qa rake tasks" do
  before(:all) do
    # Load the task file once for the whole suite. The tasks are only defined for
    # non-production environments, which is what the test environment is. Guard against
    # a double load: re-loading a .rake file appends a second action to each task, which
    # would make every invocation run twice.
    unless Rake::Task.task_defined?("preview_qa:backdate_purchase")
      Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
      load Rails.root.join("lib", "tasks", "preview_qa.rake")
    end
  end

  def run_task(name, *args)
    task = Rake::Task[name]
    # Rake memoizes task execution; re-enable so each example can invoke it fresh.
    task.reenable
    task.invoke(*args)
  end

  # The credit_card factory goes through CreditCard.create(chargeable), which makes real
  # Stripe HTTP calls (and would therefore need VCR cassettes). These specs only care about
  # json_data plumbing, so build the record directly instead.
  def build_saved_credit_card(json_data: nil)
    card = CreditCard.new(
      card_type: "visa",
      visual: "**** **** **** 4062",
      stripe_fingerprint: "preview_qa_fingerprint",
      stripe_customer_id: "cus_preview_qa",
      expiry_month: 12,
      expiry_year: 5.years.from_now.year,
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      json_data:
    )
    card.save!
    card
  end

  describe "the environment guard" do
    let(:all_tasks) do
      %w[
        preview_qa:backdate_purchase
        preview_qa:clear_mandate
        preview_qa:seed_dead_job
        preview_qa:run_worker
        preview_qa:inspect_subscription
      ]
    end

    # Make Rails.env report the given environment instead of "test", so we can exercise
    # the guard as it would behave on each deployed environment.
    def stub_rails_env(env)
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new(env))
    end

    it "aborts every task before doing any work when running in production" do
      stub_rails_env("production")

      all_tasks.each do |task_name|
        expect do
          run_task(task_name, "irrelevant")
        end.to raise_error(SystemExit), "expected #{task_name} to abort in production"
      end
    end

    it "aborts every task on shared staging (staging Rails env without the preview-app flag)" do
      stub_rails_env("staging")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("BRANCH_DEPLOYMENT").and_return(nil)

      all_tasks.each do |task_name|
        expect do
          run_task(task_name, "irrelevant")
        end.to raise_error(SystemExit), "expected #{task_name} to abort on shared staging"
      end
    end

    it "allows tasks on preview apps (staging Rails env with BRANCH_DEPLOYMENT set)" do
      stub_rails_env("staging")
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("BRANCH_DEPLOYMENT").and_return("true")

      expect(PreviewQa.safe_environment?).to be(true)
    end
  end

  describe "preview_qa:backdate_purchase" do
    it "backdates a subscription purchase by one billing period plus a day by default" do
      purchase = create(:membership_purchase)

      expect do
        run_task("preview_qa:backdate_purchase", purchase.external_id)
      end.to output(/Backdated purchase #{purchase.external_id}/).to_stdout

      expected_days = (purchase.subscription.period / 1.day).ceil + 1
      purchase.reload
      expect(purchase.created_at).to be_within(1.minute).of(expected_days.days.ago)
      expect(purchase.succeeded_at).to be_within(1.minute).of(expected_days.days.ago)
    end

    it "shifts every successful charge on the subscription, so the renewal is due by every code path" do
      original_purchase = create(:membership_purchase)
      subscription = original_purchase.subscription
      renewal_purchase = create(:membership_purchase, link: subscription.link, subscription:, is_original_subscription_purchase: false)

      expect do
        run_task("preview_qa:backdate_purchase", original_purchase.external_id)
      end.to output(/plus 1 other successful charge/).to_stdout

      expected_days = (subscription.period / 1.day).ceil + 1
      expect(original_purchase.reload.succeeded_at).to be_within(1.minute).of(expected_days.days.ago)
      expect(renewal_purchase.reload.succeeded_at).to be_within(1.minute).of(expected_days.days.ago)
      # This is the point of shifting siblings: overdue_for_charge? keys off the newest
      # succeeded_at across all successful charges, not the one purchase named on the task.
      expect(subscription.reload.overdue_for_charge?).to be(true)
    end

    it "backdates by an explicit number of days and accepts a numeric database id" do
      purchase = create(:free_purchase)

      expect do
        run_task("preview_qa:backdate_purchase", purchase.id.to_s, "45")
      end.to output(/by 45 days/).to_stdout

      purchase.reload
      expect(purchase.created_at).to be_within(1.minute).of(45.days.ago)
    end

    it "leaves succeeded_at nil for purchases that never succeeded" do
      purchase = create(:purchase_in_progress, succeeded_at: nil)

      expect do
        run_task("preview_qa:backdate_purchase", purchase.external_id, "10")
      end.to output(/succeeded_at was nil and stays nil/).to_stdout

      expect(purchase.reload.succeeded_at).to be_nil
    end

    it "aborts when no day count is given and the purchase has no subscription" do
      purchase = create(:free_purchase)

      expect do
        run_task("preview_qa:backdate_purchase", purchase.external_id)
      end.to raise_error(SystemExit)
    end

    it "aborts when the purchase cannot be found" do
      expect do
        run_task("preview_qa:backdate_purchase", "nonexistent")
      end.to raise_error(SystemExit)
    end
  end

  describe "preview_qa:clear_mandate" do
    it "removes the stripe_setup_intent_id from the subscription's chargeable card" do
      credit_card = build_saved_credit_card(json_data: { stripe_setup_intent_id: "seti_123", stripe_payment_intent_id: "pi_456" })
      subscription = create(:subscription, credit_card:)

      expect do
        run_task("preview_qa:clear_mandate", subscription.external_id)
      end.to output(/Cleared stripe_setup_intent_id "seti_123"/).to_stdout

      credit_card.reload
      expect(credit_card.stripe_setup_intent_id).to be_nil
      # Only the mandate linkage should be touched; other json_data keys must survive.
      expect(credit_card.stripe_payment_intent_id).to eq("pi_456")
    end

    it "is a no-op with a helpful message when the card has no mandate linkage" do
      credit_card = build_saved_credit_card
      subscription = create(:subscription, credit_card:)

      expect do
        run_task("preview_qa:clear_mandate", subscription.external_id)
      end.to output(/has no stripe_setup_intent_id; nothing to clear/).to_stdout
    end

    it "aborts when the subscription has no chargeable credit card" do
      subscription = create(:subscription, user: nil, credit_card: nil)

      expect do
        run_task("preview_qa:clear_mandate", subscription.external_id)
      end.to raise_error(SystemExit)
    end
  end

  describe "preview_qa:seed_dead_job" do
    it "adds a job for the given worker to the Sidekiq dead set without notifying death handlers" do
      expect_any_instance_of(Sidekiq::DeadSet).to receive(:kill) do |_dead_set, payload, opts|
        job = Sidekiq.load_json(payload)
        expect(job["class"]).to eq("RecurringChargeWorker")
        expect(job["args"]).to eq([123, true])
        expect(job["error_message"]).to match(/Seeded by preview_qa:seed_dead_job/)
        expect(opts).to eq(notify_failure: false)
      end

      expect do
        run_task("preview_qa:seed_dead_job", "RecurringChargeWorker", "123", "true")
      end.to output(/Seeded dead job RecurringChargeWorker\(123, true\)/).to_stdout
    end

    it "aborts for a class that is not a Sidekiq worker" do
      expect do
        run_task("preview_qa:seed_dead_job", "User")
      end.to raise_error(SystemExit)
    end

    it "aborts for an unknown class name" do
      expect do
        run_task("preview_qa:seed_dead_job", "TotallyNotARealWorker")
      end.to raise_error(SystemExit)
    end
  end

  describe "preview_qa:inspect_subscription" do
    def capture_stdout
      original = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end

    it "prints renewal timing, the card's mandate linkage, and recent purchases without mutating anything" do
      credit_card = build_saved_credit_card(json_data: { stripe_setup_intent_id: "seti_123" })
      purchase = create(:membership_purchase)
      subscription = purchase.subscription
      subscription.update!(credit_card:)

      output = capture_stdout { run_task("preview_qa:inspect_subscription", subscription.external_id) }

      expect(output).to include("Subscription #{subscription.external_id}")
      expect(output).to include("overdue_for_charge?: #{subscription.reload.overdue_for_charge?}")
      expect(output).to include('stripe_setup_intent_id (e-mandate linkage): "seti_123"')
      expect(output).to include(purchase.external_id)
    end

    it "reports when the subscription has no chargeable card instead of aborting" do
      subscription = create(:subscription, user: nil, credit_card: nil)

      expect do
        run_task("preview_qa:inspect_subscription", subscription.external_id)
      end.to output(/card to charge: none/).to_stdout
    end

    it "aborts when the subscription cannot be found" do
      expect do
        run_task("preview_qa:inspect_subscription", "nonexistent")
      end.to raise_error(SystemExit)
    end
  end

  describe "preview_qa:run_worker" do
    it "runs the worker inline with type-cast arguments" do
      expect_any_instance_of(RecurringChargeWorker).to receive(:perform).with(42, false)

      expect do
        run_task("preview_qa:run_worker", "RecurringChargeWorker", "42", "false")
      end.to output(/Running RecurringChargeWorker#perform\(42, false\) inline/).to_stdout
    end

    it "aborts for a class that is not a Sidekiq worker" do
      expect do
        run_task("preview_qa:run_worker", "Purchase", "1")
      end.to raise_error(SystemExit)
    end

    it "aborts when no worker class is given" do
      expect do
        run_task("preview_qa:run_worker")
      end.to raise_error(SystemExit)
    end
  end
end
