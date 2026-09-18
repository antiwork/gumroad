# frozen_string_literal: true

require "spec_helper"

describe Onetime::NotifyMarketingXReconnectBacklog do
  include ActiveJob::TestHelper
  def stuck_action(seller:, product: nil)
    product ||= create(:product, user: seller)
    create(:marketing_action, user: seller, link: product, copy: "New thing").tap do |action|
      action.approve!
      action.update!(error_code: Marketing::Action::X_WRITE_PERMISSION_MISSING)
    end
  end

  def drain_reconnect_emails
    EnqueueMarketingXReconnectEmailJob.drain
    SendMarketingXReconnectEmailJob.drain
  end

  let(:seller) { create(:user, twitter_handle: "edgar", twitter_oauth_token: "tok", twitter_oauth_secret: "sec") }

  it "enqueues one notification per stuck seller" do
    stuck_action(seller:)

    expect { described_class.process }.to change { EnqueueMarketingXReconnectEmailJob.jobs.size }.by(1)
    expect(EnqueueMarketingXReconnectEmailJob.jobs.last["args"]).to eq([seller.id])
  end

  it "mails a seller once even when several of their products are stuck" do
    stuck_action(seller:)
    stuck_action(seller:)

    expect { described_class.process }.to change { EnqueueMarketingXReconnectEmailJob.jobs.size }.by(1)
  end

  it "marks the seller's stuck actions after delivery so a rerun does not mail them again" do
    first = stuck_action(seller:)
    second = stuck_action(seller:)

    expect { described_class.process }.to change { EnqueueMarketingXReconnectEmailJob.jobs.size }.by(1)

    expect(second.reload.reconnect_notified_at).to be_nil
    expect(first.reload.reconnect_notified_at).to be_nil

    expect { drain_reconnect_emails }.to change { ActionMailer::Base.deliveries.size }.by(1)
    expect(first.reload.reconnect_notified_at).to be_present
    expect(second.reload.reconnect_notified_at).to be_present
    expect { described_class.process }.not_to change { EnqueueMarketingXReconnectEmailJob.jobs.size }
  end

  it "reselects a stuck product when the selected action is cancelled before delivery" do
    first = stuck_action(seller:)
    second = stuck_action(seller:)
    described_class.process
    first.cancel!

    expect do
      perform_enqueued_jobs { drain_reconnect_emails }
    end.to change { ActionMailer::Base.deliveries.size }.by(1)

    expect(ActionMailer::Base.deliveries.last.body.encoded).to include("/products/#{second.link.unique_permalink}/edit/share")
    expect(first.reload.reconnect_notified_at).to be_nil
    expect(second.reload.reconnect_notified_at).to be_present
    expect { described_class.process }.not_to change { EnqueueMarketingXReconnectEmailJob.jobs.size }
  end

  # The queued job is keyed to the seller, so it still covers the sibling and no second
  # pass is needed to reach them.
  it "keeps siblings recoverable when the selected action is deleted" do
    first = stuck_action(seller:)
    second = stuck_action(seller:)
    described_class.process
    first.destroy!

    expect do
      perform_enqueued_jobs { drain_reconnect_emails }
    end.to change { ActionMailer::Base.deliveries.size }.by(1)

    expect(second.reload.reconnect_notified_at).to be_present
  end

  it "leaves every action pending when enqueue fails" do
    first = stuck_action(seller:)
    second = stuck_action(seller:)
    allow(EnqueueMarketingXReconnectEmailJob).to receive(:perform_async).and_raise(Redis::CannotConnectError)

    expect { described_class.process }.to raise_error(Redis::CannotConnectError)
    expect(first.reload.reconnect_notified_at).to be_nil
    expect(second.reload.reconnect_notified_at).to be_nil

    allow(EnqueueMarketingXReconnectEmailJob).to receive(:perform_async).and_call_original
    first.cancel!
    described_class.process
    expect do
      perform_enqueued_jobs { drain_reconnect_emails }
    end.to change { ActionMailer::Base.deliveries.size }.by(1)
  end

  it "retries delivery without consuming siblings" do
    first = stuck_action(seller:)
    second = stuck_action(seller:)
    described_class.process
    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_raise(Net::ReadTimeout)

    expect { drain_reconnect_emails }.to raise_error(Net::ReadTimeout)
    expect(first.reload.reconnect_notified_at).to be_nil
    expect(second.reload.reconnect_notified_at).to be_nil

    allow_any_instance_of(Mail::TestMailer).to receive(:deliver!).and_call_original
    first.cancel!
    described_class.process
    expect do
      drain_reconnect_emails
    end.to change { ActionMailer::Base.deliveries.size }.by(1)
    expect(second.reload.reconnect_notified_at).to be_present
  end

  it "deduplicates pending runs across batches even if the first selected action changes" do
    first = stuck_action(seller:)
    second = stuck_action(seller:)
    described_class.process(batch_size: 1)
    first.cancel!
    described_class.process(batch_size: 1)

    expect do
      perform_enqueued_jobs { drain_reconnect_emails }
    end.to change { ActionMailer::Base.deliveries.size }.by(1)
    expect(second.reload.reconnect_notified_at).to be_present
    expect { described_class.process }.not_to change { EnqueueMarketingXReconnectEmailJob.jobs.size }
  end

  it "leaves another seller's stuck action eligible" do
    other_seller = create(:user, twitter_handle: "ada", twitter_oauth_token: "t", twitter_oauth_secret: "s")
    stuck_action(seller:)
    other_action = stuck_action(seller: other_seller)

    described_class.process

    expect(other_action.reload.reconnect_notified_at).to be_nil
    expect(EnqueueMarketingXReconnectEmailJob.jobs.map { _1["args"] }).to include([other_seller.id])
  end

  it "skips a seller already notified" do
    stuck_action(seller:).update!(reconnect_notified_at: Time.current)

    expect { described_class.process }.not_to change { EnqueueMarketingXReconnectEmailJob.jobs.size }
  end

  it "skips an action that is no longer blocked on write permission" do
    stuck_action(seller:).update!(error_code: nil)

    expect { described_class.process }.not_to change { EnqueueMarketingXReconnectEmailJob.jobs.size }
  end

  it "enqueues nothing on a dry run but still reports the count" do
    first = stuck_action(seller:)
    second = stuck_action(seller:)

    result = nil
    expect { result = described_class.process(dry_run: true) }.not_to change { EnqueueMarketingXReconnectEmailJob.jobs.size }
    expect(result[:sellers]).to eq(1)
    expect(first.reload.reconnect_notified_at).to be_nil
    expect(second.reload.reconnect_notified_at).to be_nil
  end
end
