# frozen_string_literal: true

require "spec_helper"

describe SweepClosedSellerConnectAccountsJob do
  # Stripe is stubbed at HTTP, so the real SDK parses each response and raises its real error classes.
  let(:seller) { create(:user, deleted_at: Time.current) }
  let!(:merchant_account) { create_candidate(seller) }
  let(:stripe_id) { merchant_account.charge_processor_merchant_id }
  let(:zero_balance) { { available: [{ amount: 0, currency: "usd" }], pending: [{ amount: 0, currency: "usd" }] } }
  before do
    allow(InternalNotificationWorker).to receive(:perform_async) { |_room, _subject, body| @message = body }
    stub_stripe_account(stripe_id)
    stub_stripe_balance(stripe_id)
    stub_stripe_delete(stripe_id)
  end

  def run = described_class.new.perform

  # Not a let: examples that run the job twice read the message in between, and a memoized let keeps the first one.
  attr_reader :message

  def create_candidate(user)
    create(:merchant_account, user:, charge_processor_merchant_id: "acct_sweep_#{SecureRandom.hex(6)}")
  end

  def stripe_endpoint(path) = "#{Stripe.api_base}/v1/#{path}"

  def stripe_response(body, status: 200) = { status:, body: body.to_json, headers: { "Content-Type" => "application/json" } }

  def stripe_error(status:, type: "invalid_request_error", code: nil, message: "No such account")
    stripe_response({ error: { type:, code:, message: }.compact }, status:)
  end

  def stub_stripe_account(id, type: "custom")
    stub_request(:get, stripe_endpoint("accounts/#{id}")).to_return(stripe_response({ id:, object: "account", type: }))
  end

  def stub_stripe_balance(id, body = zero_balance, &during)
    stub_request(:get, stripe_endpoint("balance")).with(headers: { "Stripe-Account" => id }).to_return do
      during&.call
      stripe_response({ object: "balance" }.merge(body))
    end
  end

  def stub_stripe_delete(id, deleted: true)
    stub_request(:delete, stripe_endpoint("accounts/#{id}")).to_return(stripe_response({ id:, object: "account", deleted: }))
  end

  def stripe_delete_request(id = stripe_id) = a_request(:delete, stripe_endpoint("accounts/#{id}"))

  context "with the flag off" do
    it "reports an eligible account and deletes nothing" do
      run

      expect(stripe_delete_request).not_to have_been_made
      expect(merchant_account.reload.charge_processor_deleted_at).to be_nil
      expect(message).to include("Eligible for deletion (flag off, nothing deleted): 1", stripe_id)
    end

    it "reports an account Stripe no longer has without writing to it" do
      stub_request(:get, stripe_endpoint("accounts/#{stripe_id}")).to_return(stripe_error(status: 404, code: "resource_missing"))

      expect { run }.not_to change { merchant_account.reload.attributes }
      expect(message).to include("Eligible for deletion (flag off, nothing deleted): 1", "#{stripe_id} - already gone at Stripe")
    end
  end

  context "with the flag on" do
    before { Feature.activate(:delete_closed_seller_connect_accounts) }
    after { Feature.deactivate(:delete_closed_seller_connect_accounts) }

    it "deletes the account at Stripe and marks the record deleted" do
      run

      expect(stripe_delete_request).to have_been_made.once
      expect(merchant_account.reload).to be_deleted
      expect(merchant_account.charge_processor_deleted_at).to be_present
      expect(message).to include("Deleted: 1", stripe_id, "Skipped: 0")
    end

    it "does not select an already-deleted account on a re-run" do
      run
      run

      expect(a_request(:get, stripe_endpoint("accounts/#{stripe_id}"))).to have_been_made.once
      expect(stripe_delete_request).to have_been_made.once
    end

    it "finishes the local record when the account lookup says Stripe no longer has it" do
      stub_request(:get, stripe_endpoint("accounts/#{stripe_id}")).to_return(stripe_error(status: 404, code: "resource_missing"))

      run

      expect(stripe_delete_request).not_to have_been_made
      expect(merchant_account.reload.charge_processor_deleted_at).to be_present
      expect(message).to include("Deleted: 1")
    end

    {
      "resource_missing from the balance lookup" => :balance,
      "resource_missing from the delete call" => :delete,
    }.each do |name, boundary|
      it "skips and reports #{name} instead of treating the account as gone" do
        error = stripe_error(status: 404, code: "resource_missing", message: "No such resource")
        if boundary == :balance
          stub_request(:get, stripe_endpoint("balance")).to_return(error)
        else
          stub_request(:delete, stripe_endpoint("accounts/#{stripe_id}")).to_return(error)
        end

        run

        expect(merchant_account.reload.charge_processor_deleted_at).to be_nil
        expect(message).to include("Deleted: 0", "Skipped: 1", "Stripe::InvalidRequestError")
      end
    end

    {
      "an invalid request that only says the account does not exist" => { status: 400, message: "Account acct_x does not exist" },
      "a refused lookup that may mean the account does not exist" => { status: 403, type: "invalid_request_error", message: "The provided key does not have access to account 'acct_x' (or that account does not exist)" },
    }.each do |name, error|
      it "skips and reports #{name}" do
        stub_request(:get, stripe_endpoint("accounts/#{stripe_id}")).to_return(stripe_error(**error))

        run

        expect(stripe_delete_request).not_to have_been_made
        expect(merchant_account.reload.charge_processor_deleted_at).to be_nil
        expect(message).to include("Deleted: 0", "Skipped: 1")
      end
    end

    {
      "a non-zero available balance" => [{ available: [{ amount: 5, currency: "usd" }], pending: [{ amount: 0, currency: "usd" }] }, "non-zero Stripe balance"],
      "a non-zero pending balance" => [{ available: [{ amount: 0, currency: "usd" }], pending: [{ amount: 5, currency: "eur" }] }, "non-zero Stripe balance"],
      "a negative balance" => [{ available: [{ amount: -5, currency: "usd" }], pending: [{ amount: 0, currency: "usd" }] }, "non-zero Stripe balance"],
      "an empty available list" => [{ available: [], pending: [{ amount: 0, currency: "usd" }] }, "Stripe balance missing or malformed"],
      "a null pending list" => [{ available: [{ amount: 0, currency: "usd" }], pending: nil }, "Stripe balance missing or malformed"],
      "a missing pending list" => [{ available: [{ amount: 0, currency: "usd" }] }, "Stripe balance missing or malformed"],
      "an entry without an amount" => [{ available: [{ currency: "usd" }], pending: [{ amount: 0, currency: "usd" }] }, "Stripe balance missing or malformed"],
      "a non-integer amount" => [{ available: [{ amount: "0", currency: "usd" }], pending: [{ amount: 0, currency: "usd" }] }, "Stripe balance missing or malformed"],
    }.each do |name, (body, reason)|
      it "skips and reports #{name}" do
        stub_stripe_balance(stripe_id, body)

        run

        expect(stripe_delete_request).not_to have_been_made
        expect(merchant_account.reload.charge_processor_deleted_at).to be_nil
        expect(message).to include("Skipped: 1", "#{stripe_id} - #{reason}")
      end
    end

    it "skips a standard account" do
      stub_stripe_account(stripe_id, type: "standard")

      run

      expect(stripe_delete_request).not_to have_been_made
      expect(message).to include("not custom")
    end

    it "skips a seller with a successful purchase" do
      create(:free_purchase, link: create(:product, user: seller), seller:)

      run

      expect(stripe_delete_request).not_to have_been_made
      expect(message).to include("successful or in-progress purchase")
    end

    it "skips a committed balance transaction not yet applied to a balance" do
      BalanceTransaction.new.tap { |bt| bt.user = seller; bt.merchant_account = merchant_account }
                        .save!(validate: false)

      run

      expect(stripe_delete_request).not_to have_been_made
      expect(message).to include("uncommitted balance transaction")
    end

    it "skips a seller with a payment being processed" do
      create(:payment, user: seller, state: Payment::PROCESSING)

      run

      expect(stripe_delete_request).not_to have_been_made
      expect(message).to include("payment being created or processed")
    end

    context "when a guard changes while the Stripe reads run" do
      {
        "the seller is reopened" => [-> { seller.update_columns(deleted_at: nil) }, "no longer a live candidate"],
        "the account is retired by adoption" => [-> { MerchantAccount.find(merchant_account.id).mark_retired_by_adoption! }, "no longer a live candidate"],
        "a successful purchase lands" => [-> { create(:free_purchase, link: create(:product, user: seller), seller:) }, "successful or in-progress purchase"],
        "a purchase starts" => [-> { create(:purchase_in_progress, link: create(:product, user: seller), seller:) }, "successful or in-progress purchase"],
        "a payment starts" => [-> { create(:payment, user: seller, state: Payment::CREATING) }, "payment being created or processed"],
        "a balance transaction is committed" => [-> { BalanceTransaction.new.tap { |bt| bt.user = seller; bt.merchant_account = merchant_account }.save!(validate: false) }, "uncommitted balance transaction"],
        "an unpaid balance appears" => [-> { create(:balance, user: seller, merchant_account:, state: "unpaid") }, "unsettled balance on this account"],
        "the record moves to another Stripe account" => [-> { MerchantAccount.where(id: merchant_account.id).update_all(charge_processor_merchant_id: "acct_replaced") }, "account changed during the checks"],
      }.each do |name, (change, reason)|
        it "skips and reports when #{name}" do
          stub_stripe_balance(stripe_id) { instance_exec(&change) }
          stub_stripe_delete("acct_replaced")

          run

          expect(stripe_delete_request).not_to have_been_made
          expect(stripe_delete_request("acct_replaced")).not_to have_been_made
          expect(merchant_account.reload.charge_processor_deleted_at).to be_nil
          expect(message).to include("Deleted: 0", "Skipped: 1", reason)
        end
      end
    end

    it "skips and reports an uncertain Stripe read" do
      stub_request(:get, stripe_endpoint("balance")).to_timeout

      run

      expect(stripe_delete_request).not_to have_been_made
      expect(message).to include("Skipped: 1", "Stripe::APIConnectionError")
    end

    it "skips and reports when Stripe does not confirm deletion" do
      stub_stripe_delete(stripe_id, deleted: false)

      run

      expect(merchant_account.reload).not_to be_deleted
      expect(message).to include("Deleted: 0", "Skipped: 1", "did not confirm deletion")
    end

    it "reports a confirmed Stripe deletion whose local update fails apart from both deletions and skips" do
      allow_any_instance_of(MerchantAccount).to receive(:delete_charge_processor_account!).and_raise(ActiveRecord::LockWaitTimeout)

      run

      expect(stripe_delete_request).to have_been_made.once
      expect(merchant_account.reload.charge_processor_deleted_at).to be_nil
      expect(message).to include("Deleted: 0", "Gone at Stripe, local record not updated: 1",
                                 "#{stripe_id} - deleted at Stripe; local update failed: ActiveRecord::LockWaitTimeout", "Skipped: 0")
    end

    it "finishes the local record on the next run after a failed local update" do
      calls = 0
      allow_any_instance_of(MerchantAccount).to receive(:delete_charge_processor_account!).and_wrap_original do |original, **kwargs|
        calls += 1
        raise ActiveRecord::LockWaitTimeout if calls == 1
        original.call(**kwargs)
      end

      run
      stub_request(:get, stripe_endpoint("accounts/#{stripe_id}")).to_return(stripe_error(status: 404, code: "resource_missing"))
      run

      expect(stripe_delete_request).to have_been_made.once
      expect(merchant_account.reload.charge_processor_deleted_at).to be_present
      expect(message).to include("Deleted: 1", "Skipped: 0")
    end

    it "keeps evaluating later accounts and still reports when an already-gone account's local update fails" do
      later = create_candidate(create(:user, deleted_at: Time.current))
      stub_stripe_account(later.charge_processor_merchant_id)
      stub_stripe_balance(later.charge_processor_merchant_id)
      stub_stripe_delete(later.charge_processor_merchant_id)
      stub_request(:get, stripe_endpoint("accounts/#{stripe_id}")).to_return(stripe_error(status: 404, code: "resource_missing"))
      allow_any_instance_of(MerchantAccount).to receive(:delete_charge_processor_account!).and_wrap_original do |original, **kwargs|
        raise ActiveRecord::Deadlocked if original.receiver.id == merchant_account.id
        original.call(**kwargs)
      end

      expect { run }.not_to raise_error

      expect(stripe_delete_request(later.charge_processor_merchant_id)).to have_been_made.once
      expect(later.reload.charge_processor_deleted_at).to be_present
      expect(message).to include("Deleted: 1", later.charge_processor_merchant_id,
                                 "Gone at Stripe, local record not updated: 1",
                                 "#{stripe_id} - already gone at Stripe; local update failed: ActiveRecord::Deadlocked")
    end

    it "re-evaluates a skipped account on the next run" do
      stub_stripe_balance(stripe_id, { available: [{ amount: 5, currency: "usd" }], pending: [{ amount: 0, currency: "usd" }] })
      run
      expect(message).to include("Skipped: 1")

      stub_stripe_balance(stripe_id)
      run

      expect(stripe_delete_request).to have_been_made.once
      expect(message).to include("Deleted: 1")
    end
  end

  it "walks candidates in capped pages and wraps to the start after the last one" do
    stub_const("#{described_class}::MAX_ACCOUNTS_PER_RUN", 2)
    others = Array.new(2) { create_candidate(create(:user, deleted_at: Time.current)) }
    others.each { |other| stub_stripe_account(other.charge_processor_merchant_id); stub_stripe_balance(other.charge_processor_merchant_id) }
    first, second, third = [merchant_account, *others].sort_by(&:id).map(&:charge_processor_merchant_id)
    lookups = ->(id) { a_request(:get, stripe_endpoint("accounts/#{id}")) }

    run
    expect(message).to include(first, second, "More accounts remain")
    expect(message).not_to include(third)
    expect(lookups.call(third)).not_to have_been_made

    run
    expect(message).to include(third)
    expect(message).not_to include(first, "More accounts remain")

    run
    expect(lookups.call(first)).to have_been_made.twice
    expect(lookups.call(third)).to have_been_made.once
  end

  it "ignores open sellers, Connect (standard) accounts and PayPal accounts" do
    open_seller = create(:user)
    create(:merchant_account, user: open_seller, charge_processor_merchant_id: "acct_open_#{SecureRandom.hex(4)}")
    create(:merchant_account_stripe_connect, user: seller)
    create(:merchant_account_paypal, user: seller)
    merchant_account.update!(charge_processor_deleted_at: Time.current)

    run

    expect(a_request(:get, %r{\A#{Regexp.escape(stripe_endpoint("accounts/"))}})).not_to have_been_made
    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end
end
