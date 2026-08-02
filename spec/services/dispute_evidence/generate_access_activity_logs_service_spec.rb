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

          it "includes the most recent 10 events, still in chronological order" do
            expect(usage_activity).to eq(
              <<~TEXT.strip_heredoc.rstrip
              The customer accessed the product 12 times. Most recent 10 log records:

              consumed_at,event_type,platform,ip_address
              2024-05-06 16:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 17:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 18:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 19:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 20:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 21:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 22:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-06 23:00:00 UTC,watch,iphone,0.0.0.0
              2024-05-07 00:00:00 UTC,watch,web,0.0.0.0
              2024-05-07 00:00:00 UTC,watch,iphone,0.0.0.0
              TEXT
            )
          end

          # The header's claim is the whole point of the fix: the two oldest accesses must be the
          # ones dropped, never the most recent, which are what rebut a "never used it" dispute.
          it "drops the oldest events rather than the newest" do
            expect(usage_activity).to include("2024-05-07 00:00:00 UTC,watch,iphone")
            expect(usage_activity).not_to include("2024-05-06 09:00:00 UTC,download,web")
            expect(usage_activity).not_to include("2024-05-06 15:00:00 UTC,watch,iphone")
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

        # A resend is often triggered BY the dispute, so the evidence must date
        # the receipt from the ORIGINAL send. Delivery events carry no message
        # id, so with two sends outstanding they are reported without claiming
        # which send earned them (gumroad-private#1635).
        context "when the receipt was resent after the original send" do
          before do
            create(
              :customer_email_info_opened,
              email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
              purchase: purchase,
              sent_at:,
              delivered_at: sent_at + 1.hour,
              opened_at: sent_at + 2.hours
            )
            create(
              :customer_email_info_sent,
              email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
              purchase: purchase,
              sent_at: sent_at + 5.days,
            )
          end

          it "dates the receipt from the original send and reports the events unattributed" do
            expect(email_activity).to eq(
              "The receipt email was sent at 2024-05-07 00:00:00 UTC. The receipt was sent again at " \
              "2024-05-12 00:00:00 UTC. A receipt was delivered at 2024-05-07 01:00:00 UTC. " \
              "A receipt was opened at 2024-05-07 02:00:00 UTC."
            )
          end

          it "attributes the delivery and open to no individual send" do
            expect(email_activity).to_not match(/sent at 2024-05-07 00:00:00 UTC, delivered/)
            expect(email_activity).to_not match(/sent again at 2024-05-12 00:00:00 UTC, delivered/)
          end
        end

        # The dispute flow this evidence answers is "I never got it" -> seller
        # resends -> buyer opens the RESEND, so the events land on the resend's
        # row. Citing only the original would drop the strongest signal we have,
        # and citing it as the resend's would overstate what we know.
        context "when the events landed on the resend rather than the original" do
          before do
            create(
              :customer_email_info_sent,
              email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
              purchase: purchase,
              sent_at:,
            )
            create(
              :customer_email_info_opened,
              email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
              purchase: purchase,
              sent_at: sent_at + 5.days,
              delivered_at: sent_at + 5.days + 1.hour,
              opened_at: sent_at + 5.days + 2.hours
            )
          end

          it "still reports the delivery and open" do
            expect(email_activity).to eq(
              "The receipt email was sent at 2024-05-07 00:00:00 UTC. The receipt was sent again at " \
              "2024-05-12 00:00:00 UTC. A receipt was delivered at 2024-05-12 01:00:00 UTC. " \
              "A receipt was opened at 2024-05-12 02:00:00 UTC."
            )
          end
        end

        # Both sends carry events, so "which is reported" is a real choice: the
        # EARLIEST proves the buyer had the receipt as soon as possible, which
        # is what the card network is being asked.
        context "when both sends carry their own delivery and open" do
          before do
            create(
              :customer_email_info_opened,
              email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
              purchase: purchase,
              sent_at:,
              delivered_at: sent_at + 1.hour,
              opened_at: sent_at + 2.hours
            )
            create(
              :customer_email_info_opened,
              email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
              purchase: purchase,
              sent_at: sent_at + 5.days,
              delivered_at: sent_at + 5.days + 1.hour,
              opened_at: sent_at + 5.days + 2.hours
            )
          end

          it "reports the earliest delivery and open, once" do
            expect(email_activity).to eq(
              "The receipt email was sent at 2024-05-07 00:00:00 UTC. The receipt was sent again at " \
              "2024-05-12 00:00:00 UTC. A receipt was delivered at 2024-05-07 01:00:00 UTC. " \
              "A receipt was opened at 2024-05-07 02:00:00 UTC."
            )
          end
        end

        # Whichever send a provider's event routed to, the evidence reads the
        # same — so a misrouted event cannot change what we tell the card
        # network. This is the property that makes timestamp routing's
        # remaining ambiguity harmless here.
        context "when the same events are routed to different sends" do
          # `email_activity` is a memoized `let`, so read the service directly —
          # the whole point here is evaluating it twice.
          def activity_with_events_on(row)
            purchase.email_infos.destroy_all
            purchase.instance_variable_set(:@_receipt_email_info, nil)
            rows = [sent_at, sent_at + 5.days].each_with_index.map do |at, index|
              create(
                (index == row ? :customer_email_info_opened : :customer_email_info_sent),
                email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
                purchase: purchase,
                sent_at: at,
                **(index == row ? { delivered_at: sent_at + 1.hour, opened_at: sent_at + 2.hours } : {})
              )
            end
            expect(rows.size).to eq(2)
            described_class.new(purchase.reload).send(:email_activity)
          end

          it "produces identical evidence either way" do
            events_on_original = activity_with_events_on(0)
            expect(events_on_original).to include("A receipt was opened at")
            expect(activity_with_events_on(1)).to eq(events_on_original)
          end
        end
      end

      context "when the email info is associated with a charge" do
        let(:charge) { create(:charge, purchases: [purchase], seller:, merchant_account: nil) }
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

  # Access rows are written against the member purchases the buyer downloads, not the disputed
  # wrapper.
  describe "bundle purchases" do
    let(:bundle_purchase) { create(:purchase, link: create(:product, :bundle, user: seller), is_bundle_purchase: true) }
    let(:member_product) { create(:product, user: seller, name: "Member One") }
    let(:member_purchase) do
      create(:purchase, link: member_product, seller:, email: bundle_purchase.email, is_bundle_product_purchase: true)
    end

    before do
      create(:bundle_product_purchase, bundle_purchase:, product_purchase: member_purchase)
    end

    it "reports consumption events recorded against the member purchases" do
      create(:consumption_event, purchase_id: member_purchase.id, consumed_at: DateTime.parse("2024-05-08"), ip_address: "1.2.3.4")

      expect(described_class.perform(bundle_purchase)).to eq(
        <<~TEXT.strip_heredoc.rstrip
        The customer accessed the product 1 time.

        consumed_at,event_type,platform,ip_address,product
        2024-05-08 00:00:00 UTC,watch,web,1.2.3.4,"Member One"
        TEXT
      )
    end

    it "returns nil when neither the wrapper nor members have access" do
      expect(described_class.perform(bundle_purchase)).to be_nil
    end

    it "counts url_redirect uses on the wrapper and members when there are no consumption events" do
      bundle_purchase.create_url_redirect!
      bundle_purchase.url_redirect.update!(uses: 2)
      member_purchase.create_url_redirect!
      member_purchase.url_redirect.update!(uses: 7)

      expect(described_class.perform(bundle_purchase)).to eq("The customer accessed the product 9 times.")
    end

    it "reports a redirect-only member's uses alongside another member's consumption events" do
      second_member = create(:purchase, link: create(:product, user: seller, name: "Member Two"), seller:, email: bundle_purchase.email, is_bundle_product_purchase: true)
      create(:bundle_product_purchase, bundle_purchase:, product_purchase: second_member)
      create(:consumption_event, purchase_id: member_purchase.id, consumed_at: DateTime.parse("2024-05-08"), ip_address: "1.2.3.4")
      second_member.create_url_redirect!
      second_member.url_redirect.update!(uses: 5)

      content = described_class.perform(bundle_purchase)

      expect(content).to include("The customer accessed the product 1 time.")
      expect(content).to include("The customer accessed the product 5 more times.")
    end

    it "does not recount uses on a member whose accesses are already event-logged" do
      create(:consumption_event, purchase_id: member_purchase.id, consumed_at: DateTime.parse("2024-05-08"), ip_address: "1.2.3.4")
      member_purchase.create_url_redirect!
      member_purchase.url_redirect.update!(uses: 3)

      content = described_class.perform(bundle_purchase)

      expect(content).to include("The customer accessed the product 1 time.")
      expect(content).to_not include("more time")
    end

    it "orders the merged wrapper and member events by time" do
      create(:consumption_event, purchase_id: member_purchase.id, consumed_at: DateTime.parse("2024-05-09"), ip_address: "9.9.9.9")
      create(:consumption_event, purchase_id: bundle_purchase.id, consumed_at: DateTime.parse("2024-05-08"), ip_address: "8.8.8.8")

      rows = described_class.perform(bundle_purchase).lines.grep(/\d+\.\d+\.\d+\.\d+/)

      expect(rows.first).to include("8.8.8.8")
      expect(rows.last).to include("9.9.9.9")
      expect(described_class.perform(bundle_purchase)).to include("The customer accessed the product 2 times.")
    end

    it "limits bundle consumption rows after merging member events by time" do
      second_member = create(:purchase, link: create(:product, user: seller, name: "Member Two"), seller:, email: bundle_purchase.email, is_bundle_product_purchase: true)
      create(:bundle_product_purchase, bundle_purchase:, product_purchase: second_member)
      consumed_at = DateTime.parse("2024-05-08")

      12.times do |i|
        create(
          :consumption_event,
          purchase_id: i.even? ? member_purchase.id : second_member.id,
          consumed_at: consumed_at + i.minutes,
          ip_address: "10.0.0.#{i}"
        )
      end

      content = described_class.perform(bundle_purchase)
      rows = content.lines.grep(/10\.0\.0\./).map(&:strip)
      # Events 0 and 1 are the oldest of the twelve, so the most-recent window is 2..11.
      expected_rows = (2..11).map do |i|
        product_name = i.even? ? "Member One" : "Member Two"
        "2024-05-08 00:#{format('%02d', i)}:00 UTC,watch,web,10.0.0.#{i},\"#{product_name}\""
      end

      expect(content).to include("The customer accessed the product 12 times. Most recent 10 log records:")
      expect(rows).to eq(expected_rows)
    end

    it "leaves non-bundle output byte-identical" do
      create(:consumption_event, purchase_id: purchase.id, consumed_at: DateTime.parse("2024-05-08"), ip_address: "0.0.0.0")

      expect(described_class.perform(purchase)).to eq(
        <<~TEXT.strip_heredoc.rstrip
        The customer accessed the product 1 time.

        consumed_at,event_type,platform,ip_address
        2024-05-08 00:00:00 UTC,watch,web,0.0.0.0
        TEXT
      )
    end
  end
end
