# frozen_string_literal: true

require "digest"

# A partner application's request to move one of its users' catalogs to Gumroad.
#
# The partner sends the products, and gets back a one-time onboarding link. The creator opens the
# link, logs in or signs up, and claims the migration. The claim links the creator to the partner's
# user ID and imports the products as drafts. Only a SHA-256 digest of the link's code is stored.
#
# When the export names an email that no Gumroad account uses, opening the link creates the account
# and claims the import for it. The seller then sets a password from an emailed link, which also
# proves that they own the address.
class PartnerMigration < ApplicationRecord
  EXPIRES_IN = 7.days
  # The job touches the migration around each transfer, and one download stops after
  # RemoteFileTransfer::MAX_DOWNLOAD_DURATION. A longer gap usually means the job was lost, so
  # ResumeStalledPartnerMigrationsJob queues it again. Twice the download limit leaves the same time
  # again for the upload that follows it.
  STALLED_AFTER = PartnerMigration::RemoteFileTransfer::MAX_DOWNLOAD_DURATION * 2
  CONFIRMATION_PREVIEW_SIZE = 5
  MAX_PRODUCTS = 500
  MAX_EXTERNAL_USER_ID_LENGTH = 255
  MAX_NAME_LENGTH = 255
  MAX_FAILURE_REASON_LENGTH = 255
  MAX_FILES_PER_PRODUCT = 50
  # The product editor's limit (TagSelector).
  MAX_TAGS_PER_PRODUCT = 10
  # Without SKUs, checkout offers only the first variant category of a digital product.
  MAX_VARIANT_CATEGORIES = 1
  MAX_VARIANTS_PER_CATEGORY = 20
  MAX_CODE_GENERATION_ATTEMPTS = 3
  MAX_EMAIL_LENGTH = 255
  MAX_BIO_LENGTH = 5_000
  # As long as the onboarding link, so a seller who opens the email days later can still use it.
  # Counted from the account's creation, so a resend does not extend it.
  ACCOUNT_SETUP_EXPIRES_IN = EXPIRES_IN
  ACCOUNT_SETUP_RESEND_INTERVAL = 1.minute
  # Whoever holds the onboarding link can ask for the email again, so the address gets a bounded number.
  MAX_ACCOUNT_SETUP_EMAILS = 5
  # A job that keeps stopping, for example on a file that exhausts the worker's memory, gets a final state.
  MAX_RESUMES = 3
  PUBLIC_ID_FORMAT = /\A[A-Za-z0-9_-]{21}\z/

  STATUS_PENDING = "pending"
  STATUS_CLAIMED = "claimed"
  STATUS_COMPLETED = "completed"
  STATUS_FAILED = "failed"
  STATUSES = [STATUS_PENDING, STATUS_CLAIMED, STATUS_COMPLETED, STATUS_FAILED].freeze

  class ClaimError < StandardError; end
  class CatalogConflict < StandardError; end
  class AccountSetupError < StandardError; end

  INVALID_LINK_MESSAGE = "This link is invalid or expired."
  OUT_OF_DATE_MESSAGE = "This page is out of date. Open the link from the application again."

  belongs_to :oauth_application
  belongs_to :user, optional: true

  attr_readonly :public_id
  before_validation :assign_public_id, on: :create

  validates :external_user_id, presence: true, length: { maximum: MAX_EXTERNAL_USER_ID_LENGTH }
  validates :code_digest, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :expires_at, presence: true
  validates :public_id, format: { with: PUBLIC_ID_FORMAT }

  scope :stalled, -> { where(status: STATUS_CLAIMED, updated_at: ...STALLED_AFTER.ago) }

  def self.create_for!(oauth_application:, external_user_id:, products:, email: nil, profile: nil)
    attempts = 0

    begin
      attempts += 1
      code = SecureRandom.urlsafe_base64(32)
      oauth_application.with_lock do
        migration = where(oauth_application:, external_user_id:).order(:id).first
        if migration
          if !migration.pending? && catalog_identity(migration.products) != catalog_identity(products)
            raise CatalogConflict, "This seller already has an export. Keep the same products and file order when refreshing download URLs."
          end
          # After the claim, the account is settled, so a new email or profile no longer applies.
          seller = migration.pending? ? { email:, profile: } : {}
          migration.update!(products:, code_digest: digest(code), expires_at: EXPIRES_IN.from_now, **seller)
          migration.retry_failed_products!
        else
          migration = create!(oauth_application:, external_user_id:, products:, email:, profile:, code_digest: digest(code), expires_at: EXPIRES_IN.from_now)
        end
        [migration, code]
      end
    rescue ActiveRecord::RecordNotUnique
      retry if attempts < MAX_CODE_GENERATION_ATTEMPTS
      raise
    end
  end

  def self.find_by_code(code)
    return if code.blank?

    find_by(code_digest: digest(code))
  end

  # Takes the Nano ID only, never the row ID.
  def self.find_by_public_id(value)
    find_by(public_id: value) if value.is_a?(String) && value.match?(PUBLIC_ID_FORMAT)
  end

  def self.digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  def self.catalog_identity(products)
    products.map do |product|
      product.except("files", "covers", "thumbnail_url").merge(
        "files" => product["files"].map { _1.except("url") },
        "covers" => product["covers"].size,
        "thumbnail" => product["thumbnail_url"].present?,
      )
    end
  end

  def self.record_first_publication(product)
    where(user_id: product.user_id).find_each do |migration|
      next unless migration.results.to_h.values.any? { _1["product_id"] == product.external_id }

      PartnerSeller.where(oauth_application_id: migration.oauth_application_id, user_id: product.user_id, external_user_id: migration.external_user_id)
                   .where("migrated_at IS NULL OR migrated_at > ?", product.first_published_at)
                   .update_all(migrated_at: product.first_published_at)
    end
  end

  # Returns [{ email:, profile: }, nil] with only the supported keys, or [nil, error message].
  def self.normalize_seller(email:, profile:)
    unless email.nil?
      valid_email = string?(email) && email.strip.length <= MAX_EMAIL_LENGTH && EmailFormatValidator.valid?(email.strip)
      return [nil, "email must be a valid email address with at most #{MAX_EMAIL_LENGTH} characters."] unless valid_email
    end

    unless profile.nil?
      return [nil, "profile must be an object."] unless profile.respond_to?(:key?)

      name, bio, avatar_url = profile[:name], profile[:bio], profile[:avatar_url]
      valid_name = name.nil? || (string?(name) && name.strip.length <= User::MAX_LENGTH_NAME && !name.match?(User::INVALID_NAME_FOR_EMAIL_DELIVERY_REGEX))
      return [nil, "profile.name must be a string with at most #{User::MAX_LENGTH_NAME} characters and no colons."] unless valid_name
      return [nil, "profile.bio must be a string with at most #{MAX_BIO_LENGTH} characters."] unless bio.nil? || (string?(bio) && bio.length <= MAX_BIO_LENGTH)
      return [nil, "profile.avatar_url must be an https URL."] unless avatar_url.nil? || https_url?(avatar_url)
    end

    profile = { "name" => name&.strip.presence, "bio" => bio.presence, "avatar_url" => avatar_url }.compact.presence if profile
    [{ email: email&.strip&.downcase, profile: }, nil]
  end

  # The setup token is a credential for the new account. The mail job carries it encrypted, so the
  # queue and its retry and dead sets never hold it in plain text.
  def self.encrypt_account_setup_token(token)
    account_setup_token_encryptor.encrypt_and_sign(token, expires_in: ACCOUNT_SETUP_EXPIRES_IN)
  end

  def self.decrypt_account_setup_token(encrypted_token)
    account_setup_token_encryptor.decrypt_and_verify(encrypted_token)
  end

  def self.account_setup_token_encryptor
    @account_setup_token_encryptor ||= ActiveSupport::MessageEncryptor.new(Rails.application.key_generator.generate_key("partner_migration_account_setup_token", 32), cipher: "aes-256-gcm")
  end

  def self.find_by_account_setup_token(token)
    return if token.blank?

    migration = find_by(account_setup_token_digest: digest(token))
    migration unless migration&.account_setup_expired?
  end

  # Returns [products, nil] with only the supported keys, or [nil, error message].
  def self.normalize_products(raw_products)
    return [nil, "products must be an array with 1 to #{MAX_PRODUCTS} items."] unless raw_products.is_a?(Array) && raw_products.size.between?(1, MAX_PRODUCTS)

    products = raw_products.each_with_index.map do |raw, index|
      product, error = normalize_product(raw)
      return [nil, "products[#{index}]: #{error}"] if error

      product
    end

    [products, nil]
  end

  def self.normalize_product(raw)
    return [nil, "must be an object."] unless raw.respond_to?(:key?)
    return [nil, "name must be a string with 1 to #{MAX_NAME_LENGTH} characters."] unless string?(raw[:name]) && raw[:name].strip.length.between?(1, MAX_NAME_LENGTH)
    return [nil, "description must be a string."] unless raw[:description].nil? || string?(raw[:description])
    return [nil, "price must be a whole number of cents, 0 or more."] unless raw[:price].is_a?(Integer) && raw[:price] >= 0
    return [nil, "price must be at most #{BasePrice::Shared::MAX_PRICE_CENTS} cents."] if raw[:price] > BasePrice::Shared::MAX_PRICE_CENTS

    currency = raw[:price_currency_type].nil? ? "usd" : raw[:price_currency_type].to_s.downcase
    return [nil, "price_currency_type is not a supported currency."] unless CURRENCY_CHOICES.key?(currency)
    min_price = CURRENCY_CHOICES[currency]["min_price"]
    return [nil, "price must be 0 or at least #{min_price} cents in #{currency}."] unless raw[:price].zero? || raw[:price] >= min_price
    return [nil, "taxonomy_id is not a known category."] unless raw[:taxonomy_id].nil? || (raw[:taxonomy_id].is_a?(Integer) && Taxonomy.exists?(id: raw[:taxonomy_id]))

    tags = raw[:tags].nil? ? [] : raw[:tags]
    return [nil, "tags must be an array of up to #{MAX_TAGS_PER_PRODUCT} strings."] unless tags.is_a?(Array) && tags.size <= MAX_TAGS_PER_PRODUCT && tags.all? { string?(_1) }
    # Product#tag! cannot save the same tag twice, so clean them up as Tag#clean_name does first.
    tags = unique_tag_names(tags.map { _1.downcase.strip.gsub(/[[:space:]]+/, " ") }.uniq)
    tag_error = tags.lazy.filter_map { tag_error(_1) }.first
    return [nil, "tags: #{tag_error}"] if tag_error

    files = raw[:files].nil? ? [] : raw[:files]
    return [nil, "files must be an array with up to #{MAX_FILES_PER_PRODUCT} items."] unless files.is_a?(Array) && files.size <= MAX_FILES_PER_PRODUCT
    return [nil, "each file needs an https url and an optional display_name string."] unless files.all? { _1.respond_to?(:key?) && https_url?(_1[:url]) && (_1[:display_name].nil? || string?(_1[:display_name])) }
    return [nil, "file display_name must have at most #{MAX_NAME_LENGTH} characters."] if files.any? { _1[:display_name].to_s.length > MAX_NAME_LENGTH }

    covers = raw[:covers].nil? ? [] : raw[:covers]
    return [nil, "covers must be an array with up to #{Link::MAX_PREVIEW_COUNT} items."] unless covers.is_a?(Array) && covers.size <= Link::MAX_PREVIEW_COUNT
    return [nil, "each cover needs an https url."] unless covers.all? { _1.respond_to?(:key?) && https_url?(_1[:url]) }
    return [nil, "thumbnail_url must be an https URL."] unless raw[:thumbnail_url].nil? || https_url?(raw[:thumbnail_url])

    variant_categories, error = normalize_variant_categories(raw[:variant_categories])
    return [nil, error] if error
    if variant_categories.any? { _1["variants"].any? { |variant| raw[:price] + variant["price_difference_cents"] > BasePrice::Shared::MAX_PRICE_CENTS } }
      return [nil, "the product price plus each variant price difference must be at most #{BasePrice::Shared::MAX_PRICE_CENTS} cents."]
    end

    [{
      "name" => raw[:name].strip,
      "description" => raw[:description],
      "price" => raw[:price],
      "price_currency_type" => currency,
      "taxonomy_id" => raw[:taxonomy_id],
      "tags" => tags,
      "files" => files.map { { "url" => _1[:url], "display_name" => _1[:display_name] } },
      "covers" => covers.map { { "url" => _1[:url] } },
      "thumbnail_url" => raw[:thumbnail_url],
      "variant_categories" => variant_categories,
    }, nil]
  end

  def self.normalize_variant_categories(raw_categories)
    return [[], nil] if raw_categories.nil?
    return [nil, "variant_categories must be an array with up to #{MAX_VARIANT_CATEGORIES} item."] unless raw_categories.is_a?(Array) && raw_categories.size <= MAX_VARIANT_CATEGORIES

    categories = raw_categories.map do |category|
      return [nil, "each variant category needs a title string and 1 to #{MAX_VARIANTS_PER_CATEGORY} variants."] unless category.respond_to?(:key?) && string?(category[:title]) && category[:variants].is_a?(Array) && category[:variants].size.between?(1, MAX_VARIANTS_PER_CATEGORY)
      return [nil, "variant category title must have 1 to #{MAX_NAME_LENGTH} characters."] unless category[:title].strip.length.between?(1, MAX_NAME_LENGTH)

      variants = category[:variants].map do |variant|
        return [nil, "each variant needs a name string and a whole number price_difference_cents from 0 to #{BasePrice::Shared::MAX_PRICE_CENTS}."] unless variant.respond_to?(:key?) && string?(variant[:name]) && (variant[:price_difference_cents].nil? || (variant[:price_difference_cents].is_a?(Integer) && variant[:price_difference_cents].between?(0, BasePrice::Shared::MAX_PRICE_CENTS)))
        return [nil, "variant name must have 1 to #{MAX_NAME_LENGTH} characters."] unless variant[:name].strip.length.between?(1, MAX_NAME_LENGTH)

        { "name" => variant[:name].strip, "price_difference_cents" => variant[:price_difference_cents] || 0 }
      end

      { "title" => category[:title].strip, "variants" => variants }
    end

    [categories, nil]
  end

  def self.string?(value) = value.is_a?(String)

  # Keeps the first of the names that tags.name treats as equal. Its collation matches "café" with
  # "cafe" and "straße" with "strasse", which Ruby cannot reproduce, so MySQL groups them.
  def self.unique_tag_names(names)
    return names if names.size < 2

    collation = Tag.columns_hash.fetch("name").collation
    raise ArgumentError, "Unexpected collation #{collation.inspect}" unless collation.match?(/\A\w+\z/)

    rows = Array.new(names.size, "SELECT ? AS position, ? AS name").join(" UNION ALL ")
    sql = sanitize_sql_array(["SELECT MIN(position) FROM (#{rows}) names GROUP BY name COLLATE #{collation}", *names.each_with_index.flat_map { [_2, _1] }])
    connection.select_values(sql).map(&:to_i).sort.map { names[_1] }
  end

  # Tag's own name rules, without its uniqueness check: the import reuses an existing tag.
  def self.tag_error(name)
    tag = Tag.new(name:)
    Tag.validators_on(:name).grep_v(ActiveRecord::Validations::UniquenessValidator).each { _1.validate(tag) }
    tag.errors[:name].first
  end

  def self.https_url?(value)
    return false unless value.is_a?(String)

    uri = URI.parse(value)
    uri.is_a?(URI::HTTPS) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end
  private_class_method :catalog_identity, :normalize_product, :normalize_variant_categories, :string?, :unique_tag_names, :tag_error, :https_url?

  def pending? = status == STATUS_PENDING
  def expired?(at = Time.current) = expires_at <= at

  def claimable?
    pending? && !expired? && oauth_application.alive? && oauth_application.is_partner?
  end

  # An existing account must log in and confirm, so a partner cannot add products to an account
  # just by naming its email. The address check is the one that signup uses (User::Validations#email_almost_unique).
  def account_creatable?
    claimable? && email.present? && !User.by_email(email).exists?
  end

  def account_setup_pending? = account_created && account_setup_token_digest.present?
  def account_setup_expired? = claimed_at.nil? || claimed_at + ACCOUNT_SETUP_EXPIRES_IN <= Time.current
  # The seller can still set a password from the setup email.
  def account_setup_open? = account_setup_pending? && !account_setup_expired?
  def stalled? = status == STATUS_CLAIMED && updated_at < STALLED_AFTER.ago

  def masked_email
    local_part, domain = email.split("@", 2)
    "#{local_part.first}•••@#{domain}"
  end

  # Creates the seller's account, claims the import for it, and emails a link to set a password.
  # Returns nil, or a message for the seller when the account cannot be created.
  def create_account_and_claim!(ip:)
    return unless account_creatable?

    user = User.new(email:, password: Devise.friendly_token(User::RANDOM_PASSWORD_LENGTH), account_created_ip: ip)
    user.assign_attributes(profile.to_h.slice("name", "bio"))
    # As at signup, to abide by Canadian anti-spam law.
    user.announcement_notification_enabled = false if GeoIp.lookup(ip).try(:country_code) == Compliance::Countries::CAN.alpha2
    # The setup email confirms the address, so Devise's confirmation email would be a second email.
    user.skip_confirmation_notification!
    # Validation calls the breached-password API, so it runs before the locks that partner exports wait on.
    user.validate!
    token = nil
    oauth_application.with_lock do
      with_lock do
        next unless account_creatable? && user.email == email

        user.save!(validate: false)
        token = issue_account_setup_token!(account_created: true)
        claim!(user, expected_code_digest: code_digest)
      end
    end
    send_account_setup_email(token) if token
    nil
  rescue ClaimError => e
    e.message
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    Rails.logger.info("Partner migration #{id}: account not created (#{e.class})")
    "We could not create a Gumroad account for this email. Log in or sign up with another email instead."
  end

  # Replaces the setup link and emails it again. Returns :sent, :expired, :limit, or :too_soon.
  def resend_account_setup!
    token = nil
    result = with_lock do
      next :expired unless account_setup_open?
      next :limit if account_setup_emails_count >= MAX_ACCOUNT_SETUP_EMAILS
      next :too_soon if account_setup_sent_at&.after?(ACCOUNT_SETUP_RESEND_INTERVAL.ago)

      token = issue_account_setup_token!
      :sent
    end
    send_account_setup_email(token) if token
    result
  end

  # Sets the password from the emailed link. The link proves the address, so it also confirms it.
  def complete_account_setup!(password:, ip:)
    raise AccountSetupError, INVALID_LINK_MESSAGE unless account_setup_open?

    # A local, because the lock reloads this record and its user.
    account = user
    account.password = password
    account.skip_confirmation! unless account.confirmed?
    account.tos_agreements.build(ip:)
    # Validation calls the breached-password API, so it runs before the lock that the import job waits on.
    account.validate!
    with_lock do
      raise AccountSetupError, INVALID_LINK_MESSAGE unless account_setup_open?

      account.save!(validate: false)
      update!(account_setup_token_digest: nil)
    end
  end

  # The same creator can claim again while the import has not finished, so a failed enqueue can be
  # retried from the confirmation page. The job skips the products that it already imported.
  def claimable_by?(claimer)
    claimable? || (status == STATUS_CLAIMED && user_id == claimer.id)
  end

  # Links `claimer` to the partner's user ID, then starts the import. Raises ClaimError with a
  # message for the creator when the link was used, expired, or belongs to a different account.
  def claim!(claimer, expected_code_digest:)
    raise ClaimError, "This account cannot import products." unless claimer.account_active?
    raise ClaimError, "Add an email address to your Gumroad account before importing products." if claimer.form_email.blank?

    oauth_application.with_lock do
      with_lock do
        raise ClaimError, OUT_OF_DATE_MESSAGE unless code_digest == expected_code_digest
        raise ClaimError, INVALID_LINK_MESSAGE unless claimable_by?(claimer)

        unless status == STATUS_CLAIMED
          link_partner_seller!(claimer)
          update!(user: claimer, status: STATUS_CLAIMED, claimed_at: Time.current)
        end
        # Queued under the lock: if queueing fails, the claim rolls back, so a claimed import always has
        # a job. The job locks this row first, so it waits for this transaction to commit.
        PartnerMigrationImportJob.perform_async(id)
      end
    end
  end

  # Imports the failed products again and keeps the ones that imported. Runs when the partner sends
  # the export again, for example with fresh download links, so the seller never has to retry.
  def retry_failed_products!
    return unless status == STATUS_FAILED

    # Its own savepoint: create_for! calls this inside a transaction, and the rollback below must undo
    # only this reset.
    queued = with_lock(requires_new: true) do
      next false unless status == STATUS_FAILED && user&.account_active?

      update!(results: results.to_h.reject { |_index, result| result.key?("error") }, status: STATUS_CLAIMED, failure_reason: nil, completed_at: nil, notified_at: nil, notification_failed_email: nil, resumes_count: 0)
      # A nil enqueue means the previous job still holds its lock. Keep the failed state, so the next
      # export tries again.
      raise ActiveRecord::Rollback if PartnerMigrationImportJob.perform_async(id).nil?
      true
    end
    # A savepoint rollback does not restore the attributes, so read the failed state back for the response.
    reload if queued.nil?
  end

  # Queues an import again when its job stopped without finishing, up to MAX_RESUMES times.
  def resume_stalled_import!
    failure_reason = nil
    with_lock do
      next unless stalled?

      if !user&.account_active?
        failure_reason = "This account cannot import products."
      elsif resumes_count >= MAX_RESUMES
        failure_reason = "The import stopped #{MAX_RESUMES + 1} times before it finished."
      # A nil enqueue means a job still holds the lock, so nothing resumed and the attempt does not count.
      elsif PartnerMigrationImportJob.perform_async(id)
        update!(resumes_count: resumes_count + 1)
      end
      update!(status: STATUS_FAILED, completed_at: Time.current, failure_reason:) if failure_reason
    end
    PartnerMigrationNotificationJob.perform_async(id) if failure_reason
  end

  def progress
    recorded_results = results.to_h.values
    imported = recorded_results.count { _1["product_id"].present? }
    failed = recorded_results.count { _1["error"].present? }
    { total: products.size, imported:, failed:, remaining: products.size - imported - failed }
  end

  private
    def issue_account_setup_token!(**attributes)
      token = SecureRandom.urlsafe_base64(32)
      update!(account_setup_token_digest: self.class.digest(token), account_setup_sent_at: Time.current, account_setup_emails_count: account_setup_emails_count + 1, **attributes)
      token
    end

    def send_account_setup_email(token)
      CreatorMailer.partner_migration_account_setup(id, self.class.encrypt_account_setup_token(token)).deliver_later
    end

    def assign_public_id
      self.public_id ||= Nanoid.generate
    end

    def link_partner_seller!(claimer)
      partner_sellers = oauth_application.partner_sellers
      by_external_user = partner_sellers.find_by(external_user_id:)
      by_user = partner_sellers.find_by(user: claimer)

      if by_external_user&.user_id.present? && by_external_user.user_id != claimer.id
        raise ClaimError, "This #{oauth_application.name} account is already linked to a different Gumroad account."
      end
      if by_user.present? && by_user.external_user_id != external_user_id
        raise ClaimError, "Your Gumroad account is already linked to a different #{oauth_application.name} account."
      end

      partner_seller = by_user || partner_sellers.build(user: claimer, external_user_id:)
      partner_seller.deleted_at = nil
      partner_seller.save!
    end
end
