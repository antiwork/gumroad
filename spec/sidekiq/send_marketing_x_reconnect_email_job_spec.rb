# frozen_string_literal: true

require "spec_helper"

describe SendMarketingXReconnectEmailJob do
  let(:seller) { create(:user, twitter_handle: "edgar", twitter_oauth_token: "tok", twitter_oauth_secret: "sec") }
  let(:product) { create(:product, user: seller) }
  # Eager: the job takes a seller id, so nothing in the example body would create this.
  let!(:action) do
    create(:marketing_action, user: seller, link: product, copy: "New thing").tap do |a|
      a.approve!
      a.update!(error_code: Marketing::Action::X_WRITE_PERMISSION_MISSING)
    end
  end

  it "mails the seller and records that it did" do
    expect do
      described_class.new.perform(seller.id)
    end.to change { ActionMailer::Base.deliveries.size }.by(1)

    expect(action.reload.reconnect_notified_at).to be_present
  end

  it "mails once even when the seller retries and fails again" do
    described_class.new.perform(seller.id)
    first_notified_at = action.reload.reconnect_notified_at

    expect do
      described_class.new.perform(seller.id)
    end.not_to change { ActionMailer::Base.deliveries.size }

    expect(action.reload.reconnect_notified_at).to eq(first_notified_at)
  end

  it "does not mail once the action has left the reconnect state" do
    action.update!(error_code: nil)

    expect do
      described_class.new.perform(seller.id)
    end.not_to change { ActionMailer::Base.deliveries.size }

    expect(action.reload.reconnect_notified_at).to be_nil
  end

  it "does not mail for a posted action" do
    action.queue!
    action.mark_posted!

    expect do
      described_class.new.perform(seller.id)
    end.not_to change { ActionMailer::Base.deliveries.size }
  end

  it "leaves the notice pending when delivery fails and sends it on retry" do
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_raise(Net::ReadTimeout)

    expect { described_class.new.perform(seller.id) }.to raise_error(Net::ReadTimeout)
    expect(action.reload.reconnect_notified_at).to be_nil

    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_call_original
    expect do
      described_class.new.perform(seller.id)
    end.to change { ActionMailer::Base.deliveries.size }.by(1)

    expect(action.reload.reconnect_notified_at).to be_present
  end

  it "leaves interrupted delivery recoverable" do
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_raise(Sidekiq::Shutdown)

    expect { described_class.new.perform(seller.id) }.to raise_error(Sidekiq::Shutdown)
    expect(action.reload.reconnect_notified_at).to be_nil

    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_call_original
    expect do
      described_class.new.perform(seller.id)
    end.to change { ActionMailer::Base.deliveries.size }.by(1)
  end

  it "does not consume an action when the mailer skips an invalid recipient" do
    seller.update_columns(email: "invalid", unconfirmed_email: nil)

    expect do
      described_class.new.perform(seller.id)
    end.not_to change { ActionMailer::Base.deliveries.size }

    expect(action.reload.reconnect_notified_at).to be_nil
  end

  # Delivery now happens outside the lock, so the eligible set is re-read afterwards.
  it "does not consume a sibling product cancelled while the mail was being delivered" do
    sibling = create(:marketing_action, user: seller, link: create(:product, user: seller), copy: "Other").tap do |a|
      a.approve!
      a.update!(error_code: Marketing::Action::X_WRITE_PERMISSION_MISSING)
    end
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_wrap_original do |original, *args|
      sibling.cancel!
      original.call(*args)
    end

    expect { described_class.new.perform(seller.id) }.to change { ActionMailer::Base.deliveries.size }.by(1)

    expect(action.reload.reconnect_notified_at).to be_present
    expect(sibling.reload.reconnect_notified_at).to be_nil
  end

  # Its own enqueue is dropped by this job's uniqueness lock, so the re-scan is the only
  # thing that keeps it from sitting eligible with nothing queued to pick it up.
  it "covers a product that fails while the mail is being delivered" do
    latecomer = nil
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_wrap_original do |original, *args|
      latecomer ||= create(:marketing_action, user: seller, link: create(:product, user: seller), copy: "Late").tap do |a|
        a.approve!
        a.update!(error_code: Marketing::Action::X_WRITE_PERMISSION_MISSING)
      end
      original.call(*args)
    end

    expect { described_class.new.perform(seller.id) }.to change { ActionMailer::Base.deliveries.size }.by(1)

    expect(action.reload.reconnect_notified_at).to be_present
    expect(latecomer.reload.reconnect_notified_at).to be_present
  end

  it "ignores a seller that no longer exists" do
    expect { described_class.new.perform(-1) }.not_to raise_error
  end
end
