# frozen_string_literal: true

require "spec_helper"

describe PartnerMigration do
  let(:partner_application) { create(:oauth_application, owner: create(:user), name: "Example App", is_partner: true, confidential: true, scopes: "partner_api") }
  let(:product_attributes) { { external_product_id: "Texture Pack", name: "Texture Pack", price: 1500 } }
  let(:seller) { create(:user) }

  def create_migration(external_user_id: "ext-1")
    products, _error = described_class.normalize_products([product_attributes])
    described_class.create_for!(oauth_application: partner_application, external_user_id:, products:)
  end

  describe ".normalize_products" do
    it "keeps only the supported keys and fills in defaults" do
      products, error = described_class.normalize_products([product_attributes.merge(unknown: "x", variant_categories: [{ title: "License", variants: [{ name: "Standard" }] }])])

      expect(error).to be_nil
      expect(products).to eq([{
                               "external_product_id" => "Texture Pack",
                               "name" => "Texture Pack",
                               "description" => nil,
                               "price" => 1500,
                               "price_currency_type" => "usd",
                               "taxonomy_id" => nil,
                               "tags" => [],
                               "files" => [],
                               "covers" => [],
                               "thumbnail_url" => nil,
                               "is_adult" => false,
                               "variant_categories" => [{ "title" => "License", "variants" => [{ "name" => "Standard", "price_difference_cents" => 0 }] }],
                             }])
    end

    it "rejects an empty list" do
      expect(described_class.normalize_products([])).to eq([nil, "products must be an array with 1 to #{described_class::MAX_PRODUCTS} items."])
    end

    it "names the product that is not valid" do
      _products, error = described_class.normalize_products([product_attributes, { external_product_id: "No price", name: "No price" }])

      expect(error).to eq("products[1]: price must be a whole number of cents, 0 or more.")
    end

    it "rejects a file URL that is not https" do
      _products, error = described_class.normalize_products([product_attributes.merge(files: [{ url: "http://files.example.com/pack.zip" }])])

      expect(error).to eq("products[0]: each file in files needs an https url and an optional display_name string.")
    end

    it "rejects more than one variant category" do
      category = { title: "License", variants: [{ name: "Standard" }] }
      _products, error = described_class.normalize_products([product_attributes.merge(variant_categories: [category, category])])

      expect(error).to eq("products[0]: variant_categories must be an array with up to 1 item.")
    end

    it "rejects a variant price difference above the maximum price" do
      category = { title: "License", variants: [{ name: "Commercial", price_difference_cents: BasePrice::Shared::MAX_PRICE_CENTS + 1 }] }
      _products, error = described_class.normalize_products([product_attributes.merge(variant_categories: [category])])

      expect(error).to eq("products[0]: each variant needs a name string and a whole number price_difference_cents from 0 to #{BasePrice::Shared::MAX_PRICE_CENTS}.")
    end

    it "rejects blank and oversized variant names and category titles" do
      ["", " ", "x" * (described_class::MAX_NAME_LENGTH + 1)].each do |name|
        category = { title: "License", variants: [{ name: }] }
        expect(described_class.normalize_products([product_attributes.merge(variant_categories: [category])]).last).to include("variant name")
        category = { title: name, variants: [{ name: "Standard" }] }
        expect(described_class.normalize_products([product_attributes.merge(variant_categories: [category])]).last).to include("variant category title")
      end
    end

    it "rejects a combined product and variant price above the stored range" do
      category = { title: "License", variants: [{ name: "Commercial", price_difference_cents: BasePrice::Shared::MAX_PRICE_CENTS }] }

      expect(described_class.normalize_products([product_attributes.merge(variant_categories: [category])]).last).to include("product price plus each variant")
    end

    it "rejects a file display name that would be truncated" do
      product = product_attributes.merge(files: [{ url: "https://files.example.com/pack.zip", display_name: "x" * (described_class::MAX_NAME_LENGTH + 1) }])

      expect(described_class.normalize_products([product]).last).to include("file display_name")
    end

    it "rejects a price above the maximum price" do
      _products, error = described_class.normalize_products([product_attributes.merge(price: BasePrice::Shared::MAX_PRICE_CENTS + 1)])

      expect(error).to eq("products[0]: price must be at most #{BasePrice::Shared::MAX_PRICE_CENTS} cents.")
    end

    it "requires an external_product_id that no other product in the export uses" do
      expect(described_class.normalize_products([product_attributes.except(:external_product_id)]).last).to start_with("products[0]: external_product_id must be a string")
      expect(described_class.normalize_products([product_attributes.merge(external_product_id: " ")]).last).to start_with("products[0]: external_product_id must be a string")
      expect(described_class.normalize_products([product_attributes, product_attributes.merge(name: "Copy")]).last).to eq('external_product_id "Texture Pack" appears more than once.')
      longest = "x" * described_class::MAX_EXTERNAL_USER_ID_LENGTH
      expect(described_class.normalize_products([product_attributes.merge(external_product_id: longest)]).last).to be_nil
      expect(described_class.normalize_products([product_attributes.merge(external_product_id: " #{longest}")]).last).to start_with("products[0]: external_product_id must be a string")
    end

    it "keeps the adult flag, and rejects a value that is not true or false" do
      products, = described_class.normalize_products([product_attributes.merge(is_adult: true)])

      expect(products.first["is_adult"]).to be(true)
      expect(described_class.normalize_products([product_attributes.merge(is_adult: "yes")]).last).to eq("products[0]: is_adult must be true or false.")
    end

    it "keeps a short description and its own files on each variant" do
      variants = [
        { name: "Standard", description: "Personal and client work." },
        { name: "Extended", price_difference_cents: 3000, files: [{ url: "https://files.example.com/extended.zip", display_name: "Extended" }] },
      ]
      products, error = described_class.normalize_products([product_attributes.merge(variant_categories: [{ title: "License", variants: }])])

      expect(error).to be_nil
      expect(products.first["variant_categories"].first["variants"]).to eq([
                                                                             { "name" => "Standard", "description" => "Personal and client work.", "price_difference_cents" => 0 },
                                                                             { "name" => "Extended", "price_difference_cents" => 3000, "files" => [{ "url" => "https://files.example.com/extended.zip", "display_name" => "Extended" }] },
                                                                           ])
      long_description = [{ name: "Standard", description: "x" * (described_class::MAX_VARIANT_DESCRIPTION_LENGTH + 1) }]
      expect(described_class.normalize_products([product_attributes.merge(variant_categories: [{ title: "License", variants: long_description }])]).last).to start_with("products[0]: variant description must be")
      http_files = [{ name: "Extended", files: [{ url: "http://files.example.com/extended.zip" }] }]
      expect(described_class.normalize_products([product_attributes.merge(variant_categories: [{ title: "License", variants: http_files }])]).last).to start_with("products[0]: each file in variant files needs an https url")
    end

    it "counts each file URL once across the product and its variants" do
      files = Array.new(described_class::MAX_FILES_PER_PRODUCT) { { url: "https://files.example.com/#{_1}.zip" } }
      shared = [{ name: "Standard", files: files.first(10) }]
      _products, error = described_class.normalize_products([product_attributes.merge(files:, variant_categories: [{ title: "License", variants: shared }])])
      expect(error).to be_nil

      _products, error = described_class.normalize_products([product_attributes.merge(files: files + files.first(1))])
      expect(error).to be_nil

      extra = [{ name: "Extended", files: [{ url: "https://files.example.com/extra.zip" }] }]
      _products, error = described_class.normalize_products([product_attributes.merge(files:, variant_categories: [{ title: "License", variants: extra }])])
      expect(error).to eq("products[0]: a product can have up to #{described_class::MAX_FILES_PER_PRODUCT} different file URLs, counting its variants.")
    end

    it "rejects more tags than a product can have" do
      tags = Array.new(described_class::MAX_TAGS_PER_PRODUCT + 1) { "tag#{_1}" }
      _products, error = described_class.normalize_products([product_attributes.merge(tags:)])

      expect(error).to eq("products[0]: tags must be an array of up to #{described_class::MAX_TAGS_PER_PRODUCT} strings.")
    end

    it "rejects a price below the currency's minimum" do
      _products, error = described_class.normalize_products([product_attributes.merge(price: 50)])

      expect(error).to eq("products[0]: price must be 0 or at least 99 cents in usd.")
    end

    it "cleans tags the way products save them and drops duplicates" do
      products, _error = described_class.normalize_products([product_attributes.merge(tags: [" Art ", "art", "Digital  Art"])])

      expect(products.first["tags"]).to eq(["art", "digital art"])
    end

    it "drops tags that the tags table treats as the same name" do
      products, _error = described_class.normalize_products([product_attributes.merge(tags: ["café", "cafe", "straße", "strasse"])])

      expect(products.first["tags"]).to eq(["café", "straße"])
    end

    it "rejects a tag that a product cannot use" do
      _products, error = described_class.normalize_products([product_attributes.merge(tags: ["textures", "x" * 21])])

      expect(error).to eq("products[0]: tags: A tag is too long. Please try again with a shorter one, under 20 characters.")
    end

    it "rejects an unknown taxonomy" do
      _products, error = described_class.normalize_products([product_attributes.merge(taxonomy_id: 0)])

      expect(error).to eq("products[0]: taxonomy_id is not a known category.")
    end
  end

  describe ".normalize_seller" do
    it "keeps the email in lower case and only the supported profile keys" do
      seller, error = described_class.normalize_seller(email: " Seller@Example.com ", profile: { name: " Ada ", bio: "3D artist", avatar_url: "https://files.example.com/a.png", unknown: "x" })

      expect(error).to be_nil
      expect(seller).to eq(email: "seller@example.com", profile: { "name" => "Ada", "bio" => "3D artist", "avatar_url" => "https://files.example.com/a.png" })
    end

    it "accepts an export without an email or a profile" do
      expect(described_class.normalize_seller(email: nil, profile: nil)).to eq([{ email: nil, profile: nil }, nil])
    end

    it "rejects an email that is not valid" do
      _seller, error = described_class.normalize_seller(email: "not-an-email", profile: nil)

      expect(error).to eq("email must be a valid email address with at most 255 characters.")
    end

    it "rejects profile values that a Gumroad profile cannot hold" do
      expect(described_class.normalize_seller(email: nil, profile: { name: "a" * 101 }).last).to start_with("profile.name")
      expect(described_class.normalize_seller(email: nil, profile: { name: "Ada: 3D" }).last).to start_with("profile.name")
      expect(described_class.normalize_seller(email: nil, profile: { bio: "a" * 5_001 }).last).to start_with("profile.bio")
      expect(described_class.normalize_seller(email: nil, profile: { avatar_url: "http://files.example.com/a.png" }).last).to start_with("profile.avatar_url")
    end
  end

  describe "#create_account_and_claim!" do
    def create_migration_for(email, profile: nil)
      products, _error = described_class.normalize_products([product_attributes])
      described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:, email:, profile:).first
    end

    it "creates the account, claims the import, and sends only the setup email" do
      migration = create_migration_for("new-seller@example.com", profile: { "name" => "Ada", "bio" => "3D artist" })

      expect do
        expect(migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)).to be_nil
      end.to have_enqueued_mail(CreatorMailer, :partner_migration_account_setup)

      user = User.find_by!(email: "new-seller@example.com")
      expect(user).to have_attributes(name: "Ada", bio: "3D artist", account_created_ip: "203.0.113.10", confirmed?: false)
      expect(migration.reload).to have_attributes(status: described_class::STATUS_CLAIMED, user:, account_created: true, account_setup_pending?: true)
      expect(partner_application.partner_sellers.sole.user).to eq(user)
      expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(migration.id)
    end

    it "does not send Devise's confirmation email, because the setup email confirms the address" do
      migration = create_migration_for("new-seller@example.com")

      expect { migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest) }.not_to have_enqueued_mail(UserSignupMailer, :confirmation_instructions)
    end

    it "turns announcements off for a Canadian address, as signup does" do
      migration = create_migration_for("new-seller@example.com")
      allow(GeoIp).to receive(:lookup).and_call_original
      allow(GeoIp).to receive(:lookup).with("203.0.113.10").and_return(double(country_code: Compliance::Countries::CAN.alpha2))

      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)

      expect(User.find_by!(email: "new-seller@example.com").announcement_notification_enabled).to be(false)
    end

    it "returns a message for the seller when the partner user ID is linked to another account" do
      PartnerSeller.create!(oauth_application: partner_application, user: create(:user), external_user_id: "ext-1")
      migration = create_migration_for("new-seller@example.com")

      expect(migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)).to eq("This Example App account is already linked to a different Gumroad account.")
      expect(User.where(email: "new-seller@example.com")).to be_empty
    end

    it "keeps the setup token out of the mail job in plain text" do
      migration = create_migration_for("new-seller@example.com")
      encrypted_tokens = []
      allow(CreatorMailer).to receive(:partner_migration_account_setup).and_wrap_original do |original, id, encrypted_token|
        encrypted_tokens << encrypted_token
        original.call(id, encrypted_token)
      end

      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)

      token = described_class.decrypt_account_setup_token(encrypted_tokens.sole)
      expect(described_class.find_by_account_setup_token(token)).to eq(migration)
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.to_json).not_to include(token)
    end

    it "does not create an account for an email that already has one" do
      create(:user, email: "seller@example.com")
      migration = create_migration_for("Seller@example.com")

      expect(migration.account_creatable?).to be(false)
      expect(migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)).to be_nil
      expect(migration.reload).to be_pending
    end

    it "creates one account when the link opens twice" do
      migration = create_migration_for("new-seller@example.com")
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)

      expect(described_class.find(migration.id).create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)).to be_nil
      expect(User.where(email: "new-seller@example.com").count).to eq(1)
    end
  end

  describe "account setup" do
    let(:migration) do
      products, _error = described_class.normalize_products([product_attributes])
      described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:, email: "new-seller@example.com").first
    end

    it "finds the migration by the emailed token until it expires" do
      emailed_tokens = []
      allow(CreatorMailer).to receive(:partner_migration_account_setup).and_wrap_original do |original, id, encrypted_token|
        emailed_tokens << described_class.decrypt_account_setup_token(encrypted_token)
        original.call(id, encrypted_token)
      end
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)
      token = emailed_tokens.sole

      expect(described_class.find_by_account_setup_token(token)).to eq(migration)
      travel_to((described_class::ACCOUNT_SETUP_EXPIRES_IN + 1.minute).from_now) do
        expect(described_class.find_by_account_setup_token(token)).to be_nil
      end
    end

    it "does not create an account for a catalog that the partner replaced after the page showed it" do
      expect(migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: "digest-of-the-page")).to eq(described_class::OUT_OF_DATE_MESSAGE)

      expect(User.find_by(email: migration.email)).to be_nil
      expect(migration.reload).to be_pending
    end

    it "rejects the password from a page whose setup link a resend replaced" do
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)
      shown_digest = migration.reload.account_setup_token_digest
      travel_to((described_class::ACCOUNT_SETUP_RESEND_INTERVAL + 1.second).from_now) { migration.resend_account_setup! }

      expect { migration.complete_account_setup!(password: "a-long-new-password-123", ip: "203.0.113.11", expected_token_digest: shown_digest) }.to raise_error(described_class::AccountSetupError)
      expect(migration.user.reload.valid_password?("a-long-new-password-123")).to be(false)
    end

    it "ends the setup once anyone gets into the account another way, such as a password reset" do
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)
      migration.user.update!(sign_in_count: 1)

      expect(migration.reload).to have_attributes(account_setup_pending?: false, account_setup_open?: false)
      expect { migration.complete_account_setup!(password: "a-long-new-password-123", ip: "203.0.113.11", expected_token_digest: migration.account_setup_token_digest) }.to raise_error(described_class::AccountSetupError)
      expect(migration.resend_account_setup!).to eq(:expired)
    end

    it "ends the setup when a password reset changes the password, even before a two-factor sign-in" do
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)
      migration.user.reload.update!(password: "a-reset-password-789")

      expect(migration.reload.account_setup_pending?).to be(false)
      expect { migration.complete_account_setup!(password: "a-long-new-password-123", ip: "203.0.113.11", expected_token_digest: migration.account_setup_token_digest) }.to raise_error(described_class::AccountSetupError)
      expect(migration.user.reload.valid_password?("a-reset-password-789")).to be(true)
    end

    it "locks the seller before the migration, in the order that the import job uses" do
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)
      locked_tables = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        locked_tables << payload[:sql][/FROM `(\w+)`/, 1] if payload[:sql].include?("FOR UPDATE")
      end

      migration.complete_account_setup!(password: "a-long-new-password-123", ip: "203.0.113.11", expected_token_digest: migration.account_setup_token_digest)

      ActiveSupport::Notifications.unsubscribe(subscriber)
      expect(locked_tables).to eq(%w[users partner_migrations])
    end

    it "ends the setup when the account is closed, because the setup link signs the holder in" do
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)
      migration.user.update_columns(deleted_at: Time.current)

      expect(migration.reload.account_setup_pending?).to be(false)
      expect { migration.complete_account_setup!(password: "a-long-new-password-123", ip: "203.0.113.11", expected_token_digest: migration.account_setup_token_digest) }.to raise_error(described_class::AccountSetupError)
    end

    it "attaches the address's guest purchases, as email confirmation does" do
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)

      migration.complete_account_setup!(password: "a-long-new-password-123", ip: "203.0.113.11", expected_token_digest: migration.account_setup_token_digest)

      expect(AttachPastPurchasesToUserWorker.jobs.map { _1["args"] }).to eq([[migration.user_id, migration.email]])
    end

    it "sets the password, confirms the email, records the terms, and ends the setup" do
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)

      migration.complete_account_setup!(password: "a-long-new-password-123", ip: "203.0.113.11", expected_token_digest: migration.account_setup_token_digest)

      user = migration.user.reload
      expect(user.valid_password?("a-long-new-password-123")).to be(true)
      expect(user).to be_confirmed
      expect(user.tos_agreements.sole.ip).to eq("203.0.113.11")
      expect(migration.reload.account_setup_pending?).to be(false)
      expect { migration.complete_account_setup!(password: "another-password-456", ip: "203.0.113.11", expected_token_digest: migration.account_setup_token_digest) }.to raise_error(described_class::AccountSetupError)
    end

    it "reports an expired setup instead of asking the seller to wait" do
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)

      travel_to((described_class::ACCOUNT_SETUP_EXPIRES_IN + 1.minute).from_now) do
        expect(migration.resend_account_setup!).to eq(:expired)
      end
    end

    it "stops resending after the maximum, and a resend does not extend the link" do
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)
      (described_class::MAX_ACCOUNT_SETUP_EMAILS - 1).times do |i|
        travel_to(((i + 1) * (described_class::ACCOUNT_SETUP_RESEND_INTERVAL + 1.second)).from_now) { expect(migration.resend_account_setup!).to eq(:sent) }
      end

      travel_to(1.hour.from_now) { expect(migration.resend_account_setup!).to eq(:limit) }
      expect(migration.reload.account_setup_emails_count).to eq(described_class::MAX_ACCOUNT_SETUP_EMAILS)
      travel_to((described_class::ACCOUNT_SETUP_EXPIRES_IN + 1.minute).from_now) do
        expect { migration.complete_account_setup!(password: "a-long-new-password-123", ip: "203.0.113.11", expected_token_digest: migration.account_setup_token_digest) }.to raise_error(described_class::AccountSetupError)
      end
    end

    it "replaces the link when the seller asks again, at most once a minute" do
      migration.create_account_and_claim!(ip: "203.0.113.10", expected_code_digest: migration.code_digest)
      first_digest = migration.reload.account_setup_token_digest

      expect(migration.resend_account_setup!).to eq(:too_soon)
      travel_to((described_class::ACCOUNT_SETUP_RESEND_INTERVAL + 1.second).from_now) do
        expect { expect(migration.resend_account_setup!).to eq(:sent) }.to have_enqueued_mail(CreatorMailer, :partner_migration_account_setup)
      end
      expect(migration.reload.account_setup_token_digest).not_to eq(first_digest)
    end
  end

  describe "parts" do
    def send_part(part, name, **options)
      products, = described_class.normalize_products([{ external_product_id: name, name:, price: 500 }])
      described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:, part:, **options)
    end

    it "takes a large catalog in parts, under the one link of part 1" do
      head, first_code = send_part(1, "Texture Pack")
      second, second_code = send_part(2, "Brush Set")

      expect(second).to have_attributes(part: 2, status: described_class::STATUS_PENDING)
      expect(second_code).to be_present
      expect(described_class.find_by_code(first_code)).to be_nil
      expect(described_class.find_by_code(second_code)).to eq(head)
      expect(head.catalog_size).to eq(2)
      expect(head.reload.expires_at).to be_within(1.minute).of(described_class::EXPIRES_IN.from_now)
    end

    it "rejects a product ID that another part already has" do
      send_part(1, "Texture Pack")

      expect { send_part(2, "Texture Pack") }.to raise_error(described_class::PartError, 'external_product_id "Texture Pack" is already in another part.')
      second, = send_part(2, "Brush Set")
      expect(second.reload.products.first["name"]).to eq("Brush Set")
    end

    it "locks part 1 before it writes a later part, in the order that the result email takes them" do
      send_part(1, "Texture Pack")
      send_part(2, "Brush Set")
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] if payload[:sql].include?("partner_migrations") && payload[:sql].match?(/FOR UPDATE|\AUPDATE/)
      end

      products, = described_class.normalize_products([{ external_product_id: "Brush Set", name: "Brush Set", price: 500, files: [{ url: "https://files.example.com/new.zip" }] }])
      described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:, part: 2)

      ActiveSupport::Notifications.unsubscribe(subscriber)
      expect(statements.first).to include("FOR UPDATE")
    end

    it "clears a rejected address on part 1 when a later part retries, so the result email can go out" do
      head, = send_part(1, "Texture Pack")
      second, = send_part(2, "Brush Set")
      head.reload.claim!(seller, expected_code_digest: head.code_digest)
      head.update!(status: described_class::STATUS_COMPLETED, completed_at: Time.current, notification_failed_email: seller.email)
      second.update!(status: described_class::STATUS_FAILED, completed_at: Time.current, notification_failed_email: seller.email, results: { "0" => { "error" => "Missing file" } })

      send_part(2, "Brush Set")

      expect(second.reload.status).to eq(described_class::STATUS_CLAIMED)
      expect(head.reload.notification_failed_email).to be_nil
    end

    it "drops the parts above total_parts when the catalog shrinks before the confirmation" do
      head, = send_part(1, "Texture Pack")
      send_part(2, "Brush Set")
      products, = described_class.normalize_products([{ external_product_id: "Texture Pack", name: "Texture Pack", price: 500 }, { external_product_id: "Brush Set", name: "Brush Set", price: 500 }])

      _head, code = described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:, part: 1, total_parts: 1)

      expect(head.parts.pluck(:part)).to eq([1])
      expect(head.catalog_size).to eq(2)
      expect(described_class.find_by_code(code)).to eq(head)
      expect { send_part(1, "Texture Pack", total_parts: 0) }.to raise_error(described_class::PartError)
    end

    it "does not drop a part after the confirmation" do
      head, = send_part(1, "Texture Pack")
      send_part(2, "Brush Set")
      head.reload.claim!(seller, expected_code_digest: head.code_digest)

      expect { send_part(1, "Texture Pack", total_parts: 1) }.to raise_error(described_class::CatalogConflict)
      expect(head.parts.count).to eq(2)
    end

    it "rejects a later part before part 1" do
      expect { send_part(2, "Brush Set") }.to raise_error(described_class::PartError, "Send part 1 before part 2.")
    end

    it "claims every part and queues an import for each" do
      head, = send_part(1, "Texture Pack")
      second, = send_part(2, "Brush Set")
      Sidekiq::Worker.clear_all

      head.reload.claim!(seller, expected_code_digest: head.code_digest)

      expect([head.reload, second.reload].map { [_1.status, _1.user] }).to eq([[described_class::STATUS_CLAIMED, seller]] * 2)
      expect(PartnerMigrationImportJob.jobs.map { _1["args"] }).to contain_exactly([head.id], [second.id])
    end

    it "locks every part after the confirmation, but still lets the partner refresh a part's URLs" do
      head, = send_part(1, "Texture Pack")
      send_part(2, "Brush Set")
      head.reload.claim!(seller, expected_code_digest: head.code_digest)

      expect { send_part(3, "Sculpt Kit") }.to raise_error(described_class::CatalogConflict)
      expect { send_part(2, "Another product") }.to raise_error(described_class::CatalogConflict)
      _second, code = send_part(2, "Brush Set")
      expect(code).to be_nil
    end

    it "reports the catalog as importing until every part finished, then failed if any part failed" do
      head, = send_part(1, "Texture Pack")
      second, = send_part(2, "Brush Set")
      head.update!(status: described_class::STATUS_COMPLETED)
      second.update!(status: described_class::STATUS_CLAIMED)

      expect(head.catalog_status).to eq(described_class::STATUS_CLAIMED)
      second.update!(status: described_class::STATUS_FAILED)
      expect(head.catalog_status).to eq(described_class::STATUS_FAILED)
      second.update!(status: described_class::STATUS_COMPLETED)
      expect(head.catalog_status).to eq(described_class::STATUS_COMPLETED)
    end
  end

  describe ".create_for!" do
    it "stores only a digest of the code" do
      migration, code = create_migration

      expect(migration.code_digest).to eq(described_class.digest(code))
      expect(migration.code_digest).not_to eq(code)
      expect(described_class.find_by_code(code)).to eq(migration)
      expect(migration.expires_at).to be_within(1.minute).of(described_class::EXPIRES_IN.from_now)
    end

    it "reuses one migration and replaces the link when the partner changes the catalog" do
      first, first_code = create_migration
      products, = described_class.normalize_products([product_attributes.merge(name: "Renamed pack")])
      second, second_code = described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)

      expect(second.id).to eq(first.id)
      expect(first_code).not_to eq(second_code)
      expect(described_class.find_by_code(first_code)).to be_nil
      expect(described_class.find_by_code(second_code)).to eq(first)
    end

    it "keeps the link and extends it when the partner sends only new download URLs" do
      export = ->(url) do
        products, = described_class.normalize_products([product_attributes.merge(files: [{ url: }])])
        described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)
      end
      migration, code = export.call("https://files.example.com/pack.zip?signature=old")
      migration.update_columns(expires_at: 1.day.from_now)

      refreshed, refreshed_code = export.call("https://files.example.com/pack.zip?signature=new")

      expect(refreshed_code).to be_nil
      expect(described_class.find_by_code(code)).to eq(migration)
      expect(refreshed.reload.expires_at).to be_within(1.minute).of(described_class::EXPIRES_IN.from_now)
      expect(refreshed.products.first["files"].first["url"]).to end_with("signature=new")
    end

    it "replaces the link when the seller's email changes before the confirmation" do
      products, = described_class.normalize_products([product_attributes])
      _migration, code = described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:, email: "old@example.com")

      _migration, new_code = described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:, email: "new@example.com")

      expect(new_code).to be_present
      expect(described_class.find_by_code(code)).to be_nil
    end

    it "refreshes signed URLs without clearing products that already imported" do
      original = product_attributes.merge(files: [{ url: "https://files.example.com/pack.zip?signature=old" }])
      products, = described_class.normalize_products([original])
      migration, = described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      migration.update!(results: { "0" => { "product_id" => "saved-product" } })
      products, = described_class.normalize_products([original.merge(files: [{ url: "https://files.example.com/pack.zip?signature=new" }])])

      refreshed, = described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)

      expect(refreshed.id).to eq(migration.id)
      expect(refreshed.results).to eq("0" => { "product_id" => "saved-product" })
      expect(refreshed.products.first["files"].first["url"]).to end_with("signature=new")
    end

    it "rejects catalog changes after the seller confirms" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      products, = described_class.normalize_products([product_attributes.merge(name: "Another product")])

      expect { described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:) }.to raise_error(described_class::CatalogConflict)
      expect(migration.reload.products.first["name"]).to eq("Texture Pack")
    end

    it "lets the partner refresh variant file URLs after the seller confirms" do
      variants = [{ name: "Extended", files: [{ url: "https://files.example.com/extended.zip?signature=old" }] }]
      products, = described_class.normalize_products([product_attributes.merge(variant_categories: [{ title: "License", variants: }])])
      migration, = described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      variants = [{ name: "Extended", files: [{ url: "https://files.example.com/extended.zip?signature=new" }] }]
      products, = described_class.normalize_products([product_attributes.merge(variant_categories: [{ title: "License", variants: }])])

      refreshed, = described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)

      expect(refreshed.products.first.dig("variant_categories", 0, "variants", 0, "files", 0, "url")).to end_with("signature=new")
    end

    it "gives each migration its own Nano ID and keeps it when the partner sends the export again" do
      first, = create_migration
      other, = create_migration(external_user_id: "ext-2")
      again, = create_migration

      expect(first.public_id).to match(/\A[A-Za-z0-9_-]{21}\z/)
      expect(other.public_id).not_to eq(first.public_id)
      expect(again.id).to eq(first.id)
      expect(again.reload.public_id).to eq(first.public_id)
    end
  end

  describe "#public_id" do
    it "cannot be changed" do
      migration, = create_migration
      public_id = migration.public_id

      expect { migration.update!(public_id: Nanoid.generate) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(migration.reload.public_id).to eq(public_id)
    end
  end

  describe ".find_by_public_id" do
    let(:public_id) { "aB3xaB3xaB3xaB3xaB3x_" }
    let!(:migration) do
      products, _error = described_class.normalize_products([product_attributes])
      described_class.create!(oauth_application: partner_application, external_user_id: "ext-1", products:, code_digest: described_class.digest("code"), expires_at: 1.day.from_now, public_id:)
    end

    it "finds a migration by its exact Nano ID" do
      expect(described_class.find_by_public_id(public_id)).to eq(migration)
    end

    it "does not find a migration by its row ID, another case, or extra characters" do
      [migration.id, migration.id.to_s, public_id.swapcase, public_id.upcase, "#{public_id} ", " #{public_id}", "#{public_id}\n", public_id.chop, "#{public_id}x", "", nil, [public_id]].each do |value|
        expect(described_class.find_by_public_id(value)).to be_nil, "found a migration for #{value.inspect}"
      end
      expect(described_class.where(public_id: "#{public_id} ")).not_to exist
      expect(described_class.where(public_id: public_id.swapcase)).not_to exist
    end
  end

  describe "#claim!" do
    it "requires an email address for the result notification" do
      migration, = create_migration
      seller.update_columns(provider: "apple", email: nil, unconfirmed_email: nil)

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, /Add an email address/)

      expect(migration.reload).to be_pending
      expect(PartnerMigrationImportJob.jobs).to be_empty
    end

    it "rejects a catalog refreshed after the confirmation page loads" do
      migration, = create_migration
      products, = described_class.normalize_products([product_attributes.merge(name: "Replacement catalog")])
      described_class.create_for!(oauth_application: partner_application, external_user_id: "ext-1", products:)

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, /out of date/)

      expect(migration.reload).to be_pending
      expect(partner_application.partner_sellers).to be_empty
      expect(PartnerMigrationImportJob.jobs).to be_empty
    end

    it "links the seller to the partner user ID and starts the import" do
      migration, _code = create_migration

      migration.claim!(seller, expected_code_digest: migration.code_digest)

      expect(migration.reload).to have_attributes(status: described_class::STATUS_CLAIMED, user: seller, claimed_at: be_present)
      expect(partner_application.partner_sellers.alive.find_by(external_user_id: "ext-1")).to have_attributes(user: seller, migrated_at: nil)
      expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(migration.id)
    end

    it "rolls the claim back when the import cannot be queued" do
      migration, = create_migration
      allow(PartnerMigrationImportJob).to receive(:perform_async).and_raise(Redis::CannotConnectError)

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(Redis::CannotConnectError)

      expect(migration.reload).to be_pending
      expect(partner_application.partner_sellers).to be_empty
    end

    it "cannot be claimed by a second account" do
      migration, _code = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)

      expect { migration.claim!(create(:user), expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "queues the import again when the same seller claims again before it finishes" do
      migration, _code = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      Sidekiq::Worker.clear_all

      migration.claim!(seller, expected_code_digest: migration.code_digest)

      expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(migration.id)
      migration.update!(status: described_class::STATUS_COMPLETED)
      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "rejects an expired link" do
      migration, _code = create_migration
      migration.update!(expires_at: 1.minute.ago)

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "rejects a link from an application that is no longer a partner" do
      migration, _code = create_migration
      partner_application.update!(is_partner: false)

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This link is invalid or expired.")
    end

    it "rejects a partner user ID that is linked to a different Gumroad account" do
      create(:partner_seller, oauth_application: partner_application, user: create(:user), external_user_id: "ext-1")
      migration, _code = create_migration

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This Example App account is already linked to a different Gumroad account.")
      expect(migration.reload).to be_pending
    end

    it "rejects a Gumroad account that is linked to a different partner user ID" do
      create(:partner_seller, oauth_application: partner_application, user: seller, external_user_id: "ext-2")
      migration, _code = create_migration

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "Your Gumroad account is already linked to a different Example App account.")
    end

    it "restores a seller that was removed from the program" do
      partner_seller = create(:partner_seller, oauth_application: partner_application, user: seller, external_user_id: "ext-1")
      partner_seller.mark_deleted!
      migration, _code = create_migration

      migration.claim!(seller, expected_code_digest: migration.code_digest)

      expect(partner_seller.reload).to be_alive
    end

    it "links partner user IDs that differ only in case, accents, Unicode form or trailing spaces to different accounts" do
      external_user_ids = ["aB3x", "Ab3X", "café", "cafe", "\u00e9", "e\u0301", "ext-9", "ext-9 "]

      external_user_ids.each do |external_user_id|
        migration, _code = create_migration(external_user_id:)
        claimer = create(:user)

        migration.claim!(claimer, expected_code_digest: migration.code_digest)

        expect(partner_application.partner_sellers.where(external_user_id:).sole).to have_attributes(user: claimer, external_user_id:)
      end
      expect(partner_application.partner_sellers.pluck(:external_user_id)).to match_array(external_user_ids)
    end

    it "rejects a suspended account" do
      migration, _code = create_migration
      seller.update!(user_risk_state: "suspended_for_fraud")

      expect { migration.claim!(seller, expected_code_digest: migration.code_digest) }.to raise_error(described_class::ClaimError, "This account cannot import products.")
    end

    it "starts the migration date when an imported product first goes live" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      PartnerMigrationImportJob.new.perform(migration.id)
      partner_seller = partner_application.partner_sellers.sole
      expect(partner_seller.migrated_at).to be_nil

      seller.links.sole.publish!

      expect(partner_seller.reload.migrated_at).to eq(seller.links.sole.first_published_at)
    end

    it "retries only failed products, keeping saved ones, when the partner sends the export again" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      migration.update!(status: described_class::STATUS_FAILED, results: { "0" => { "product_id" => "saved" }, "1" => { "error" => "Missing file" } }, import_started_at: 1.day.ago)
      Sidekiq::Worker.clear_all

      create_migration

      # The retry has not started, so the resume scan must not count it while it waits in the queue.
      expect(migration.reload).to have_attributes(status: described_class::STATUS_CLAIMED, results: { "0" => { "product_id" => "saved" } }, import_started_at: nil)
      expect(PartnerMigrationImportJob).to have_enqueued_sidekiq_job(migration.id)
    end

    it "keeps the failed state when the previous job still holds its queue lock" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      results = { "0" => { "error" => "Missing file" } }
      migration.update!(status: described_class::STATUS_FAILED, results:)
      allow(PartnerMigrationImportJob).to receive(:perform_async).with(migration.id).and_return(nil)

      returned_migration, = create_migration

      expect(returned_migration.status).to eq(described_class::STATUS_FAILED)
      expect(migration.reload).to have_attributes(status: described_class::STATUS_FAILED, results:)
    end

    it "does not restart a failed import for an account that can no longer import" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      migration.update!(status: described_class::STATUS_FAILED, results: { "0" => { "error" => "Missing file" } })
      seller.update!(user_risk_state: "suspended_for_fraud")
      Sidekiq::Worker.clear_all

      create_migration

      expect(migration.reload.status).to eq(described_class::STATUS_FAILED)
      expect(PartnerMigrationImportJob.jobs).to be_empty
    end

    it "does not restart a completed import when the partner sends the export again" do
      migration, = create_migration
      migration.claim!(seller, expected_code_digest: migration.code_digest)
      migration.update!(status: described_class::STATUS_COMPLETED, completed_at: Time.current, notified_at: Time.current)
      Sidekiq::Worker.clear_all

      create_migration

      expect(migration.reload.status).to eq(described_class::STATUS_COMPLETED)
      expect(PartnerMigrationImportJob.jobs).to be_empty
    end
  end
end
