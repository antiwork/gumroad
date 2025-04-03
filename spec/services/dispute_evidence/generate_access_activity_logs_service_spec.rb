# frozen_string_literal: true

require "spec_helper"

describe DisputeEvidence::GenerateAccessActivityLogsService do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product) }

  describe ".perform" do
    let(:activity_logs_content) { described_class.perform(purchase) }
    let(:sent_at) { DateTime.parse("2024-05-07") }
    let(:rental_first_viewed_at) { DateTime.parse("2024-05-08") }
    let(:consumed_at) { DateTime.parse("2024-05-08") }

    before do
      purchase.create_url_redirect!
      create(
        :customer_email_info_opened,
        email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
        purchase: purchase,
        sent_at:,
        delivered_at: sent_at + 1.hour,
        opened_at: sent_at + 2.hours
      )
      purchase.url_redirect.update!(rental_first_viewed_at:)
      create(:consumption_event, purchase:, consumed_at:, ip_address: "0.0.0.0")
    end

    it "returns combined rental_activity, usage_activity, and email_activity" do
      expect(activity_logs_content).to eq(
        <<~TEXT.strip_heredoc.rstrip
        The receipt email was sent at 2024-05-07 00:00:00 UTC, delivered at 2024-05-07 01:00:00 UTC, opened at 2024-05-07 02:00:00 UTC.

        The rented content was first viewed at 2024-05-08 00:00:00 UTC.

        The customer accessed the product 1 time.

        consumed_at,event_type,platform,ip_address
        2024-05-08 00:00:00 UTC,watch,web,0.0.0.0
        TEXT
      )
    end
  end

  describe "#rental_activity" do
    let(:rental_activity) { described_class.new(purchase).send(:rental_activity) }

    context "without url_redirect" do
      it "returns nil" do
        expect(rental_activity).to be_nil
      end
    end

    context "with url_redirect" do
      before do
        purchase.create_url_redirect!
      end

      context "when rental hasn't been viewed" do
        it "returns nil" do
          expect(rental_activity).to be_nil
        end
      end

      context "when rental has been viewed" do
        let(:rental_first_viewed_at) { DateTime.parse("2024-05-07") }

        before do
          purchase.url_redirect.update!(rental_first_viewed_at:)
        end

        it "returns appropriate content" do
          expect(rental_activity).to eq("The rented content was first viewed at 2024-05-07 00:00:00 UTC.")
        end
      end
    end
  end

  describe "#usage_activity" do
    let(:usage_activity) { described_class.new(purchase).send(:usage_activity) }

    context "without consumption events" do
      context "without url_redirect" do
        it "returns nil" do
          expect(usage_activity).to be_nil
        end
      end

      context "with url_redirect" do
        before do
          purchase.create_url_redirect!
        end

        context "without usage" do
          it "returns nil" do
            expect(usage_activity).to be_nil
          end
        end

        context "when there is usage" do
          before do
            purchase.url_redirect.update!(uses: 2)
          end

          it "returns usage from url_redirect" do
            expect(usage_activity).to eq("The customer accessed the product 2 times.")
          end
        end
      end
    end

    context "with consumption events" do
      let(:consumed_at) { DateTime.parse("2024-05-07") }

      before do
        create(:consumption_event, purchase:, consumed_at:, ip_address: "0.0.0.0")
      end

      it "returns consumption events content" do
        expect(usage_activity).to eq(
          <<~TEXT.strip_heredoc.rstrip
          The customer accessed the product 1 time.

          consumed_at,event_type,platform,ip_address
          2024-05-07 00:00:00 UTC,watch,web,0.0.0.0
          TEXT
        )
      end

      context "with multiple events" do
        before do
          create(
            :consumption_event,
            purchase:,
            consumed_at: (consumed_at - 15.hours),
            event_type: ConsumptionEvent::EVENT_TYPE_DOWNLOAD,
            ip_address: "0.0.0.0"
          )
        end

        it "sorts events chronologically" do
          expect(usage_activity).to eq(
            <<~TEXT.strip_heredoc.rstrip
            The customer accessed the product 2 times.

            consumed_at,event_type,platform,ip_address
            2024-05-06 09:00:00 UTC,download,web,0.0.0.0
            2024-05-07 00:00:00 UTC,watch,web,0.0.0.0
            TEXT
          )
        end

        context "with more records than the limit" do
          before do
            DisputeEvidence::GenerateAccessActivityLogsService::LOG_RECORDS_LIMIT.times do |i|
              create(
                :consumption_event,
                purchase:,
                consumed_at: (consumed_at - i.hour),
                platform: Platform::IPHONE,
                ip_address: "0.0.0.0"
              )
            end
          end

          it "limits content to the last 10 events" do
            expect(usage_activity).to eq(
              <<~TEXT.strip_heredoc.rstrip
              The customer accessed the product 12 times. Most recent 10 log records:

              consumed_at,event_type,platform,ip_address
              2024-05-06 09:00:00 UTC,download,web,0.0.0.0
              2024-05-06 15:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 16:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 17:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 18:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 19:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 20:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 21:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 22:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 23:00:00 UTC,watch,iphone,0.0.0.0
              TEXT
            )
          end
        end
      end
    end
  end

  describe "#email_activity" do
    let(:email_activity) { described_class.new(purchase).send(:email_activity) }

    context "without customer_email_infos" do
      it "returns nil" do
        expect(email_activity).to be_nil
      end
    end

    context "with customer_email_infos" do
      let(:sent_at) { DateTime.parse("2024-05-07") }

      context "when the email infos is associated with a purchase" do
        context "when the email info is not delivered" do
          before do
            create(
              :customer_email_info_sent,
              email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
              purchase: purchase,
              sent_at:,
            )
          end

          it "returns appropriate content" do
            expect(email_activity).to eq(
              "The receipt email was sent at 2024-05-07 00:00:00 UTC."
            )
          end
        end

        context "when the email info is delivered" do
          before do
            create(
              :customer_email_info_delivered,
              email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
              purchase: purchase,
              sent_at:,
              delivered_at: sent_at + 1.hour,
            )
          end

          it "returns appropriate content" do
            expect(email_activity).to eq(
              "The receipt email was sent at 2024-05-07 00:00:00 UTC, delivered at 2024-05-07 01:00:00 UTC."
            )
          end
        end

        context "when the email info is opened" do
          before do
            create(
              :customer_email_info_opened,
              email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
              purchase: purchase,
              sent_at:,
              delivered_at: sent_at + 1.hour,
              opened_at: sent_at + 2.hours
            )
          end

          it "returns appropriate content" do
            expect(email_activity).to eq(
              "The receipt email was sent at 2024-05-07 00:00:00 UTC, delivered at 2024-05-07 01:00:00 UTC, opened at 2024-05-07 02:00:00 UTC."
            )
          end
        end
      end

      context "when the email info is associated with a charge" do
        let(:charge) { create(:charge, purchases: [purchase], seller:) }
        let(:order) { charge.order }

        before do
          order.purchases << purchase
          create(
            :customer_email_info_opened,
            purchase_id: nil,
            state: :opened,
            sent_at:,
            delivered_at: sent_at + 1.hour,
            opened_at: sent_at + 2.hours,
            email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
            email_info_charge_attributes: { charge_id: charge.id }
          )
        end

        it "returns appropriate content" do
          expect(email_activity).to eq(
            "The receipt email was sent at 2024-05-07 00:00:00 UTC, delivered at 2024-05-07 01:00:00 UTC, opened at 2024-05-07 02:00:00 UTC."
          )
        end
      end
    end
  end
end
