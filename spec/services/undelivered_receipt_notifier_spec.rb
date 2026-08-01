# frozen_string_literal: true

require "spec_helper"

describe UndeliveredReceiptNotifier do
  let(:purchase) { create(:purchase) }

  def settled_receipt(state, **attrs)
    create(:customer_email_info, purchase:, state:, sent_at: 3.days.ago, **attrs)
  end

  describe ".undelivered?" do
    it "is true for a receipt that was sent and never confirmed" do
      settled_receipt("sent")

      expect(described_class.undelivered?(purchase)).to eq(true)
    end

    it "is true for a bounced receipt" do
      settled_receipt("bounced")

      expect(described_class.undelivered?(purchase)).to eq(true)
    end

    it "is false when the receipt was delivered" do
      settled_receipt("delivered", delivered_at: 3.days.ago)

      expect(described_class.undelivered?(purchase)).to eq(false)
    end

    it "is false when the receipt was opened" do
      settled_receipt("opened", opened_at: 3.days.ago)

      expect(described_class.undelivered?(purchase)).to eq(false)
    end

    # A delivery timestamp is evidence the buyer got the email whatever the state column says, and a
    # resend leaves exactly that shape while the row sits back at `sent`.
    it "is false for a row back at sent that still carries a delivery timestamp" do
      settled_receipt("sent", delivered_at: 4.days.ago)

      expect(described_class.undelivered?(purchase)).to eq(false)
    end

    # Delivery events land in minutes but content access does not, so judging early would report a
    # buyer who is about to click.
    it "is false before the settle grace has elapsed" do
      create(:customer_email_info, purchase:, state: "sent", sent_at: 1.hour.ago)

      expect(described_class.undelivered?(purchase)).to eq(false)
    end

    it "is false when there is no receipt record at all" do
      expect(described_class.undelivered?(purchase)).to eq(false)
    end

    it "is false when the buyer has opened their content" do
      settled_receipt("sent")
      create(:url_redirect, purchase:, link: purchase.link, uses: 2)

      expect(described_class.undelivered?(purchase)).to eq(false)
    end

    it "is true when a download page exists but was never used" do
      settled_receipt("sent")
      create(:url_redirect, purchase:, link: purchase.link, uses: 0)

      expect(described_class.undelivered?(purchase)).to eq(true)
    end

    context "with a charge receipt covering several purchases" do
      let(:seller) { create(:user) }
      let(:charge) { create(:charge, seller:) }
      let(:first_purchase) { create(:purchase, seller:, link: create(:product, user: seller)) }
      let(:second_purchase) { create(:purchase, seller:, link: create(:product, user: seller)) }

      before do
        charge.purchases << first_purchase
        charge.purchases << second_purchase
        charge.update!(order: create(:order))
        create(:customer_email_info, purchase: nil, state: "sent", sent_at: 3.days.ago,
                                     email_info_charge_attributes: { charge_id: charge.id })
      end

      # One receipt covers the whole order, so any purchase in it being opened proves the buyer read
      # the email. Checking only the representative purchase would report a buyer using their content.
      it "is false when a sibling purchase in the same charge was accessed" do
        create(:url_redirect, purchase: second_purchase, link: second_purchase.link, uses: 1)

        expect(described_class.undelivered?(first_purchase)).to eq(false)
      end

      it "is true when no purchase in the charge was accessed" do
        create(:url_redirect, purchase: first_purchase, link: first_purchase.link, uses: 0)
        create(:url_redirect, purchase: second_purchase, link: second_purchase.link, uses: 0)

        expect(described_class.undelivered?(first_purchase)).to eq(true)
      end
    end
  end

  describe ".notified? and .record_sent" do
    it "is false before the notice and true after" do
      expect(described_class.notified?(purchase.id)).to eq(false)

      described_class.record_sent([purchase.id])

      expect(described_class.notified?(purchase.id)).to eq(true)
    end

    # The record is the only thing between a nightly sweep and re-emailing every seller in the window,
    # so an unreadable store must suppress rather than send. It answers `nil` rather than `true` so a
    # caller can tell that apart from having actually told the seller.
    it "cannot say whether the seller was notified when the store cannot be read" do
      allow($redis).to receive(:exists?).and_raise(StandardError)
      expect(ErrorNotifier).to receive(:notify)

      expect(described_class.notified?(purchase.id)).to be_nil
    end

    it "stops tracking a buyer for retry once the notice is recorded" do
      described_class.track_for_retry([purchase.id])

      described_class.record_sent([purchase.id])

      expect(described_class.pending_retry_purchase_ids(10)).to be_empty
    end
  end

  describe ".track_for_retry and the pending retry set" do
    # The sweep advanced its cursor past this buyer's row in the run that enqueued the digest, and it
    # only ever queries forward. Handing the claim back without this set drops the notice for good.
    it "keeps a buyer whose notice was claimed and never sent" do
      described_class.track_for_retry([purchase.id])
      described_class.claim_send([purchase.id])

      described_class.release_claim([purchase.id])

      expect(described_class.notified?(purchase.id)).to eq(false)
      expect(described_class.pending_retry_purchase_ids(10)).to eq([purchase.id])
    end

    it "holds one entry per buyer across repeated failures" do
      described_class.track_for_retry([purchase.id])
      described_class.track_for_retry([purchase.id])

      expect(described_class.pending_retry_purchase_ids(10)).to eq([purchase.id])
    end

    it "returns no more than the requested number" do
      other = create(:purchase)
      described_class.track_for_retry([purchase.id, other.id])

      expect(described_class.pending_retry_purchase_ids(1).size).to eq(1)
    end

    it "drops a buyer that is cleared" do
      described_class.track_for_retry([purchase.id])

      described_class.clear_pending_retry([purchase.id])

      expect(described_class.pending_retry_purchase_ids(10)).to be_empty
    end

    # The caller advances a cursor on this answer. Reporting success for a write that did not happen
    # would move it past a buyer with nothing holding them.
    it "reports failure when the buyer could not be tracked" do
      allow($redis).to receive(:sadd).and_raise(StandardError)
      expect(ErrorNotifier).to receive(:notify)

      expect(described_class.track_for_retry([purchase.id])).to eq(false)
    end

    it "reports success when the buyer is tracked" do
      expect(described_class.track_for_retry([purchase.id])).to eq(true)
    end

    # The buyer is already in the set by the time a claim is given back, so this path writes nothing
    # that could fail and strand them.
    it "keeps the buyer tracked when giving the claim key back fails" do
      described_class.track_for_retry([purchase.id])
      described_class.claim_send([purchase.id])
      allow($redis).to receive(:del).and_raise(StandardError)
      expect(ErrorNotifier).to receive(:notify)

      described_class.release_claim([purchase.id])

      expect(described_class.pending_retry_purchase_ids(10)).to eq([purchase.id])
    end
  end
end
