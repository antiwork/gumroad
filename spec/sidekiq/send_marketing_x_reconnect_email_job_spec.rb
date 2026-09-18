# frozen_string_literal: true

require "spec_helper"

describe SendMarketingXReconnectEmailJob do
  let(:seller) { create(:user, twitter_handle: "edgar", twitter_oauth_token: "tok", twitter_oauth_secret: "sec") }
  let(:product) { create(:product, user: seller) }
  let(:action) do
    create(:marketing_action, user: seller, link: product, copy: "New thing").tap do |a|
      a.approve!
      a.update!(error_code: Marketing::Action::X_WRITE_PERMISSION_MISSING)
    end
  end

  it "mails the seller and records that it did" do
    expect do
      described_class.new.perform(action.id)
    end.to have_enqueued_mail(CreatorMailer, :marketing_x_reconnect).with(marketing_action_id: action.id)

    expect(action.reload.reconnect_notified_at).to be_present
  end

  it "mails once even when the seller retries and fails again" do
    described_class.new.perform(action.id)
    first_notified_at = action.reload.reconnect_notified_at

    expect do
      described_class.new.perform(action.id)
    end.not_to have_enqueued_mail(CreatorMailer, :marketing_x_reconnect)

    expect(action.reload.reconnect_notified_at).to eq(first_notified_at)
  end

  it "does not mail once the action has left the reconnect state" do
    action.update!(error_code: nil)

    expect do
      described_class.new.perform(action.id)
    end.not_to have_enqueued_mail(CreatorMailer, :marketing_x_reconnect)

    expect(action.reload.reconnect_notified_at).to be_nil
  end

  it "does not mail for a posted action" do
    action.queue!
    action.mark_posted!

    expect do
      described_class.new.perform(action.id)
    end.not_to have_enqueued_mail(CreatorMailer, :marketing_x_reconnect)
  end

  # Recording before the enqueue would strand the seller as notified and unmailed if the
  # worker died in between.
  it "records nothing when the delivery cannot be enqueued" do
    mail = double
    allow(mail).to receive(:deliver_later).and_raise(Redis::CannotConnectError)
    allow(CreatorMailer).to receive(:marketing_x_reconnect).and_return(mail)

    expect { described_class.new.perform(action.id) }.to raise_error(Redis::CannotConnectError)
    expect(action.reload.reconnect_notified_at).to be_nil
  end

  it "mails on the retry that follows a failed enqueue" do
    mail = double
    allow(mail).to receive(:deliver_later).and_raise(Redis::CannotConnectError)
    allow(CreatorMailer).to receive(:marketing_x_reconnect).and_return(mail)
    expect { described_class.new.perform(action.id) }.to raise_error(Redis::CannotConnectError)

    allow(CreatorMailer).to receive(:marketing_x_reconnect).and_call_original
    expect do
      described_class.new.perform(action.id)
    end.to have_enqueued_mail(CreatorMailer, :marketing_x_reconnect).with(marketing_action_id: action.id)

    expect(action.reload.reconnect_notified_at).to be_present
  end

  it "ignores an action that no longer exists" do
    expect { described_class.new.perform(-1) }.not_to raise_error
  end
end
