# frozen_string_literal: true

require "spec_helper"

describe SaveInstallmentService do
  let(:seller) { create(:user) }
  let(:installment) { nil }
  let(:product) { create(:product, user: seller) }
  let(:params) do
    ActionController::Parameters.new(
      installment: {
        affiliate_products: nil,
        allow_comments: true,
        bought_from: "United States",
        bought_products: [product.unique_permalink],
        bought_variants: [],
        created_after: "2024-01-01",
        created_before: "2024-01-31",
        files: [{ external_id: SecureRandom.uuid, stream_only: false, subtitles: [], url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/some-url.txt" }],
        installment_type: "product",
        link_id: product.unique_permalink,
        message: "<p>Hello, world!</p>",
        name: "Hello",
        not_bought_products: [],
        not_bought_variants: [],
        paid_less_than_cents: 2000,
        paid_more_than_cents: 1000,
        send_emails: true,
        shown_on_profile: true,
      },
      publish: false,
      send_preview_email: false,
      to_be_published_at: nil,
      variant_external_id: nil,
      shown_in_profile_sections: [],
    )
  end
  let(:preview_email_recipient) { seller }

  before do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:payment_completed, user: seller)
  end

  shared_examples_for "updates profile posts sections" do
    it "updates profile posts sections based on 'shown_in_profile_sections' param" do
      section1 = create(:seller_profile_posts_section, seller:, shown_posts: [2000, 3000])
      section2 = create(:seller_profile_posts_section, seller:, shown_posts: [])
      section3 = create(:seller_profile_posts_section, seller:, shown_posts: [2000, 3000])

      if installment.present?
        section1.update!(shown_posts: [installment.id, 2000, 3000])
      end

      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { shown_in_profile_sections: [section2.external_id, section3.external_id] }), preview_email_recipient:)
      service.process

      expect(section1.reload.shown_posts).to eq([2000, 3000])
      expect(section2.reload.shown_posts).to eq([Installment.last.id])
      expect(section3.reload.shown_posts).to eq([2000, 3000, Installment.last.id])
    end
  end

  context "when installment is nil" do
    it "creates a product-type installment" do
      service = described_class.new(seller:, installment:, params:, preview_email_recipient:)
      expect do
        service.process
      end.to change { Installment.count }.by(1)

      expect(service.error).to be_nil
      installment = Installment.last
      expect(service.installment).to eq(installment)
      expect(installment.seller).to eq(seller)
      expect(installment.name).to eq("Hello")
      expect(installment.product_type?).to be(true)
      expect(installment.link).to eq(product)
      expect(installment.bought_from).to eq("United States")
      expect(installment.bought_products).to eq([product.unique_permalink])
      expect(installment.bought_variants).to be_nil
      expect(installment.created_after.to_date).to eq(Date.parse("2024-01-01"))
      expect(installment.created_before.to_date).to eq(Date.parse("2024-01-31"))
      expect(installment.paid_less_than_cents).to eq(2000)
      expect(installment.paid_more_than_cents).to eq(1000)
      expect(installment.send_emails).to be(true)
      expect(installment.shown_on_profile).to be(true)
      expect(installment.published?).to be(false)
      expect(installment.product_files.sole.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/some-url.txt")
    end

    it "creates a variant-type installment" do
      variant = create(:variant, variant_category: create(:variant_category, link: product))

      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { installment_type: "variant", bought_variants: [variant.external_id], bought_products: [] }, variant_external_id: variant.external_id), preview_email_recipient:)
      service.process

      expect(service.error).to be_nil
      installment = service.installment
      expect(installment.variant_type?).to be(true)
      expect(installment.bought_variants).to eq([variant.external_id])
      expect(installment.bought_products).to be_nil
      expect(installment.link).to eq(product)
      expect(installment.base_variant).to eq(variant)
    end

    it "creates a seller-type installment" do
      product2 = create(:product, user: seller)
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { installment_type: "seller", link_id: nil, bought_products: [product.unique_permalink, product2.unique_permalink] }), preview_email_recipient:)
      service.process

      expect(service.error).to be_nil
      installment = service.installment
      expect(installment.seller_type?).to be(true)
      expect(installment.bought_products).to eq([product.unique_permalink, product2.unique_permalink])
    end

    it "creates an audience-type installment" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { installment_type: "audience", link_id: nil, bought_products: nil, not_bought_products: [product.unique_permalink] }), preview_email_recipient:)
      service.process

      expect(service.error).to be_nil
      installment = service.installment
      expect(installment.audience_type?).to be(true)
      expect(installment.bought_products).to be_nil
      expect(installment.not_bought_products).to eq([product.unique_permalink])
    end

    it "creates a follower-type installment" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { installment_type: "follower", link_id: nil }), preview_email_recipient:)
      service.process

      expect(service.error).to be_nil
      installment = service.installment
      expect(installment.follower_type?).to be(true)
      expect(installment.bought_products).to eq([product.unique_permalink])
    end

    it "creates a affiliate-type installment" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { installment_type: "affiliate", link_id: nil, affiliate_products: [product.unique_permalink], bought_products: nil }), preview_email_recipient:)
      service.process

      expect(service.error).to be_nil
      installment = service.installment
      expect(installment.affiliate_type?).to be(true)
      expect(installment.bought_products).to be_nil
      expect(installment.affiliate_products).to eq([product.unique_permalink])
    end

    it "creates and publishes the installment" do
      service = described_class.new(seller:, installment:, params: params.merge(publish: true), preview_email_recipient:)
      service.process

      expect(service.error).to be_nil
      expect(service.installment.published?).to be(true)
      expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
    end

    it "publishes the installment but does not send emails" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(publish: true, installment: { send_emails: false }), preview_email_recipient:)
      service.process

      expect(service.error).to be_nil
      expect(service.installment.published?).to be(true)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
    end

    it "creates and sends a preview email" do
      allow(PostSendgridApi).to receive(:process).and_call_original

      service = described_class.new(seller:, installment:, params: params.merge(send_preview_email: true), preview_email_recipient:)
      service.process

      expect(service.error).to be_nil
      expect(service.installment.published?).to be(false)
      expect(PostSendgridApi).to have_received(:process).with(
        post: service.installment,
        recipients: [{
          email: seller.email,
          url_redirect: service.installment.url_redirects.sole,
        }],
        preview: true,
      )
    end

    it "sends a preview email to the impersonated user" do
      gumroad_admin = create(:admin_user)
      expect_any_instance_of(Installment).to receive(:send_preview_email).with(gumroad_admin)

      service = described_class.new(seller:, installment:, params: params.merge(send_preview_email: true), preview_email_recipient: gumroad_admin)
      service.process
    end

    it "returns an error while previewing an email if the logged-in user has uncofirmed email" do
      seller.update_attribute(:unconfirmed_email, "john@example.com")
      expect(PostSendgridApi).to_not receive(:process)

      service = described_class.new(seller:, installment:, params: params.merge(send_preview_email: true), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { Installment.count }

      expect(service.error).to eq("You have to confirm your email address before you can do that.")
    end

    it "creates and schedules the installment" do
      freeze_time do
        service = described_class.new(seller:, installment:, params: params.merge(to_be_published_at: 1.day.from_now.to_s), preview_email_recipient:)
        expect do
          service.process
        end.to change { Installment.count }.by(1)
           .and change { InstallmentRule.count }.by(1)

        expect(service.error).to be_nil
        expect(service.installment.published?).to be(false)
        expect(service.installment.ready_to_publish?).to be(true)
        expect(PublishScheduledPostJob).to have_enqueued_sidekiq_job(service.installment.id, 1).at(1.day.from_now)
      end
    end

    it "returns an error if the schedule date is in past" do
      service = described_class.new(seller:, installment:, params: params.merge(to_be_published_at: 1.day.ago.to_s), preview_email_recipient:)
      expect do
        service.process
      end.to not_change { Installment.count }
         .and not_change { InstallmentRule.count }

      expect(service.error).to eq("Please select a date and time in the future.")
    end

    it "returns an error if no channel is provided" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { send_emails: nil, shown_on_profile: nil }), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { Installment.count }

      expect(service.error).to eq("Please set at least one channel for your update.")
    end

    it "returns an error if paid more than is greater than paid less than" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { paid_more_than_cents: 5000 }), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { Installment.count }

      expect(service.error).to eq("Please enter valid paid more than and paid less than values.")
    end

    it "returns an error if bought after date is after bought before date" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { created_after: "2024-01-31", created_before: "2024-01-01" }), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { Installment.count }

      expect(service.error).to eq("Please enter valid before and after dates.")
    end

    it "returns an error if the message is missing" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { message: nil }), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { Installment.count }

      expect(service.error).to eq("Please include a message as part of the update.")
    end

    it "invokes SaveContentUpsellsService with correct arguments" do
      expect(SaveContentUpsellsService).to receive(:new).with(seller:, content: "<p>Hello, world!</p>", old_content: nil).and_call_original

      service = described_class.new(seller:, installment:, params:, preview_email_recipient:)
      service.process
    end

    include_examples "updates profile posts sections"
  end

  context "when installment is present" do
    let(:installment) { create(:installment, seller:, installment_type: "seller") }

    it "updates the installment" do
      service = described_class.new(seller:, installment:, params:, preview_email_recipient:)
      expect do
        service.process
      end.to change { installment.reload.installment_type }.to("product")

      expect(service.error).to be_nil
      expect(installment.name).to eq("Hello")
      expect(installment.message).to eq("<p>Hello, world!</p>")
      expect(installment.link).to eq(product)
      expect(installment.seller).to eq(seller)
      expect(installment.bought_products).to eq([product.unique_permalink])
      expect(installment.bought_variants).to be_nil
      expect(installment.bought_from).to eq("United States")
      expect(installment.paid_less_than_cents).to eq(2000)
      expect(installment.paid_more_than_cents).to eq(1000)
      expect(installment.created_after.to_date).to eq(Date.parse("2024-01-01"))
      expect(installment.created_before.to_date).to eq(Date.parse("2024-01-31"))
      expect(installment.send_emails).to be(true)
      expect(installment.shown_on_profile).to be(true)
      expect(installment.published?).to be(false)
      expect(installment.product_files.sole.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/some-url.txt")
    end

    it "marks the old file as deleted" do
      installment.product_files.create!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/old-url.txt")
      service = described_class.new(seller:, installment:, params:, preview_email_recipient:)
      expect do
        service.process
      end.to change { installment.reload.product_files.count }.from(1).to(2)
      expect(installment.product_files.alive.sole.url).to eq("#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/some-url.txt")
      expect(service.error).to be_nil
    end

    it "removes the existing files" do
      installment.product_files.create!(url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/old-url.txt")
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { files: [] }), preview_email_recipient:)
      expect do
        service.process
      end.to change { installment.reload.product_files.alive.count }.from(1).to(0)

      expect(service.error).to be_nil
    end

    it "updates and publishes the installment" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(publish: true), preview_email_recipient:)
      expect do
        service.process
      end.to change { installment.reload.published? }.from(false).to(true)

      expect(service.error).to be_nil
      expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(PostEmailBlast.last.id)
      expect(installment.name).to eq("Hello")
    end

    it "returns an error while publishing an installment if the seller is not eligible to send emails" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

      service = described_class.new(seller:, installment:, params: params.deep_merge(publish: true), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { installment.reload.published? }

      expect(service.error).to eq("You are not eligible to publish or schedule emails. Please ensure you have made at least $100 in sales and received a payout.")
      expect(SendPostBlastEmailsJob.jobs).to be_empty
    end

    it "updates and publishes the installment but does not send emails" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

      service = described_class.new(seller:, installment:, params: params.deep_merge(publish: true, installment: { send_emails: false }), preview_email_recipient:)
      expect do
        service.process
      end.to change { installment.reload.published? }.from(false).to(true)

      expect(service.error).to be_nil
      expect(installment.reload.published?).to be(true)
      expect(SendPostBlastEmailsJob.jobs).to be_empty
      expect(installment.name).to eq("Hello")
    end

    it "allows updating only certain attributes for a published installment" do
      freeze_time do
        installment.update!(published_at: 10.days.ago, shown_on_profile: false, send_emails: true, allow_comments: false)

        service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { published_at: 2.days.ago.to_date.to_s, send_emails: false }), preview_email_recipient:)
        expect do
          service.process
          puts service.error
        end.to change { installment.reload.published_at }.from(10.days.ago).to(2.days.ago.to_date)
          .and change { installment.name }.to("Hello")
          .and change { installment.message }.to("<p>Hello, world!</p>")
          .and change { installment.shown_on_profile }.from(false).to(true)
          .and change { installment.send_emails }.from(true).to(false)
          .and change { installment.allow_comments }.from(false).to(true)
          .and not_change { installment.installment_type }
          .and not_change { installment.bought_products }
          .and not_change { installment.bought_variants }
          .and not_change { installment.bought_from }
          .and not_change { installment.paid_less_than_cents }
          .and not_change { installment.paid_more_than_cents }
          .and not_change { installment.created_after }
          .and not_change { installment.created_before }

        expect(service.error).to be_nil
      end
    end

    it "does not allow updating 'send_emails' if it has been published and already blasted" do
      create(:blast, post: installment)
      installment.update!(published_at: 10.days.ago, send_emails: true)

      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { send_emails: false }), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { installment.reload.send_emails }

      expect(service.error).to be_nil
    end

    it "updates the installment but do not change the publish date if it is unchanged for a published installment" do
      installment.update!(published_at: 10.days.ago)

      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { published_at: 10.days.ago.to_date.to_s }), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { installment.reload.published_at }

      expect(service.error).to be_nil
      expect(installment.reload.published?).to be(true)
      expect(installment.name).to eq("Hello")
    end

    it "does not allow a future publish date for an already published installment" do
      installment.update!(published_at: 1.day.ago)

      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { published_at: 1.day.from_now.to_date.to_s }), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { installment.reload.published_at }

      expect(service.error).to eq("Please enter a publish date in the past.")
      expect(installment.name).to_not eq("Hello")
    end

    it "updates the installment and sends a preview email" do
      allow(PostSendgridApi).to receive(:process).and_call_original

      service = described_class.new(seller:, installment:, params: params.deep_merge(send_preview_email: true), preview_email_recipient:)
      service.process

      expect(service.error).to be_nil
      expect(installment.reload.published?).to be(false)
      expect(installment.name).to eq("Hello")
      expect(PostSendgridApi).to have_received(:process).with(
        post: installment,
        recipients: [{
          email: preview_email_recipient.email,
          url_redirect: installment.url_redirects.sole,
        }],
        preview: true,
      )
    end

    it "returns an error while previewing an email if the logged-in user has uncofirmed email" do
      seller.update_attribute(:unconfirmed_email, "john@example.com")
      expect(PostSendgridApi).to_not receive(:process)

      service = described_class.new(seller:, installment:, params: params.deep_merge(send_preview_email: true), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { installment.reload }

      expect(service.error).to eq("You have to confirm your email address before you can do that.")
    end

    it "updates the installment and schedules the installment" do
      freeze_time do
        service = described_class.new(seller:, installment:, params: params.merge(to_be_published_at: 1.day.from_now.to_s), preview_email_recipient:)
        expect do
          service.process
        end.to change { InstallmentRule.count }.by(1)

        expect(service.error).to be_nil
        expect(installment.reload.published?).to be(false)
        expect(installment.ready_to_publish?).to be(true)
        expect(PublishScheduledPostJob).to have_enqueued_sidekiq_job(installment.id, 1).at(1.day.from_now)
      end
    end

    it "returns an error while scheduling an installment if the seller is not eligible to send emails" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

      service = described_class.new(seller:, installment:, params: params.merge(to_be_published_at: 1.day.from_now.to_s), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { installment.reload }

      expect(service.error).to eq("You are not eligible to publish or schedule emails. Please ensure you have made at least $100 in sales and received a payout.")
      expect(PublishScheduledPostJob.jobs).to be_empty
    end

    it "updates the installment and changes the existing schedule time of an already scheduled installment" do
      freeze_time do
        installment_rule = create(:installment_rule, installment:, to_be_published_at: 1.day.from_now)

        service = described_class.new(seller:, installment:, params: params.merge(to_be_published_at: 15.day.from_now.to_s), preview_email_recipient:)
        expect do
          service.process
        end.to change { installment_rule.reload.to_be_published_at }.from(1.day.from_now).to(15.days.from_now)

        expect(service.error).to be_nil
        expect(installment.reload.name).to eq("Hello")
        expect(installment.published?).to be(false)
        expect(installment.ready_to_publish?).to be(true)
        expect(PublishScheduledPostJob).to have_enqueued_sidekiq_job(installment.id, 2).at(15.days.from_now)
      end
    end

    it "returns an error if the schedule date is in past" do
      service = described_class.new(seller:, installment:, params: params.merge(to_be_published_at: 1.day.ago.to_s), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { installment.reload }

      expect(service.error).to eq("Please select a date and time in the future.")
    end

    it "returns an error while scheduling if the seller has not confirmed their email address" do
      seller.update!(confirmed_at: nil)

      service = described_class.new(seller:, installment:, params: params.merge(to_be_published_at: 1.day.from_now.to_s), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { installment.reload }

      expect(service.error).to eq("You have to confirm your email address before you can do that.")
    end

    it "returns an error if paid more than is greater than paid less than" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { paid_more_than_cents: 5000 }), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { installment.reload }

      expect(service.error).to eq("Please enter valid paid more than and paid less than values.")
    end

    it "returns an error if bought after date is after bought before date" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { created_after: "2024-01-31", created_before: "2024-01-01" }), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { installment.reload }

      expect(service.error).to eq("Please enter valid before and after dates.")
    end

    it "returns an error if the message is missing" do
      service = described_class.new(seller:, installment:, params: params.deep_merge(installment: { message: nil }), preview_email_recipient:)
      expect do
        service.process
      end.to_not change { installment.reload }

      expect(service.error).to eq("Please include a message as part of the update.")
    end

    include_examples "updates profile posts sections"
  end
end
