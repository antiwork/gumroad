# frozen_string_literal: true

require "spec_helper"

describe SyncStripeBusinessProfileUrlJob do
  let(:user) { create(:user, username: "davidsbuild") }
  let!(:merchant_account) { create(:merchant_account, user:, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}") }
  let(:stripe_url) { "#{PROTOCOL}://#{Subdomain.from_username("antdavidson")}/l/client-report-kit" }

  before do
    allow_any_instance_of(User).to receive(:business_profile_url).and_call_original
    allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do
      Stripe::Account.construct_from(id: merchant_account.charge_processor_merchant_id, business_profile: { url: stripe_url })
    end
    allow(Stripe::Account).to receive(:update)
  end

  it "serializes runs per user and reschedules a run that arrives during another" do
    expect(described_class.sidekiq_options).to include(
      "queue" => :low,
      "lock" => :while_executing,
      "lock_timeout" => 0,
      "on_conflict" => { "server" => :reschedule }
    )
  end

  it "replaces a previous seller subdomain with the current profile URL" do
    described_class.new.perform(user.id)

    expect(Stripe::Account).to have_received(:update).with(
      merchant_account.charge_processor_merchant_id,
      business_profile: { url: user.business_profile_url }
    )
    expect(user.business_profile_url).to eq("#{PROTOCOL}://#{Subdomain.from_username("davidsbuild")}")
  end

  context "when the Stripe URL has no scheme" do
    let(:stripe_url) { "ANTDAVIDSON.#{URI("#{PROTOCOL}://#{ROOT_DOMAIN}").host}" }

    it "still replaces the previous seller subdomain" do
      described_class.new.perform(user.id)

      expect(Stripe::Account).to have_received(:update).with(
        merchant_account.charge_processor_merchant_id,
        business_profile: { url: user.business_profile_url }
      )
    end
  end

  context "when the Stripe URL is already on the current subdomain" do
    let(:stripe_url) { "#{PROTOCOL}://#{Subdomain.from_username("davidsbuild").upcase}/l/client-report-kit" }

    it "does not update the account" do
      described_class.new.perform(user.id)

      expect(Stripe::Account).not_to have_received(:update)
    end
  end

  [
    ["a custom domain", "https://example.com/shop"],
    ["the Gumroad root domain", "#{PROTOCOL}://#{ROOT_DOMAIN}/davidsbuild"],
    ["a reserved Gumroad host", "#{PROTOCOL}://app.#{ROOT_DOMAIN}/davidsbuild"],
    ["a nested Gumroad host", "#{PROTOCOL}://a.antdavidson.#{ROOT_DOMAIN}"],
    ["a blank value", nil],
    ["an unparseable value", "http://bad host.#{ROOT_DOMAIN}"],
  ].each do |description, url|
    context "when the Stripe URL is #{description}" do
      let(:stripe_url) { url }

      it "does not update the account" do
        described_class.new.perform(user.id)

        expect(Stripe::Account).not_to have_received(:update)
      end
    end
  end

  it "does not update the account when Stripe returns no business profile" do
    allow(Stripe::Account).to receive(:retrieve).and_return(Stripe::Account.construct_from(id: merchant_account.charge_processor_merchant_id))

    described_class.new.perform(user.id)

    expect(Stripe::Account).not_to have_received(:update)
  end

  it "converges on the latest username after overlapping renames" do
    stripe_state = { url: "#{PROTOCOL}://#{Subdomain.from_username("davidsbuild")}" }
    allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do
      Stripe::Account.construct_from(id: merchant_account.charge_processor_merchant_id, business_profile: { url: stripe_state[:url] })
    end
    allow(Stripe::Account).to receive(:update) do |_id, params|
      stripe_state[:url] = params[:business_profile][:url]
    end

    user.update!(username: "davidsbuild2")
    user.update!(username: "davidsbuild3")
    described_class.new.perform(user.id)
    described_class.new.perform(user.id)

    expect(stripe_state[:url]).to eq("#{PROTOCOL}://#{Subdomain.from_username("davidsbuild3")}")
    expect(Stripe::Account).to have_received(:update).once

    stripe_state[:url] = "#{PROTOCOL}://#{Subdomain.from_username("davidsbuild2")}"
    described_class.new.perform(user.id)

    expect(stripe_state[:url]).to eq("#{PROTOCOL}://#{Subdomain.from_username("davidsbuild3")}")
  end

  it "reads the seller and the Stripe account from the primary database" do
    primary_scope = false
    expect(ApplicationRecord).to receive(:connected_to).with(role: :writing).and_wrap_original do |original, **options, &block|
      original.call(**options) do
        primary_scope = true
        block.call
      ensure
        primary_scope = false
      end
    end
    expect(User).to receive(:find_by).with(id: user.id).and_wrap_original do |original, **args|
      expect(primary_scope).to eq(true)
      original.call(**args)
    end
    expect_any_instance_of(User).to receive(:stripe_account).and_wrap_original do |original|
      expect(primary_scope).to eq(true)
      original.call
    end

    described_class.new.perform(user.id)

    expect(Stripe::Account).to have_received(:update)
  end

  context "with runtime uniqueness enabled" do
    around do |example|
      SidekiqUniqueJobs.use_config(enabled: true) { example.run }
    end

    def run_through_server_middleware(job)
      SidekiqUniqueJobs::Middleware::Server.new.call(described_class.new, job, "low") do
        described_class.new.perform(*job.fetch("args"))
        yield if block_given?
      end
    end

    it "reschedules a rename that commits during a run, and the later run writes the newest URL" do
      stripe_state = { url: stripe_url }
      allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do
        Stripe::Account.construct_from(id: merchant_account.charge_processor_merchant_id, business_profile: { url: stripe_state[:url] })
      end
      described_class.clear
      user.update!(username: "davidsbuild2")
      first_job = described_class.jobs.sole
      conflicting_run_executed = false

      allow(Stripe::Account).to receive(:update) do |_id, params|
        if described_class.jobs.size == 1
          user.update!(username: "davidsbuild3")
          run_through_server_middleware(described_class.jobs.last) { conflicting_run_executed = true }
        end
        stripe_state[:url] = params[:business_profile][:url]
      end

      run_through_server_middleware(first_job)

      expect(conflicting_run_executed).to eq(false)
      expect(stripe_state[:url]).to eq("#{PROTOCOL}://#{Subdomain.from_username("davidsbuild2")}")
      expect(described_class.jobs.size).to eq(3)
      rescheduled_job = described_class.jobs.last
      expect(rescheduled_job.fetch("args")).to eq([user.id])
      expect(rescheduled_job).to have_key("at")

      run_through_server_middleware(rescheduled_job)

      expect(stripe_state[:url]).to eq("#{PROTOCOL}://#{Subdomain.from_username("davidsbuild3")}")
    end
  end

  it "does nothing for a deleted user" do
    user.update!(deleted_at: Time.current)

    described_class.new.perform(user.id)

    expect(Stripe::Account).not_to have_received(:retrieve)
  end

  it "does nothing when the user no longer exists" do
    expect { described_class.new.perform(-1) }.not_to raise_error
    expect(Stripe::Account).not_to have_received(:retrieve)
  end

  it "does nothing when the Stripe account was deleted" do
    merchant_account.mark_deleted!

    described_class.new.perform(user.id)

    expect(Stripe::Account).not_to have_received(:retrieve)
  end

  it "does nothing when the seller only has a Stripe Connect account" do
    merchant_account.mark_deleted!
    create(:merchant_account_stripe_connect, user:)

    described_class.new.perform(user.id)

    expect(Stripe::Account).not_to have_received(:retrieve)
  end

  it "logs and stops when Stripe rejects the read" do
    allow(Stripe::Account).to receive(:retrieve).and_raise(Stripe::InvalidRequestError.new("No such account", "account"))
    allow(Rails.logger).to receive(:info)

    expect { described_class.new.perform(user.id) }.not_to raise_error
    expect(Rails.logger).to have_received(:info).with(/skipped user #{user.id}: Stripe::InvalidRequestError/)
  end

  it "logs and stops when the platform lost access to the account" do
    allow(Stripe::Account).to receive(:update).and_raise(Stripe::PermissionError.new("No access"))
    allow(Rails.logger).to receive(:info)

    expect { described_class.new.perform(user.id) }.not_to raise_error
    expect(Rails.logger).to have_received(:info).with(/skipped user #{user.id}: Stripe::PermissionError/)
  end

  it "raises transient Stripe errors so Sidekiq retries" do
    allow(Stripe::Account).to receive(:update).and_raise(Stripe::RateLimitError.new("Too many requests"))

    expect { described_class.new.perform(user.id) }.to raise_error(Stripe::RateLimitError)
  end
end
