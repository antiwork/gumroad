# frozen_string_literal: true

require "spec_helper"

describe PartnerMigrationNotificationJob do
  let(:seller) { create(:user, email: "seller@example.com") }
  let(:partner_application) { create(:oauth_application, owner: create(:user), name: "Example App", is_partner: true, confidential: true, scopes: "partner_api") }
  let(:migration) do
    products, = PartnerMigration.normalize_products([{ name: "Texture Pack", price: 500 }, { name: "Brush Set", price: 500 }])
    migration, = PartnerMigration.create_for!(oauth_application: partner_application, external_user_id: "seller-1", products:)
    migration.claim!(seller, expected_code_digest: migration.code_digest)
    migration.update!(status: PartnerMigration::STATUS_COMPLETED, completed_at: Time.current, results: {
                        "0" => { "product_id" => "texture-pack" }, "1" => { "product_id" => "brush-set" },
                      })
    migration
  end

  it "emails the account once with a link and keeps import details behind authentication" do
    2.times { described_class.new.perform(migration.id) }

    mail = ActionMailer::Base.deliveries.sole
    body = Capybara.string(mail.html_part.body.decoded)
    expect(mail.to).to eq([seller.email])
    expect(mail.subject).to eq("Your import is ready to review")
    expect(body).to have_text("Your product import on Gumroad is ready to review.")
    expect(body).not_to have_text("Example App")
    expect(body).not_to have_text("Texture Pack")
    expect(body).to have_text("Imported products start as drafts.")
    status_url = Rails.application.routes.url_helpers.partner_migration_status_url(migration.status_id, host: DOMAIN, protocol: PROTOCOL)
    expect(body).to have_link("Review products", href: status_url)
    expect(migration.reload.notified_at).to be_present
  end

  it "reports a partial import and sends an updated result after a manual retry" do
    migration.update!(status: PartnerMigration::STATUS_FAILED, results: {
                        "0" => { "product_id" => "texture-pack" }, "1" => { "error" => "The file link expired." },
                      })
    described_class.new.perform(migration.id)

    mail = ActionMailer::Base.deliveries.sole
    body = Capybara.string(mail.html_part.body.decoded)
    expect(mail.subject).to eq("Your import needs attention")
    expect(body).to have_text("retry the products that did not import")

    migration.reload.retry!(seller)
    described_class.new.perform(migration.id)
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    expect(migration.reload).to have_attributes(notified_at: nil, completed_at: nil)

    migration.update!(status: PartnerMigration::STATUS_COMPLETED, completed_at: Time.current, results: {
                        "0" => { "product_id" => "texture-pack" }, "1" => { "product_id" => "brush-set" },
                      })
    described_class.new.perform(migration.id)

    expect(ActionMailer::Base.deliveries.size).to eq(2)
    expect(ActionMailer::Base.deliveries.last.subject).to eq("Your import is ready to review")
    expect(Capybara.string(ActionMailer::Base.deliveries.last.html_part.body.decoded)).to have_text("Your product import on Gumroad is ready to review.")
  end

  it "sends to the checked address if the account changes its email while the mailer starts" do
    migration
    recipient = seller.form_email
    allow(CreatorMailer).to receive(:partner_migration_finished).and_wrap_original do |original, id, **kwargs|
      seller.update!(email: "replacement@example.com")
      original.call(id, **kwargs)
    end

    described_class.new.perform(migration.id)

    expect(ActionMailer::Base.deliveries.sole.to).to eq([recipient])
  end

  it "retries a temporary email failure without recording a successful notification" do
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(Net::SMTPServerBusy.new("450 try later"))

    expect { described_class.new.perform(migration.id) }.to raise_error(Net::SMTPServerBusy)
    expect(migration.reload).to have_attributes(notified_at: nil, notification_failed_email: nil)

    allow_any_instance_of(Mail::Message).to receive(:deliver).and_call_original
    described_class.new.perform(migration.id)

    expect(ActionMailer::Base.deliveries.size).to eq(1)
    expect(migration.reload.notified_at).to be_present
  end

  it "stops retrying a permanent rejection without recording a successful notification" do
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(Net::SMTPFatalError.new("550 rejected"))

    2.times { described_class.new.perform(migration.id) }

    expect(ActionMailer::Base.deliveries).to be_empty
    expect(migration.reload).to have_attributes(notified_at: nil, notification_failed_email: seller.form_email)
  end

  it "recovers a rejected notification after the account changes its email" do
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(Net::SMTPFatalError.new("550 rejected"))
    described_class.new.perform(migration.id)
    seller.update!(email: "corrected@example.com")
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_call_original

    travel_to 15.minutes.from_now do
      DispatchPendingPartnerMigrationNotificationsJob.new.perform
      described_class.drain
    end

    expect(ActionMailer::Base.deliveries.sole.to).to eq(["corrected@example.com"])
    expect(migration.reload.notified_at).to be_present
  end

  it "uses the address shown for an account with a pending email confirmation" do
    migration
    seller.update_columns(email: nil, unconfirmed_email: "pending@example.com", provider: "apple")

    described_class.new.perform(migration.id)

    expect(ActionMailer::Base.deliveries.sole.to).to eq(["pending@example.com"])
  end

  it "keeps the notification pending if the account removes its email after the import starts" do
    migration
    seller.update_columns(email: nil, unconfirmed_email: nil, provider: "apple")

    described_class.new.perform(migration.id)

    expect(ActionMailer::Base.deliveries).to be_empty
    expect(migration.reload).to have_attributes(notified_at: nil, notification_failed_email: nil)
  end

  it "does not email a suspended account" do
    migration
    seller.update!(user_risk_state: "suspended_for_fraud")

    described_class.new.perform(migration.id)

    expect(ActionMailer::Base.deliveries).to be_empty
    expect(migration.reload.notified_at).to be_nil
  end
end
