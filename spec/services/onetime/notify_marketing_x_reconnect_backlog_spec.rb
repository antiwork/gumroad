# frozen_string_literal: true

require "spec_helper"

describe Onetime::NotifyMarketingXReconnectBacklog do
  def stuck_action(seller:, product: nil)
    product ||= create(:product, user: seller)
    create(:marketing_action, user: seller, link: product, copy: "New thing").tap do |action|
      action.approve!
      action.update!(error_code: Marketing::Action::X_WRITE_PERMISSION_MISSING)
    end
  end

  let(:seller) { create(:user, twitter_handle: "edgar", twitter_oauth_token: "tok", twitter_oauth_secret: "sec") }

  it "enqueues one notification per stuck action" do
    action = stuck_action(seller:)

    expect { described_class.process }.to change { SendMarketingXReconnectEmailJob.jobs.size }.by(1)
    expect(SendMarketingXReconnectEmailJob.jobs.last["args"]).to eq([action.id])
  end

  it "mails a seller once even when several of their products are stuck" do
    stuck_action(seller:)
    stuck_action(seller:)

    expect { described_class.process }.to change { SendMarketingXReconnectEmailJob.jobs.size }.by(1)
  end

  # The in-process Set dies with the run, so the seller's other stuck actions have to be
  # closed in the database or a rerun mails them again.
  it "closes the seller's other stuck actions so a rerun does not mail them again" do
    first = stuck_action(seller:)
    second = stuck_action(seller:)

    expect { described_class.process }.to change { SendMarketingXReconnectEmailJob.jobs.size }.by(1)

    expect(second.reload.reconnect_notified_at).to be_present
    expect(first.reload.reconnect_notified_at).to be_nil # claimed by the job it was queued for

    SendMarketingXReconnectEmailJob.drain
    expect { described_class.process }.not_to change { SendMarketingXReconnectEmailJob.jobs.size }
  end

  it "leaves another seller's stuck action eligible" do
    other_seller = create(:user, twitter_handle: "ada", twitter_oauth_token: "t", twitter_oauth_secret: "s")
    stuck_action(seller:)
    other_action = stuck_action(seller: other_seller)

    described_class.process

    expect(other_action.reload.reconnect_notified_at).to be_nil
    expect(SendMarketingXReconnectEmailJob.jobs.map { _1["args"] }).to include([other_action.id])
  end

  it "skips a seller already notified" do
    stuck_action(seller:).update!(reconnect_notified_at: Time.current)

    expect { described_class.process }.not_to change { SendMarketingXReconnectEmailJob.jobs.size }
  end

  it "skips an action that is no longer blocked on write permission" do
    stuck_action(seller:).update!(error_code: nil)

    expect { described_class.process }.not_to change { SendMarketingXReconnectEmailJob.jobs.size }
  end

  it "enqueues nothing on a dry run but still reports the count" do
    stuck_action(seller:)

    result = nil
    expect { result = described_class.process(dry_run: true) }.not_to change { SendMarketingXReconnectEmailJob.jobs.size }
    expect(result[:sellers]).to eq(1)
  end
end
