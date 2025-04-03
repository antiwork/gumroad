# frozen_string_literal: true

require "spec_helper"

describe MillionDollarMilestoneCheckWorker do
  describe "#perform" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }

    it "sends Slack notification if million dollar milestone is reached with no compliance info" do
      allow_any_instance_of(User).to receive(:gross_sales_cents_total_as_seller).and_return(1_000_000_00)
      allow_any_instance_of(User).to receive(:alive_user_compliance_info).and_return(nil)
      create(:purchase, seller:, link: product, created_at: 15.days.ago)

      described_class.new.perform

      message = "<#{seller.profile_url}|#{seller.name_or_username}> has crossed $1M in earnings :tada:\n" \
                "• Name: #{seller.name}\n" \
                "• Username: #{seller.username}\n" \
                "• Email: #{seller.email}\n"
      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("awards", "Gumroad Awards", message, "hotpink")
    end

    it "sends Slack notification if million dollar milestone is reached with compliance info" do
      allow_any_instance_of(User).to receive(:gross_sales_cents_total_as_seller).and_return(1_000_000_00)
      compliance_info = instance_double(
        "UserComplianceInfo",
        first_name: "John",
        last_name: "Doe",
        street_address: "123 Main St",
        city: "San Francisco",
        state: "CA",
        zip_code: "94105",
        country: "USA"
      )
      allow_any_instance_of(User).to receive(:alive_user_compliance_info).and_return(compliance_info)
      create(:purchase, seller:, link: product, created_at: 15.days.ago)

      described_class.new.perform

      message = "<#{seller.profile_url}|#{seller.name_or_username}> has crossed $1M in earnings :tada:\n" \
                "• Name: #{seller.name}\n" \
                "• Username: #{seller.username}\n" \
                "• Email: #{seller.email}\n" \
                "• First name: John\n" \
                "• Last name: Doe\n" \
                "• Street address: 123 Main St\n" \
                "• City: San Francisco\n" \
                "• State: CA\n" \
                "• ZIP code: 94105\n" \
                "• Country: USA"
      expect(SlackMessageWorker).to have_enqueued_sidekiq_job("awards", "Gumroad Awards", message, "hotpink")
    end

    it "does not send Slack notification if million dollar milestone is not reached" do
      allow_any_instance_of(User).to receive(:gross_sales_cents_total_as_seller).and_return(999_999)
      create(:purchase, seller:, link: product, created_at: 15.days.ago)

      described_class.new.perform

      expect(SlackMessageWorker).not_to have_enqueued_sidekiq_job("awards", "Gumroad Awards", anything, "hotpink")
    end

    it "does not send Slack notification if million dollar milestone is reached but announcement has already been " \
       "sent" do
      seller.update!(million_dollar_announcement_sent: true)
      allow_any_instance_of(User).to receive(:gross_sales_cents_total_as_seller).and_return(1_000_000_00)
      create(:purchase, seller:, link: product, created_at: 15.days.ago)

      described_class.new.perform

      expect(SlackMessageWorker).not_to have_enqueued_sidekiq_job("awards", "Gumroad Awards", anything, "hotpink")
    end

    it "does not include users who have not made a sale in the last 3 weeks" do
      allow_any_instance_of(User).to receive(:gross_sales_cents_total_as_seller).and_return(1_000_000_00)
      create(:purchase, seller:, link: product, created_at: 4.weeks.ago)

      described_class.new.perform

      expect(SlackMessageWorker).not_to have_enqueued_sidekiq_job("awards", "Gumroad Awards", anything, "hotpink")
    end

    it "does not include users whose purchases are within the last 2 weeks" do
      allow_any_instance_of(User).to receive(:gross_sales_cents_total_as_seller).and_return(1_000_000_00)
      create(:purchase, seller:, link: product, created_at: 1.weeks.ago)

      described_class.new.perform

      expect(SlackMessageWorker).not_to have_enqueued_sidekiq_job("awards", "Gumroad Awards", anything, "hotpink")
    end

    it "marks seller as announcement sent" do
      allow_any_instance_of(User).to receive(:gross_sales_cents_total_as_seller).and_return(1_000_000_00)
      create(:purchase, seller:, link: product, created_at: 15.days.ago)

      described_class.new.perform

      expect(seller.reload.million_dollar_announcement_sent).to eq(true)
    end

    it "sends Bugsnag notification if announcement cannot be marked as sent" do
      allow_any_instance_of(User).to receive(:gross_sales_cents_total_as_seller).and_return(1_000_000_00)
      allow_any_instance_of(User).to receive(:update).and_return(false)
      create(:purchase, seller:, link: product, created_at: 15.days.ago)

      expect(Bugsnag).to receive(:notify).with("Failed to send Slack notification for million dollar milestone", user_id: seller.id)

      described_class.new.perform
    end

    it "carries on with other users if announcement cannot be marked as sent for a user" do
      additional_seller = create(:user)
      additional_product = create(:product, user: additional_seller)
      create(:purchase, seller:, link: product, created_at: 15.days.ago)
      create(:purchase, seller: additional_seller, link: additional_product, created_at: 15.days.ago)

      allow_any_instance_of(User).to receive(:gross_sales_cents_total_as_seller).and_return(1_000_000_00)
      allow_any_instance_of(User).to receive(:update).and_return(false)

      expect(Bugsnag).to receive(:notify).with("Failed to send Slack notification for million dollar milestone", user_id: anything).twice

      described_class.new.perform
    end
  end
end
