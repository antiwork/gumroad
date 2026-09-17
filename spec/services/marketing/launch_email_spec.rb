# frozen_string_literal: true

require "spec_helper"

describe Marketing::LaunchEmail do
  let(:seller) { create(:user) }
  let(:product) do
    create(:product, user: seller, name: "Gumstein Letters",
                     description: "<p>Ten years of letters from the Andes. Second sentence nobody needs.</p>")
  end
  let(:utm_link) do
    create(:utm_link, seller:, target_resource_type: :product_page, target_resource_id: product.id)
  end

  subject(:launch_email) { described_class.new(product:, seller:, utm_link:) }

  before do
    create(:payment_completed, user: seller)
    # Same convention as the gate's own spec: seeding $100 of real sales is heavier than the
    # predicate needs.
    allow(seller).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
  end

  describe "#installment" do
    it "drafts one audience email that excludes the new product's buyers" do
      expect { launch_email.installment }.to change { seller.installments.count }.by(1)

      installment = launch_email.installment
      expect(installment.installment_type).to eq(Installment::AUDIENCE_TYPE)
      expect(installment.not_bought_products).to eq([product.unique_permalink])
      expect(installment.bought_products).to be_blank
      expect(installment.send_emails?).to eq(true)
      expect(installment.workflow_id).to be_nil
    end

    it "leaves the draft unsent and unscheduled" do
      installment = launch_email.installment

      expect(installment.published_at).to be_nil
      expect(installment.ready_to_publish?).to eq(false)
      expect(installment.installment_rule).to be_nil
      expect(installment.blasts).to be_empty
      expect(installment.has_been_blasted?).to eq(false)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
      expect(PublishScheduledPostJob.jobs).to be_empty
    end

    it "writes the product copy and the launch's tagged link into the body" do
      installment = launch_email.installment

      expect(installment.name).to eq("Gumstein Letters")
      expect(installment.message).to include("Gumstein Letters: Ten years of letters from the Andes.")
      expect(installment.message).not_to include("Second sentence nobody needs")
      expect(installment.message).to include(utm_link.short_url)
    end

    it "reuses the same draft on repeat calls" do
      first = launch_email.installment
      second = described_class.new(product:, seller:, utm_link:).installment

      expect(second).to eq(first)
      expect(seller.installments.alive.count).to eq(1)
    end

    it "does not adopt an audience email the seller wrote with the same product exclusion" do
      theirs = create(:audience_installment, seller:)
      theirs.not_bought_products = [product.unique_permalink]
      theirs.save!

      draft = launch_email.installment

      expect(draft).not_to eq(theirs)
      expect(draft.json_data[described_class::LAUNCH_PRODUCT_KEY]).to eq(product.id)
      expect(described_class.new(product:, seller:, utm_link:).installment).to eq(draft)
    end

    it "does not replace a draft the seller deleted" do
      draft = launch_email.installment
      draft.mark_deleted!

      expect { launch_email.installment }.not_to change { Installment.count }
      expect(launch_email.installment).to be_nil
      expect(launch_email).to be_declined
    end

    it "refreshes the copy of an untouched draft when the product changes" do
      draft = launch_email.installment
      product.update!(description: "<p>A brand new first sentence. Ignored second.</p>")

      expect(launch_email.installment).to eq(draft)
      expect(draft.reload.message).to include("A brand new first sentence.")
    end

    it "leaves a draft the seller rewrote alone" do
      draft = launch_email.installment
      draft.update!(message: "<p>My own words.</p>")
      product.update!(description: "<p>Changed again.</p>")

      expect(launch_email.installment).to eq(draft)
      expect(draft.reload.message).to eq("<p>My own words.</p>")
    end

    it "still recognises a draft the seller renamed, without drafting a second one" do
      draft = launch_email.installment
      draft.update!(name: "A subject of my own")

      expect(launch_email.installment).to eq(draft)
      expect(seller.installments.alive.count).to eq(1)
      expect(draft.reload.name).to eq("A subject of my own")
    end

    it "still recognises the draft after the seller retargets its audience" do
      draft = launch_email.installment
      # The card links straight to the Emails editor, where removing the "has not bought"
      # exclusion is the obvious edit. Matching on the product filter as well would lose the
      # draft here and mint a second launch email beside it.
      draft.update!(not_bought_products: [])

      expect(launch_email.installment).to eq(draft)
      expect(seller.installments.alive.count).to eq(1)
      expect(launch_email.installment.not_bought_products).to be_blank
    end

    it "still recognises the draft the seller moved to another audience type" do
      draft = launch_email.installment
      # The editor's audience selector persists as installment_type, so "Customers only" is no
      # longer an audience-type email. Matching on the type would lose the draft and mint a twin.
      draft.update!(installment_type: Installment::SELLER_TYPE)

      expect(launch_email.installment).to eq(draft)
      expect(seller.installments.alive.count).to eq(1)
    end

    it "does not touch an email the seller has already scheduled" do
      draft = launch_email.installment
      draft.update!(ready_to_publish: true)
      product.update!(description: "<p>Changed after scheduling.</p>")

      expect(launch_email.installment).to eq(draft)
      expect(draft.reload.message).not_to include("Changed after scheduling")
      expect(draft.ready_to_publish?).to eq(true)
    end

    it "drafts nothing for a seller who cannot send emails yet" do
      allow(seller).to receive(:sales_cents_total).and_return(0)

      expect { launch_email.installment }.not_to change { Installment.count }
      expect(launch_email.installment).to be_nil
    end

    it "reports no draft instead of raising when the installment cannot be saved" do
      installments = double(alive: Installment.none, where: Installment.none)
      allow(installments).to receive(:new)
        .and_raise(ActiveRecord::RecordInvalid.new(Installment.new))
      allow(seller).to receive(:installments).and_return(installments)

      expect(launch_email.installment).to be_nil
    end
  end

  describe "#recipient_counts" do
    it "counts customers, followers and affiliates separately, both excluding the new product's buyers" do
      expect(AudienceMember).to receive(:filter_count)
        .with(seller_id: seller.id, params: { type: "customer", not_bought_product_ids: [product.id] })
        .and_return(4)
      expect(AudienceMember).to receive(:filter_count)
        .with(seller_id: seller.id, params: { type: "follower", not_bought_product_ids: [product.id] })
        .and_return(2)
      expect(AudienceMember).to receive(:filter_count)
        .with(seller_id: seller.id, params: { type: "affiliate", not_bought_product_ids: [product.id] })
        .and_return(1)
      expect(AudienceMember).to receive(:filter_count)
        .with(seller_id: seller.id, params: { not_bought_product_ids: [product.id] })
        .and_return(7)

      expect(launch_email.recipient_counts).to eq(customers: 4, followers: 2, affiliates: 1, total: 7)
    end

    it "takes the total from the draft itself once it exists" do
      launch_email.installment
      allow(AudienceMember).to receive(:filter_count).and_return(1)
      allow_any_instance_of(Installment).to receive(:audience_members_count).and_return(9)

      expect(launch_email.recipient_counts).to eq(customers: 1, followers: 1, affiliates: 1, total: 9)
    end
  end
end
