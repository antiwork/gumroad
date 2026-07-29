# frozen_string_literal: true

require "spec_helper"

describe Purchase::ClearMistakenBuyerBlocksService do
  let(:buyer_email) { "loyal-buyer@example.com" }

  # A buyer the old rule would have blocked wrongly: three settled, undisputed purchases behind
  # them, then one renewal declined with "lost card", which blocked everything about them.
  def block_everything_for(purchase)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: purchase.browser_guid)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: purchase.email)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:ip_address], object_value: purchase.ip_address, expires_in: 6.months)
  end

  let!(:history) do
    create_list(:purchase, Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY,
                email: buyer_email, purchase_state: "successful")
  end

  let!(:failed_purchase) do
    create(:purchase, email: buyer_email, purchase_state: "failed", stripe_error_code: "card_declined_lost_card")
  end

  before { block_everything_for(failed_purchase) }

  it "clears the automated blocks that hold a buyer with clean history" do
    expect { described_class.new.process }.to change { PlatformBlock.active.count }.from(3).to(0)
  end

  it "reports what it cleared" do
    result = described_class.new.process

    expect(result.length).to eq(1)
    expect(result.first[:purchase_id]).to eq(failed_purchase.id)
    expect(result.first[:error_code]).to eq("card_declined_lost_card")
    expect(result.first[:blocks].map(&:last)).to match_array([failed_purchase.browser_guid, failed_purchase.ip_address, buyer_email])
  end

  it "changes nothing in a dry run" do
    expect { described_class.new(dry_run: true).process }.not_to change { PlatformBlock.active.count }
  end

  it "leaves blocks an admin created alone" do
    admin = create(:admin_user)
    PlatformBlock.active.each { |block| block.update!(blocked_by: admin.id) }

    expect { described_class.new.process }.not_to change { PlatformBlock.active.count }
  end

  it "leaves a buyer without clean history blocked" do
    history.each { |purchase| purchase.update!(chargeback_date: 1.month.ago) }

    expect { described_class.new.process }.not_to change { PlatformBlock.active.count }
  end

  it "leaves blocks from a non-fraud decline alone" do
    failed_purchase.update!(stripe_error_code: "card_declined_insufficient_funds")

    expect { described_class.new.process }.not_to change { PlatformBlock.active.count }
  end
end
