# frozen_string_literal: true

require "spec_helper"

describe Marketing::Recommendations do
  let(:seller) { create(:user, twitter_handle: "edgar", twitter_oauth_token: "tok", twitter_oauth_secret: "sec") }
  let(:product) do
    create(:product, user: seller, name: "Gumstein Letters",
                     description: "<p>Ten years of letters from the Andes. Second sentence nobody needs. Third.</p>")
  end

  subject(:channels) { described_class.new(product:, seller:).call }

  it "lists every channel with X and email live and the rest as coming soon" do
    expect(channels.map { _1.slice(:channel, :live) }).to eq([
                                                               { channel: "x", live: true },
                                                               { channel: "instagram", live: false },
                                                               { channel: "youtube", live: false },
                                                               { channel: "tiktok", live: false },
                                                               { channel: "email", live: true },
                                                             ])
    expect(channels.find { _1[:channel] == "tiktok" }.keys).to match_array(%i[channel label live])
  end

  it "builds the X action from the product name and first description sentence with a launch UtmLink" do
    x = channels.first
    action = x[:action]
    expect(action.copy).to eq("Gumstein Letters: Ten years of letters from the Andes.")
    expect(action.utm_link).to have_attributes(utm_source: "x", utm_medium: "social", utm_campaign: "launch",
                                               target_resource_id: product.id, seller:)
    expect(action.post_text.length).to be <= Marketing::Action::MAX_POST_LENGTH
    expect(x).to include(connected: true, handle: "edgar")
    expect(x[:intent_url]).to include(CGI.escape(action.utm_link.short_url))
  end

  it "does not invent copy beyond the product's own text" do
    product.update!(description: "")
    action = channels.first[:action]
    expect(action.copy).to eq("Gumstein Letters")
    expect(action.copy).not_to match(/limited|hurry|only|today|love/i)
  end

  it "truncates long names on a word boundary within the copy budget" do
    product.update!(name: "word " * 50, description: "tail " * 60)
    copy = channels.first[:action].copy
    expect(copy.length).to be <= Marketing::Action::MAX_COPY_LENGTH
    expect(copy).to end_with("...")
  end

  it "reuses the open action and its UtmLink on repeat calls" do
    first = channels.first[:action]
    second = described_class.new(product:, seller:).call.first[:action]
    expect(second).to eq(first)
    expect(second.as_json[:idempotency_key]).to eq(first.as_json[:idempotency_key])
    expect(UtmLink.where(seller:, utm_source: "x", utm_campaign: "launch").count).to eq(1)
  end

  it "reports X as not connected when the seller has no user token" do
    seller.update!(twitter_oauth_token: nil)
    expect(channels.first).to include(connected: false)
  end

  it "keeps serving the same action, with its reason, after a connection that cannot write" do
    action = channels.first[:action]
    action.approve!
    WebMock.stub_request(:post, Marketing::XApi::TWEETS_URL).to_return(status: 403, body: "{}", headers: { "Content-Type" => "application/json" })
    Marketing::Channels::X.new(action).call

    reloaded = described_class.new(product:, seller:).call.first[:action]

    expect(reloaded).to eq(action)
    expect(reloaded.error_code).to eq("x_write_permission_missing")
    expect(reloaded).not_to be_terminal
  end

  describe "the email channel" do
    let(:email_entry) { channels.find { _1[:channel] == "email" } }

    context "for a seller who can send emails" do
      before do
        create(:payment_completed, user: seller)
        allow(seller).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
      end

      it "drafts one launch email to the audience, excluding the new product's buyers" do
        expect { channels }.to change { seller.installments.alive.count }.by(1)

        draft = Installment.find_by_external_id(email_entry[:draft][:id])
        expect(draft).to have_attributes(
          installment_type: Installment::AUDIENCE_TYPE,
          not_bought_products: [product.unique_permalink],
          name: "Gumstein Letters",
          published_at: nil,
        )
        expect(draft.message).to include("Gumstein Letters: Ten years of letters from the Andes.")
        expect(draft.ready_to_publish?).to eq(false)
        expect(draft.blasts).to be_empty
      end

      it "reports the draft's state, per-segment counts and the Emails link" do
        expect(email_entry).to include(eligible: true, blocked_reason: nil, live: true, label: "Email")
        expect(email_entry[:counts]).to eq(customers: 0, followers: 0, affiliates: 0, total: 0)
        expect(email_entry[:draft]).to include(subject: "Gumstein Letters", state: "draft")
        expect(email_entry[:draft][:edit_url]).to include("/emails/#{email_entry[:draft][:id]}/edit")
      end

      it "tags the draft's link as email rather than reusing the X post's" do
        expect(email_entry[:action].utm_link).to have_attributes(
          utm_source: "email", utm_medium: "email", utm_campaign: "launch"
        )
        expect(email_entry[:action].utm_link).not_to eq(channels.first[:action].utm_link)
        expect(UtmLink.where(seller:, utm_campaign: "launch").count).to eq(2)
      end

      it "reports a deleted draft as declined and does not build another" do
        Installment.find_by_external_id(email_entry[:draft][:id]).mark_deleted!

        again = described_class.new(product:, seller:).call.find { _1[:channel] == "email" }

        expect(again[:draft]).to be_nil
        expect(again[:declined]).to eq(true)
        expect(Installment.where(seller:, installment_type: Installment::AUDIENCE_TYPE).count).to eq(1)
      end

      it "reuses the same draft and action on repeat calls" do
        first = email_entry[:draft]
        again = described_class.new(product:, seller:).call.find { _1[:channel] == "email" }

        expect(again[:draft]).to eq(first)
        expect(seller.installments.alive.count).to eq(1)
        expect(Marketing::Action.where(user: seller, channel: "email").count).to eq(1)
      end

      it "records the seller's own scheduling as the action being approved" do
        Installment.find_by_external_id(email_entry[:draft][:id]).update!(ready_to_publish: true)

        again = described_class.new(product:, seller:).call.find { _1[:channel] == "email" }

        expect(again[:action]).to be_approved
        expect(again[:draft]).to include(state: "scheduled")
      end
    end

    context "for a seller who cannot send emails yet" do
      it "reports the reason, blocks the action and drafts nothing" do
        expect { channels }.not_to change { Installment.count }

        expect(email_entry[:eligible]).to eq(false)
        expect(email_entry[:blocked_reason]).to eq("You can email your customers once you've made at least $100 in sales and received a payout.")
        expect(email_entry[:requirements]).to eq(sales_cents_total: seller.sales_cents_total,
                                                 min_sales_cents_required: Installment::MINIMUM_SALES_CENTS_VALUE)
        expect(email_entry[:draft]).to be_nil
        expect(email_entry[:action]).to have_attributes(status: "blocked", error_code: "email_eligibility_not_met")
      end

      it "keeps one blocked action row, then clears it when the seller qualifies" do
        email_entry
        described_class.new(product:, seller:).call
        expect(Marketing::Action.where(user: seller, channel: "email").count).to eq(1)

        create(:payment_completed, user: seller)
        allow(seller).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
        recovered = described_class.new(product:, seller:).call.find { _1[:channel] == "email" }

        expect(recovered[:eligible]).to eq(true)
        expect(recovered[:action]).to have_attributes(status: "recommended", error_code: nil)
        expect(recovered[:draft]).to be_present
      end

      it "says the account is suspended instead of quoting the sales bar" do
        allow(seller).to receive(:suspended?).and_return(true)

        expect(email_entry[:blocked_reason]).to eq("Your account can't send emails while it's suspended.")
      end
    end
  end
  describe "email publication and delivery state" do
    let(:draft) { Marketing::LaunchEmail.new(product:, seller:, utm_link: nil).installment }

    before do
      create(:payment_completed, user: seller)
      allow(seller).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    end

    def email_state
      described_class.new(product:, seller:).call.find { _1[:channel] == "email" }.dig(:draft, :state)
    end

    it "reports a real profile-only publication as published, never sent" do
      service = SaveInstallmentService.new(seller:, installment: draft, preview_email_recipient: seller,
                                           params: ActionController::Parameters.new(installment: { installment_type: Installment::AUDIENCE_TYPE, send_emails: false, shown_on_profile: true }, publish: true))
      expect(service.process).to eq(true)
      expect(draft.reload).to be_published
      expect(draft.blasts.count).to eq(0)
      expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
      expect(email_state).to eq("published")
    end

    it "reports a requested blast as processing, not sent" do
      service = SaveInstallmentService.new(seller:, installment: draft, preview_email_recipient: seller,
                                           params: ActionController::Parameters.new(installment: { installment_type: Installment::AUDIENCE_TYPE, send_emails: true }, publish: true))
      expect(service.process).to eq(true)
      expect(draft.blasts.sole).to have_attributes(started_at: nil, completed_at: nil, delivery_count: 0)
      expect(SendPostBlastEmailsJob.jobs.size).to eq(1)
      expect(email_state).to eq("sending")
    end

    %w[sent waiting incomplete].each do |state|
      it "uses the existing #{state} blast state instead of publication time" do
        draft.update!(published_at: Time.current)
        blast = draft.blasts.create!(requested_at: 2.days.ago)
        case state
        when "sent" then blast.update!(completed_at: Time.current)
        when "waiting" then $redis.set(RedisKey.blast_quota_deferred_until(blast.id), 1.hour.from_now.iso8601)
        end
        expect(email_state).to eq(state)
        expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
      end
    end
  end
end
