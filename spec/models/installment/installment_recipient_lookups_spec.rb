# frozen_string_literal: true

require "spec_helper"

# Regression coverage for the batch sizes used when resolving a post's non-opener
# audience. These are not arbitrary tuning knobs: an oversized `WHERE id IN (...)` list
# against `purchases` makes MySQL exceed its range-optimizer memory budget, at which point
# it silently discards the primary-key plan and scans the whole table (~327 million rows in
# production). It raises no error and logs no warning, so the only thing that catches a bad
# value is a test that looks at the SQL actually emitted.
describe "Installment non-opener recipient lookups" do
  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller) }
  let(:post) { create(:installment, seller:, link: product) }

  describe "batch size constants" do
    it "keeps the purchases lookup well under the id count where MySQL abandons the primary key" do
      # Measured against a 350k-recipient post on production: at 2,000 ids the plan is
      # still `range` on PRIMARY; by 2,500 it has flipped to a full table scan. Anything
      # at or above that boundary must fail this test.
      expect(Installment::PURCHASE_LOOKUP_BATCH_SIZE).to be <= 2_000
    end

    it "keeps the purchases lookup smaller than the email_infos walk" do
      # The email_infos walk only touches its own table and is safe at a large size. The
      # purchases lookup is the constrained one. Collapsing them back into a single shared
      # constant is what caused the original outage, so assert they stay distinct.
      expect(Installment::PURCHASE_LOOKUP_BATCH_SIZE).to be < Installment::EMAIL_INFO_BATCH_SIZE
    end
  end

  describe "#unopened_recipient_emails" do
    let!(:opened_purchase) { create(:purchase, link: product, email: "opened@example.com") }
    let!(:unopened_purchase) { create(:purchase, link: product, email: "unopened@example.com") }

    before do
      create(:creator_contacting_customers_email_info_opened, installment: post, purchase: opened_purchase)
      create(:creator_contacting_customers_email_info_sent, installment: post, purchase: unopened_purchase)
    end

    it "returns the emails of recipients who were sent the post but never opened it" do
      expect(post.unopened_recipient_emails).to contain_exactly("unopened@example.com")
    end

    it "never puts more purchase ids in one statement than the batch size allows" do
      stub_const("Installment::PURCHASE_LOOKUP_BATCH_SIZE", 1)

      id_list_lengths = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        sql = payload[:sql]
        next unless sql.include?("`purchases`") && sql.include?("`id` IN (")

        id_list_lengths << sql[/`id` IN \(([^)]*)\)/, 1].split(",").length
      end

      begin
        post.unopened_recipient_emails
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(id_list_lengths).to all(be <= Installment::PURCHASE_LOOKUP_BATCH_SIZE)
    end

    it "returns an empty list when the post was never emailed to anyone" do
      expect(create(:installment, seller:, link: product).unopened_recipient_emails).to eq([])
    end
  end
end
