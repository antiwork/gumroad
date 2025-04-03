# frozen_string_literal: true

require "spec_helper"

describe Onetime::EmailCreatorsQuarterlyRecap do
  let(:start_time) { 89.days.ago }
  let(:end_time) { 1.day.from_now }
  let(:installment) { create(:installment, allow_comments: false) }
  let(:service) { described_class.new(installment_external_id: installment&.external_id, start_time:, end_time:) }

  it "sends an email to users with a sale in the last 90 days" do
    purchase = create(:purchase)

    expect do
      service.process
    end.to have_enqueued_mail(OneOffMailer, :email_using_installment).with(
      email: purchase.seller.form_email,
      installment_external_id: installment.external_id,
      reply_to: described_class::DEFAULT_REPLY_TO_EMAIL
    ).once
  end

  it "does not send an email to users with no sales in the last 90 days" do
    create(:purchase, created_at: 100.days.ago)

    expect do
      service.process
    end.to_not have_enqueued_mail(OneOffMailer, :email_using_installment)
  end

  it "does not send an email to deleted or suspended users" do
    deleted_user = create(:user, :deleted)
    deleted_user_product = create(:product, user: deleted_user)
    tos_user = create(:tos_user)
    tos_user_product = create(:product, user: tos_user)
    create(:purchase, created_at: 100.days.ago)
    create(:purchase, seller: deleted_user, link: deleted_user_product)
    create(:purchase, seller: tos_user, link: tos_user_product)

    expect do
      service.process
    end.to_not have_enqueued_mail(OneOffMailer, :email_using_installment)
  end

  context "when the provided installment is not found" do
    let(:installment) { nil }

    it "does not send the email" do
      create(:purchase)

      expect do
        service.process
      end.to raise_error("Installment not found")
    end
  end

  it "does not send the email if the provided installment is published" do
    create(:purchase)
    installment.update!(published_at: Time.current)

    expect do
      service.process
    end.to raise_error("Installment must not be published or scheduled to publish")
  end

  it "does not send the email if the installment allows comments" do
    create(:purchase)
    installment.update!(allow_comments: true)

    expect do
      service.process
    end.to raise_error("Installment must not allow comments")
  end

  context "when the provided time range is too short" do
    let(:start_time) { 10.days.ago }

    it "does not send the email" do
      create(:purchase)

      expect do
        service.process
      end.to raise_error("Date range must be at least 85 days")
    end
  end

  it "skips sending the email to users in the skip_user_ids list" do
    purchase1 = create(:purchase)
    purchase2 = create(:purchase)

    expect do
      expect do
        described_class.new(installment_external_id: installment.external_id, start_time:, end_time:, skip_user_ids: [purchase1.seller.id]).process
      end.to have_enqueued_mail(OneOffMailer, :email_using_installment).with(installment_external_id: installment.external_id, email: purchase2.seller.form_email, reply_to: described_class::DEFAULT_REPLY_TO_EMAIL)
    end.to_not have_enqueued_mail(OneOffMailer, :email_using_installment).with(installment_external_id: installment.external_id, email: purchase1.seller.form_email, reply_to: described_class::DEFAULT_REPLY_TO_EMAIL)
  end
end
