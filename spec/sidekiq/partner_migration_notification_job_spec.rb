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

  it "does not email a new account again when its import completes, because the setup email covered it" do
    migration.update!(account_created: true, account_setup_token_digest: "pending")

    described_class.new.perform(migration.id)

    expect(ActionMailer::Base.deliveries).to be_empty
    expect(migration.reload.notified_at).to be_present
  end

  it "emails a new account whose setup link expired, so the seller still hears that the import finished" do
    migration.update!(account_created: true, account_setup_token_digest: "pending", claimed_at: (PartnerMigration::ACCOUNT_SETUP_EXPIRES_IN + 1.minute).ago)

    described_class.new.perform(migration.id)

    expect(ActionMailer::Base.deliveries.sole.subject).to eq("Your products are ready to review")
  end

  it "emails a new account that already set its password, for example after a retry" do
    migration.update!(account_created: true, account_setup_token_digest: nil)

    described_class.new.perform(migration.id)

    expect(ActionMailer::Base.deliveries.sole.subject).to eq("Your products are ready to review")
  end

  it "emails a new account when its import needs attention" do
    migration.update!(account_created: true, account_setup_token_digest: "pending", status: PartnerMigration::STATUS_FAILED)

    described_class.new.perform(migration.id)

    mail = ActionMailer::Base.deliveries.sole
    expect(mail.subject).to eq("Some products did not import")
    expect(Capybara.string(mail.html_part.body.decoded)).to have_text("first set your password with the link in the email \"Your Gumroad account is ready\"")
  end

  it "emails the account once with a link and keeps import details behind authentication" do
    2.times { described_class.new.perform(migration.id) }

    mail = ActionMailer::Base.deliveries.sole
    body = Capybara.string(mail.html_part.body.decoded)
    expect(mail.to).to eq([seller.email])
    expect(mail.subject).to eq("Your products are ready to review")
    expect(body).to have_text("Your products from Example App are on Gumroad as drafts.")
    expect(body).not_to have_text("Texture Pack")
    products_url = Rails.application.routes.url_helpers.products_url(host: DOMAIN, protocol: PROTOCOL)
    expect(body).to have_link("Review drafts", href: products_url)
    expect(migration.reload.notified_at).to be_present
  end

  it "reports a partial import and sends an updated result after an automatic retry" do
    migration.update!(status: PartnerMigration::STATUS_FAILED, results: {
                        "0" => { "product_id" => "texture-pack" }, "1" => { "error" => "The file link expired." },
                      })
    described_class.new.perform(migration.id)

    mail = ActionMailer::Base.deliveries.sole
    body = Capybara.string(mail.html_part.body.decoded)
    expect(mail.subject).to eq("Some products did not import")
    expect(body).to have_text("We try them again when Example App sends them again.")

    migration.reload.retry_failed_products!
    described_class.new.perform(migration.id)
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    expect(migration.reload).to have_attributes(notified_at: nil, completed_at: nil)

    migration.update!(status: PartnerMigration::STATUS_COMPLETED, completed_at: Time.current, results: {
                        "0" => { "product_id" => "texture-pack" }, "1" => { "product_id" => "brush-set" },
                      })
    described_class.new.perform(migration.id)

    expect(ActionMailer::Base.deliveries.size).to eq(2)
    expect(ActionMailer::Base.deliveries.last.subject).to eq("Your products are ready to review")
  end

  it "emails a failure once, however often the partner sends the export again" do
    failed_results = { "0" => { "product_id" => "texture-pack" }, "1" => { "error" => "The file link expired." } }
    migration.update!(status: PartnerMigration::STATUS_FAILED, results: failed_results)
    described_class.new.perform(migration.id)

    2.times do
      migration.reload.retry_failed_products!
      migration.update!(status: PartnerMigration::STATUS_FAILED, completed_at: Time.current, results: failed_results)
      described_class.new.perform(migration.id)
    end

    expect(ActionMailer::Base.deliveries.map(&:subject)).to eq(["Some products did not import"])
    expect(migration.reload.notified_at).to be_present
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
