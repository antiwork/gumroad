# frozen_string_literal: true

require "test_helper"

class DisputeEvidenceGenerateAccessActivityLogsServiceTest < ActiveSupport::TestCase
  self.described_class = DisputeEvidence::GenerateAccessActivityLogsService



  context_ DisputeEvidence::GenerateAccessActivityLogsService do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product) }

  context_ ".perform" do
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

  test "returns combined rental_activity, usage_activity, and email_activity" do
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

  context_ "#rental_activity" do
      let(:rental_activity) { described_class.new(purchase).send(:rental_activity) }

  context_ "without url_redirect" do
  test "returns nil" do
          expect(rental_activity).to be_nil
        end
      end

  context_ "with url_redirect" do
        before do
          purchase.create_url_redirect!
        end

  context_ "when rental hasn't been viewed" do
  test "returns nil" do
            expect(rental_activity).to be_nil
          end
        end

  context_ "when rental has been viewed" do
          let(:rental_first_viewed_at) { DateTime.parse("2024-05-07") }

          before do
            purchase.url_redirect.update!(rental_first_viewed_at:)
          end

  test "returns appropriate content" do
            expect(rental_activity).to eq("The rented content was first viewed at 2024-05-07 00:00:00 UTC.")
          end
        end
      end
    end

  context_ "#usage_activity" do
      let(:usage_activity) { described_class.new(purchase).send(:usage_activity) }

  context_ "without consumption events" do
  context_ "without url_redirect" do
  test "returns nil" do
            expect(usage_activity).to be_nil
          end
        end

  context_ "with url_redirect" do
          before do
            purchase.create_url_redirect!
          end

  context_ "without usage" do
  test "returns nil" do
              expect(usage_activity).to be_nil
            end
          end

  context_ "when there is usage" do
            before do
              purchase.url_redirect.update!(uses: 2)
            end

  test "returns usage from url_redirect" do
              expect(usage_activity).to eq("The customer accessed the product 2 times.")
            end
          end
        end
      end

  context_ "with consumption events" do
        let(:consumed_at) { DateTime.parse("2024-05-07") }

        before do
          create(:consumption_event, purchase:, consumed_at:, ip_address: "0.0.0.0")
        end

  test "returns consumption events content" do
          expect(usage_activity).to eq(
            <<~TEXT.strip_heredoc.rstrip
            The customer accessed the product 1 time.

            consumed_at,event_type,platform,ip_address
            2024-05-07 00:00:00 UTC,watch,web,0.0.0.0
            TEXT
          )
        end

  context_ "with multiple events" do
          before do
            create(
              :consumption_event,
              purchase:,
              consumed_at: (consumed_at - 15.hours),
              event_type: ConsumptionEvent::EVENT_TYPE_DOWNLOAD,
              ip_address: "0.0.0.0"
            )
          end

  test "sorts events chronologically" do
            expect(usage_activity).to eq(
              <<~TEXT.strip_heredoc.rstrip
              The customer accessed the product 2 times.

              consumed_at,event_type,platform,ip_address
              2024-05-06 09:00:00 UTC,download,web,0.0.0.0
              2024-05-07 00:00:00 UTC,watch,web,0.0.0.0
              TEXT
            )
          end

  context_ "with more records than the limit" do
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

  test "limits content to the last 10 events" do
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

  context_ "#email_activity" do
      let(:email_activity) { described_class.new(purchase).send(:email_activity) }

  context_ "without customer_email_infos" do
  test "returns nil" do
          expect(email_activity).to be_nil
        end
      end

  context_ "with customer_email_infos" do
        let(:sent_at) { DateTime.parse("2024-05-07") }

  context_ "when the email infos is associated with a purchase" do
  context_ "when the email info is not delivered" do
            before do
              create(
                :customer_email_info_sent,
                email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
                purchase: purchase,
                sent_at:,
              )
            end

  test "returns appropriate content" do
              expect(email_activity).to eq(
                "The receipt email was sent at 2024-05-07 00:00:00 UTC."
              )
            end
          end

  context_ "when the email info is delivered" do
            before do
              create(
                :customer_email_info_delivered,
                email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
                purchase: purchase,
                sent_at:,
                delivered_at: sent_at + 1.hour,
              )
            end

  test "returns appropriate content" do
              expect(email_activity).to eq(
                "The receipt email was sent at 2024-05-07 00:00:00 UTC, delivered at 2024-05-07 01:00:00 UTC."
              )
            end
          end

  context_ "when the email info is opened" do
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

  test "returns appropriate content" do
              expect(email_activity).to eq(
                "The receipt email was sent at 2024-05-07 00:00:00 UTC, delivered at 2024-05-07 01:00:00 UTC, opened at 2024-05-07 02:00:00 UTC."
              )
            end
          end
        end

  context_ "when the email info is associated with a charge" do
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

  test "returns appropriate content" do
            expect(email_activity).to eq(
              "The receipt email was sent at 2024-05-07 00:00:00 UTC, delivered at 2024-05-07 01:00:00 UTC, opened at 2024-05-07 02:00:00 UTC."
            )
          end
        end
      end
    end
  end
end
