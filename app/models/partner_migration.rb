# frozen_string_literal: true

require "digest"

# A partner application's request to move one of its users' catalogs to Gumroad. Only SHA-256 digests
# of the onboarding code and the account setup token are stored. Nothing imports until the creator
# confirms the catalog that the page showed, so every claim checks the digest that page carried.
class PartnerMigration < ApplicationRecord
  EXPIRES_IN = 7.days
  # The job touches the migration around each transfer, and one download stops after
  # RemoteFileTransfer::MAX_DOWNLOAD_DURATION. A longer gap after an attempt started usually means the
  # job was lost, so ResumeStalledPartnerMigrationsJob queues it again. Twice the download limit leaves
  # the same time again for the upload that follows it.
  STALLED_AFTER = PartnerMigration::RemoteFileTransfer::MAX_DOWNLOAD_DURATION * 2
  CONFIRMATION_PREVIEW_SIZE = 5
  MAX_PRODUCTS = 500
  # A larger catalog comes in parts of up to MAX_PRODUCTS each. The seller confirms all parts at once.
  MAX_PARTS = 50
  MAX_EXTERNAL_USER_ID_LENGTH = 255
  MAX_NAME_LENGTH = 255
  MAX_FAILURE_REASON_LENGTH = 255
  # Across the product and its variants, counting a URL once.
  MAX_FILES_PER_PRODUCT = 100
  MAX_VARIANT_DESCRIPTION_LENGTH = 255
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
  class PartError < StandardError; end
  class AccountSetupError < StandardError; end

  INVALID_LINK_MESSAGE = "This link is invalid or expired."
  OUT_OF_DATE_MESSAGE = "This page is out of date. Open the link from the application again."
  INACTIVE_ACCOUNT_MESSAGE = "This account cannot import products."

  belongs_to :oauth_application
  belongs_to :user, optional: true

  attr_readonly :public_id
  before_validation :assign_public_id, on: :create

  validates :external_user_id, presence: true, length: { maximum: MAX_EXTERNAL_USER_ID_LENGTH }
  validates :code_digest, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :expires_at, presence: true
  validates :public_id, format: { with: PUBLIC_ID_FORMAT }

  # Only an attempt that started counts: a job can wait in the queue for longer than STALLED_AFTER.
  scope :stalled, -> { where(status: STATUS_CLAIMED, updated_at: ...STALLED_AFTER.ago).where.not(import_started_at: nil) }

  # Part 1 holds the seller's link, email and profile. The link of part 1 opens the whole catalog.
  def self.create_for!(oauth_application:, external_user_id:, products:, part: 1, total_parts: nil, email: nil, profile: nil, new_link: false)
    attempts = 0

    begin
      attempts += 1
      code = SecureRandom.urlsafe_base64(32)
      oauth_application.with_lock do
        # Locked before any later part, in the order that the claim and the result email take them.
        head = lock.find_by(oauth_application:, external_user_id:, part: 1)
        raise PartError, "Send part 1 before part #{part}." if part > 1 && head.nil?
        raise PartError, "total_parts must be at least #{part}." if total_parts && total_parts < part

        siblings = where(oauth_application:, external_user_id:)
        # A catalog that shrank drops the parts above total_parts, before the seller confirms.
        obsolete_parts = total_parts ? siblings.where(part: (total_parts + 1)..) : none
        # Each part imports on its own, so a product in two parts would import twice.
        other_ids = siblings.where.not(part:).where.not(id: obsolete_parts.select(:id)).pluck(Arel.sql("JSON_EXTRACT(products, '$[*].external_product_id')"))
        shared_id = other_ids.flat_map { Array(_1.is_a?(String) ? JSON.parse(_1) : _1) }.intersection(products.map { _1["external_product_id"] }).first
        raise PartError, "external_product_id #{shared_id.inspect} is already in another part." if shared_id

        migration = part == 1 ? head : find_by(oauth_application:, external_user_id:, part:)
        # The seller confirms every part at once, so after that no part can change its catalog.
        confirmed = head.present? && !head.pending?
        if migration
          same_catalog = catalog_identity(migration.products) == catalog_identity(products)
          if confirmed && !same_catalog
            raise CatalogConflict, "This seller already has an export. Keep the same products and file order when refreshing download URLs."
          end
          # After the claim, the account is settled, so a new email or profile no longer applies.
          seller = part == 1 && !confirmed ? { email:, profile: } : {}
          # New URLs alone keep the seller's link, so the partner does not have to send it again. Any other
          # change replaces the link, so a page that showed the old catalog or email cannot confirm it.
          # `new_link` lets a partner that lost the response get a link again.
          keep_link = !new_link && same_catalog && seller.all? { |key, value| migration[key] == value }
          migration.update!(products:, **seller)
        else
          raise CatalogConflict, "This seller already confirmed the export, so it cannot take another part." if confirmed

          # A later part gets a code that is never sent, because the link of part 1 opens it.
          own_code = part == 1 ? code : SecureRandom.urlsafe_base64(32)
          migration = create!(oauth_application:, external_user_id:, part:, products:, **(part == 1 ? { email:, profile: } : {}), code_digest: digest(own_code), expires_at: EXPIRES_IN.from_now)
          keep_link = false
        end
        if obsolete_parts.exists?
          raise CatalogConflict, "This seller already confirmed #{obsolete_parts.maximum(:part)} parts, so total_parts cannot remove any." if confirmed

          obsolete_parts.delete_all
          keep_link = false
        end
        # A new part 1 already has its link. An update would also clear previously_new_record?, which the
        # response reads.
        head&.update!(expires_at: EXPIRES_IN.from_now, **(keep_link ? {} : { code_digest: digest(code) }))
        migration.retry_failed_products!
        code = nil if keep_link
        [migration, code]
      end
    rescue ActiveRecord::RecordNotUnique
      retry if attempts < MAX_CODE_GENERATION_ATTEMPTS
      raise
    end
  end

  def self.find_by_code(code)
    return if code.blank?

    find_by(code_digest: digest(code), part: 1)
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
      variant_categories = product["variant_categories"].map do |category|
        category.merge("variants" => category["variants"].map { |variant| variant["files"] ? variant.merge("files" => variant["files"].map { _1.except("url") }) : variant })
      end
      product.except("files", "covers", "thumbnail_url").merge(
        "files" => product["files"].map { _1.except("url") },
        "covers" => product["covers"].size,
        "thumbnail" => product["thumbnail_url"].present?,
        "variant_categories" => variant_categories,
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
    migration if migration&.account_setup_open?
  end

  # Returns [products, nil] with only the supported keys, or [nil, error message].
  def self.normalize_products(raw_products)
    return [nil, "products must be an array with 1 to #{MAX_PRODUCTS} items."] unless raw_products.is_a?(Array) && raw_products.size.between?(1, MAX_PRODUCTS)

    products = raw_products.each_with_index.map do |raw, index|
      product, error = normalize_product(raw)
      return [nil, "products[#{index}]: #{error}"] if error

      product
    end
    duplicate_id = products.map { _1["external_product_id"] }.tally.find { _2 > 1 }&.first
    return [nil, "external_product_id #{duplicate_id.inspect} appears more than once."] if duplicate_id

    [products, nil]
  end

  def self.normalize_product(raw)
    return [nil, "must be an object."] unless raw.respond_to?(:key?)
    unless string?(raw[:external_product_id]) && raw[:external_product_id].strip.present? && raw[:external_product_id].length <= MAX_EXTERNAL_USER_ID_LENGTH
      return [nil, "external_product_id must be a string with 1 to #{MAX_EXTERNAL_USER_ID_LENGTH} characters, not only spaces."]
    end
    return [nil, "is_adult must be true or false."] unless [nil, true, false].include?(raw[:is_adult])
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

    files, error = normalize_files(raw[:files], "files")
    return [nil, error] if error

    covers = raw[:covers].nil? ? [] : raw[:covers]
    return [nil, "covers must be an array with up to #{Link::MAX_PREVIEW_COUNT} items."] unless covers.is_a?(Array) && covers.size <= Link::MAX_PREVIEW_COUNT
    return [nil, "each cover needs an https url."] unless covers.all? { _1.respond_to?(:key?) && https_url?(_1[:url]) }
    return [nil, "thumbnail_url must be an https URL."] unless raw[:thumbnail_url].nil? || https_url?(raw[:thumbnail_url])

    variant_categories, error = normalize_variant_categories(raw[:variant_categories])
    return [nil, error] if error
    if variant_categories.any? { _1["variants"].any? { |variant| raw[:price] + variant["price_difference_cents"] > BasePrice::Shared::MAX_PRICE_CENTS } }
      return [nil, "the product price plus each variant price difference must be at most #{BasePrice::Shared::MAX_PRICE_CENTS} cents."]
    end
    file_count = (files + variant_categories.flat_map { _1["variants"] }.flat_map { _1["files"].to_a }).map { _1["url"] }.uniq.size
    return [nil, "a product can have up to #{MAX_FILES_PER_PRODUCT} different file URLs, counting its variants."] if file_count > MAX_FILES_PER_PRODUCT

    [{
      "external_product_id" => raw[:external_product_id],
      "name" => raw[:name].strip,
      "description" => raw[:description],
      "price" => raw[:price],
      "price_currency_type" => currency,
      "taxonomy_id" => raw[:taxonomy_id],
      "tags" => tags,
      "files" => files,
      "covers" => covers.map { { "url" => _1[:url] } },
      "thumbnail_url" => raw[:thumbnail_url],
      "is_adult" => raw[:is_adult] || false,
      "variant_categories" => variant_categories,
    }, nil]
  end

  def self.normalize_files(raw_files, field)
    files = raw_files.nil? ? [] : raw_files
    return [nil, "#{field} must be an array."] unless files.is_a?(Array)
    return [nil, "each file in #{field} needs an https url and an optional display_name string."] unless files.all? { _1.respond_to?(:key?) && https_url?(_1[:url]) && (_1[:display_name].nil? || string?(_1[:display_name])) }
    # A URL counts once, as normalize_product counts it across the variants.
    return [nil, "#{field} can have up to #{MAX_FILES_PER_PRODUCT} different URLs."] if files.map { _1[:url] }.uniq.size > MAX_FILES_PER_PRODUCT
    return [nil, "file display_name must have at most #{MAX_NAME_LENGTH} characters."] if files.any? { _1[:display_name].to_s.length > MAX_NAME_LENGTH }

    [files.map { { "url" => _1[:url], "display_name" => _1[:display_name] } }, nil]
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
        unless variant[:description].nil? || (string?(variant[:description]) && variant[:description].length <= MAX_VARIANT_DESCRIPTION_LENGTH)
          return [nil, "variant description must be a string with at most #{MAX_VARIANT_DESCRIPTION_LENGTH} characters."]
        end

        files = nil
        unless variant[:files].nil?
          files, error = normalize_files(variant[:files], "variant files")
          return [nil, error] if error
        end

        { "name" => variant[:name].strip, "description" => variant[:description].presence, "price_difference_cents" => variant[:price_difference_cents] || 0, "files" => files }.compact
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
  private_class_method :catalog_identity, :normalize_product, :normalize_files, :normalize_variant_categories, :string?, :unique_tag_names, :tag_error, :https_url?

  def pending? = status == STATUS_PENDING
  def expired?(at = Time.current) = expires_at <= at

  def parts = self.class.where(oauth_application_id:, external_user_id:).order(:part)

  def head = part == 1 ? self : self.class.find_by!(oauth_application_id:, external_user_id:, part: 1)

  # The number of products across the parts, without loading their catalogs.
  def catalog_size = parts.sum("JSON_LENGTH(products)").to_i

  # The status of the whole catalog: claimed until every part finished, then failed if any part failed.
  def catalog_status
    statuses = parts.distinct.pluck(:status)
    return statuses.first if statuses.one?
    return STATUS_CLAIMED if statuses.intersect?([STATUS_PENDING, STATUS_CLAIMED])

    STATUS_FAILED
  end

  def claimable?
    pending? && !expired? && oauth_application.alive? && oauth_application.is_partner?
  end

  # An existing account must log in and confirm, so a partner cannot add products to an account
  # just by naming its email. The address check is the one that signup uses (User::Validations#email_almost_unique).
  def account_creatable?
    claimable? && email.present? && !User.by_email(email).exists?
  end

  # Setup ends once the seller gets into the account another way, by a password reset or by signing in
  # with Google, so an older setup link cannot replace those credentials. A closed or suspended account
  # cannot finish setup either: the setup link signs the holder in.
  def account_setup_pending?
    account_created && account_setup_token_digest.present? && user.present? && user.account_active? && user.sign_in_count.zero? &&
      self.class.digest(user.encrypted_password) == account_setup_password_digest
  end

  def account_setup_expired? = claimed_at.nil? || claimed_at + ACCOUNT_SETUP_EXPIRES_IN <= Time.current
  # The seller can still set a password from the setup email.
  def account_setup_open? = account_setup_pending? && !account_setup_expired?
  def stalled? = status == STATUS_CLAIMED && import_started_at.present? && updated_at < STALLED_AFTER.ago

  def masked_email
    local_part, domain = email.split("@", 2)
    "#{local_part.first}•••@#{domain}"
  end

  # Creates the seller's account, claims the import for it, and emails a link to set a password.
  # Returns nil, or a message for the seller when the account cannot be created.
  def create_account_and_claim!(ip:, expected_code_digest:)
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
        token = issue_account_setup_token!(account_created: true, account_setup_password_digest: self.class.digest(user.encrypted_password))
        claim!(user, expected_code_digest:)
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
  def complete_account_setup!(password:, ip:, expected_token_digest:)
    raise AccountSetupError, INVALID_LINK_MESSAGE unless account_setup_open?

    # A local, because the lock reloads this record and its user.
    account = user
    account.password = password
    account.skip_confirmation! unless account.confirmed?
    account.tos_agreements.build(ip:)
    # Validation calls the breached-password API, so it runs before the lock that the import job waits on.
    account.validate!
    transaction do
      # The seller row first, then this row, in the order that the import job takes them. The check below
      # then reads the seller as it is now, so a password reset that committed first ends the setup.
      User.lock.find(user_id)
      with_lock do
        # The page that the seller submitted showed this token; a resend since then replaced it.
        raise AccountSetupError, INVALID_LINK_MESSAGE unless account_setup_open? && account_setup_token_digest == expected_token_digest

        account.save!(validate: false)
        update!(account_setup_token_digest: nil)
      end
    end
    # skip_confirmation! skips User#after_confirmation, which attaches the address's guest purchases.
    AttachPastPurchasesToUserWorker.perform_async(account.id, account.email)
    # The saved account, because Devise signs in with the password hash that it holds.
    account
  end

  # The same creator can claim again while the import has not finished, so a failed enqueue can be
  # retried from the confirmation page. The job skips the products that it already imported.
  def claimable_by?(claimer)
    claimable? || (status == STATUS_CLAIMED && user_id == claimer.id)
  end

  # Links `claimer` to the partner's user ID, then starts the import. Raises ClaimError with a
  # message for the creator when the link was used, expired, or belongs to a different account.
  def claim!(claimer, expected_code_digest:)
    raise ClaimError, INACTIVE_ACCOUNT_MESSAGE unless claimer.account_active?
    raise ClaimError, "Add an email address to your Gumroad account before importing products." if claimer.form_email.blank?

    oauth_application.with_lock do
      with_lock do
        raise ClaimError, OUT_OF_DATE_MESSAGE unless code_digest == expected_code_digest
        raise ClaimError, INVALID_LINK_MESSAGE unless claimable_by?(claimer)

        unless status == STATUS_CLAIMED
          link_partner_seller!(claimer)
          # The link opens the whole catalog, so the claim takes every part.
          parts.lock.each { _1.update!(user: claimer, status: STATUS_CLAIMED, claimed_at: Time.current) }
          reload
        end
        # Queued under the lock: if queueing fails, the claim rolls back, so a claimed import always has
        # a job. Each job locks its part first, so it waits for this transaction to commit.
        parts.where(status: STATUS_CLAIMED).pluck(:id).each { PartnerMigrationImportJob.perform_async(_1) }
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

      update!(results: results.to_h.reject { |_index, result| result.key?("error") }, status: STATUS_CLAIMED, failure_reason: nil, completed_at: nil, notified_at: nil, notification_failed_email: nil, resumes_count: 0, import_started_at: nil)
      # The result email reads a rejected address from part 1, so the retry clears it there too.
      # create_for! has already locked part 1.
      head.update!(notification_failed_email: nil) if part > 1
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
    stopped_too_often = false
    with_lock do
      next unless stalled?

      if !user&.account_active?
        failure_reason = INACTIVE_ACCOUNT_MESSAGE
      elsif resumes_count >= MAX_RESUMES
        failure_reason = "The import stopped #{MAX_RESUMES + 1} times before it finished."
        stopped_too_often = true
      # A running import touches this row at least once per STALLED_AFTER, so a stalled import has no live
      # worker, and a rejected enqueue means a killed worker left its lock behind. The job skips products
      # that another run saved, so a job still waiting in the queue cannot import them twice.
      elsif PartnerMigrationImportJob.perform_async(id) || PartnerMigrationImportJob.enqueue_releasing_lock(id)
        # The queued job has not started, so the scan does not count it again while it waits.
        update!(resumes_count: resumes_count + 1, import_started_at: nil)
      end
      if failure_reason
        update!(status: STATUS_FAILED, completed_at: Time.current, failure_reason:)
        # A killed worker may have left its lock, which would stop the next export from retrying the products.
        PartnerMigrationImportJob.release_lock(id)
      end
    end
    # An inactive account is expected to stop its import, so only the repeated stops reach Sentry.
    ErrorNotifier.notify(failure_reason, partner_migration_id: id) if stopped_too_often
    PartnerMigrationNotificationJob.perform_async(id) if failure_reason
  end

  def progress
    recorded_results = results.to_h.values
    imported = recorded_results.count { _1["product_id"].present? }
    failed = recorded_results.count { _1["error"].present? }
    { total: products.size, imported:, failed:, remaining: products.size - imported - failed }
  end

  # The job records results by position in the catalog. The partner matches them by its own product ID.
  def results_by_external_product_id
    results.to_h.transform_keys { products[_1.to_i]["external_product_id"] }
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
      PartnerSeller.link!(oauth_application:, user: claimer, external_user_id:)
    rescue PartnerSeller::LinkConflict => e
      raise ClaimError, e.message
    end
end
