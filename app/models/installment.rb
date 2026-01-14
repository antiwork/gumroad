# frozen_string_literal: true

require "custom_rouge_theme"

class Installment < ApplicationRecord
  has_paper_trail

  include Rails.application.routes.url_helpers
  include ExternalId, ActionView::Helpers::SanitizeHelper, ActionView::Helpers::TextHelper, CurrencyHelper, S3Retrievable, WithProductFiles, Deletable, JsonData,
          WithFiltering, Post::Caching, Installment::Searchable, FlagShihTzu
  extend FriendlyId

  PRODUCT_LIST_PLACEHOLDER_TAG_NAME = "product-list-placeholder"
  MAX_ABANDONED_CART_PRODUCTS_TO_SHOW_IN_EMAIL = 3

  PUBLISHED = "published"
  SCHEDULED = "scheduled"
  DRAFT = "draft"

  LANGUAGE_LEXERS = {
    "arduino" => Rouge::Lexers::Cpp,
    "bash" => Rouge::Lexers::Shell,
    "c" => Rouge::Lexers::C,
    "cpp" => Rouge::Lexers::Cpp,
    "csharp" => Rouge::Lexers::CSharp,
    "css" => Rouge::Lexers::CSS,
    "diff" => Rouge::Lexers::Diff,
    "go" => Rouge::Lexers::Go,
    "graphql" => Rouge::Lexers::GraphQL,
    "ini" => Rouge::Lexers::INI,
    "java" => Rouge::Lexers::Java,
    "javascript" => Rouge::Lexers::Javascript,
    "json" => Rouge::Lexers::JSON,
    "kotlin" => Rouge::Lexers::Kotlin,
    "less" => Rouge::Lexers::CSS,
    "lua" => Rouge::Lexers::Lua,
    "makefile" => Rouge::Lexers::Make,
    "markdown" => Rouge::Lexers::Markdown,
    "objectivec" => Rouge::Lexers::ObjectiveC,
    "perl" => Rouge::Lexers::Perl,
    "php" => Rouge::Lexers::PHP,
    "php-template" => Rouge::Lexers::PHP,
    "plaintext" => Rouge::Lexers::PlainText,
    "python" => Rouge::Lexers::Python,
    "python-repl" => Rouge::Lexers::Python,
    "r" => Rouge::Lexers::R,
    "ruby" => Rouge::Lexers::Ruby,
    "rust" => Rouge::Lexers::Rust,
    "scss" => Rouge::Lexers::Scss,
    "shell" => Rouge::Lexers::Shell,
    "sql" => Rouge::Lexers::SQL,
    "swift" => Rouge::Lexers::Swift,
    "typescript" => Rouge::Lexers::Typescript,
    "vbnet" => Rouge::Lexers::VisualBasic,
    "wasm" => Rouge::Lexers::ArmAsm,
    "xml" => Rouge::Lexers::XML,
    "yaml" => Rouge::Lexers::YAML
  }.freeze

  attr_json_data_accessor :workflow_trigger

  belongs_to :link, optional: true
  belongs_to :base_variant, optional: true
  belongs_to :seller, class_name: "User", optional: true
  belongs_to :workflow, optional: true
  has_many :url_redirects
  has_one :installment_rule
  has_many :installment_events
  has_many :email_infos
  has_many :purchases, through: :email_infos
  has_many :comments, as: :commentable
  has_many :sent_post_emails, foreign_key: "post_id"
  has_many :blasts, class_name: "PostEmailBlast", foreign_key: "post_id"
  has_many :sent_abandoned_cart_emails

  friendly_id :slug_candidates, use: :slugged

  after_save :trigger_iffy_ingest

  validates :name, length: { maximum: 255 }
  validate :message_must_be_provided, :validate_call_to_action_url_and_text, :validate_channel,
           :published_at_cannot_be_in_the_future, :validate_sending_limit_for_sellers
  validate :shown_on_profile_only_for_confirmed_users, if: :shown_on_profile_changed?

  has_flags 1 => :is_unpublished_by_admin,
            2 => :DEPRECATED_is_automated_installment,
            3 => :DEPRECATED_stream_only,
            4 => :DEPRECATED_is_open_rate_tracking_enabled,
            5 => :DEPRECATED_is_click_rate_tracking_enabled,
            6 => :is_for_new_customers_of_workflow,
            7 => :workflow_installment_published_once_already,
            8 => :shown_on_profile,
            9 => :send_emails,
            10 => :ready_to_publish,
            11 => :allow_comments,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  scope :published,                       -> { where.not(published_at: nil) }
  scope :not_published,                   -> { where(published_at: nil) }
  scope :scheduled,                       -> { not_published.ready_to_publish }
  scope :draft,                           -> { not_published.not_ready_to_publish }
  scope :not_workflow_installment,        -> { where(workflow_id: nil) }
  scope :send_emails,                     -> { where("installments.flags & ? > 0", Installment.flag_mapping["flags"][:send_emails]) }
  scope :profile_only,                    -> { not_send_emails.shown_on_profile }
  scope :visible_on_profile,              -> { alive.published.audience_type.shown_on_profile.not_workflow_installment }

  scope :ordered_updates, -> (user, type) {
    order_clause = if type == DRAFT
      { updated_at: :desc }
    else
      Arel.sql("published_at IS NULL, COALESCE(published_at, installments.created_at) DESC")
    end
    # The custom `ORDER BY` clause does the following:
    #   - Keep all unpublished updates at the top
    #   - Sort unpublished updates by `created_at DESC` and sort published updates by `published_at DESC`
    by_seller_sql = where(seller: user).to_sql
    by_product_sql = where(link_id: user.links.visible.select(:id)).to_sql
    from("((#{by_seller_sql}) UNION (#{by_product_sql})) installments")
      .alive
      .not_workflow_installment
      .order(order_clause)
  }

  scope :filter_by_product_id_if_present,    -> (product_id) {
    if product_id.present?
      where(link_id: product_id)
    end
  }

  scope :missed_for_purchase, -> (purchase) {
    product_installment_ids = purchase.link.installments.where(seller_id: purchase.seller_id).alive.published.filter_map do |post|
      post.id if post.purchase_passes_filters(purchase)
    end
    seller_installment_ids = purchase.seller.installments.alive.published.filter_map do |post|
      post.id if post.purchase_passes_filters(purchase)
    end

    purchase_ids_with_same_email = Purchase.where(email: purchase.email, seller_id: purchase.seller_id)
                                           .all_success_states
                                           .not_fully_refunded
                                           .not_chargedback_or_chargedback_reversed
                                           .pluck(:id)

    where_sent_sql = <<-SQL.squish
      NOT EXISTS (
        SELECT 1
        FROM email_infos
        WHERE installments.id = email_infos.installment_id
        AND email_infos.purchase_id IN (#{purchase_ids_with_same_email.append(purchase.id).join(", ")})
        AND email_infos.installment_id IS NOT NULL
      )
    SQL

    send_emails.
      where(id: product_installment_ids + seller_installment_ids).
      where(where_sent_sql)
  }

  scope :product_or_variant_with_sent_emails_for_purchases, -> (purchase_ids) {
    send_emails.
      joins(:purchases).
      where("purchases.id IN (?)", purchase_ids).
      product_or_variant_type.
      alive.
      published.
      order("email_infos.sent_at DESC, email_infos.delivered_at DESC, email_infos.id DESC").
      select("installments.*, email_infos.sent_at, email_infos.delivered_at, email_infos.opened_at")
  }

  scope :seller_with_sent_emails_for_purchases, -> (purchase_ids) {
    alive.
      published.
      send_emails.
      seller_type.
      joins(:purchases).
      where("purchases.id IN (?)", purchase_ids)
  }

  scope :profile_only_for_products, -> (product_ids) {
    profile_only.
      alive.
      published.
      product_type.
      where(link_id: product_ids, base_variant_id: nil)
  }

  scope :profile_only_for_variants, -> (variant_ids) {
    profile_only.
      alive.
      published.
      variant_type.
      where(base_variant_id: variant_ids)
  }

  scope :profile_only_for_sellers, -> (seller_ids) {
    alive.
      published.
      profile_only.
      seller_type.
      where(seller_id: seller_ids)
  }

  scope :for_products, ->(product_ids:) {
    alive.
      published.
      not_workflow_installment.
      product_type.
      where(link_id: product_ids)
  }

  scope :for_variants, ->(variant_ids:) {
    alive.
      published.
      not_workflow_installment.
      variant_type.
      where(base_variant_id: variant_ids)
  }

  scope :for_sellers, ->(seller_ids:) {
    alive.
      published.
      not_workflow_installment.
      seller_type.
      where(seller_id: seller_ids)
  }

  scope :past_posts_to_show_for_products, -> (product_ids:, excluded_post_ids: []) {
    exclude_posts_sql = excluded_post_ids.empty? ? "" : sanitize_sql_array(["installments.id NOT IN (?) AND ", excluded_post_ids])
    joins(:link).
      for_products(product_ids:).
      where("#{exclude_posts_sql}links.flags & ?", Link.flag_mapping["flags"][:should_show_all_posts])
  }

  scope :past_posts_to_show_for_variants, -> (variant_ids:, excluded_post_ids: []) {
    exclude_posts_sql = excluded_post_ids.empty? ? "" : sanitize_sql_array(["installments.id NOT IN (?) AND ", excluded_post_ids])
    joins(:link).
      for_variants(variant_ids:).
      where("#{exclude_posts_sql}links.flags & ?", Link.flag_mapping["flags"][:should_show_all_posts])
  }

  scope :seller_posts_for_sellers, -> (seller_ids:, excluded_post_ids: []) {
    exclude_posts_sql = excluded_post_ids.empty? ? "" : sanitize_sql_array(["installments.id NOT IN (?)", excluded_post_ids])
    for_sellers(seller_ids:).where(exclude_posts_sql)
  }

  scope :emailable_posts_for_purchase, ->(purchase:) do
    subqueries = [
      for_products(product_ids: [purchase.link_id]).send_emails,
      for_variants(variant_ids: purchase.variant_attributes.pluck(:id)).send_emails,
      seller_posts_for_sellers(seller_ids: [purchase.seller_id]).send_emails,
    ]
    subqueries_sqls = subqueries.map { "(" + _1.to_sql + ")" }
    from("(" + subqueries_sqls.join(" UNION ") + ") AS #{table_name}")
  end

  scope :group_by_installment_rule, -> (timezone) {
    includes(:installment_rule)
      .sort_by { |post| post.installment_rule.to_be_published_at }
      .group_by { |post| post.installment_rule.to_be_published_at.in_time_zone(timezone).strftime("%B %-d, %Y") }
  }

  SENDING_LIMIT = 100
  MINIMUM_SALES_CENTS_VALUE = 100_00 # $100

  MEMBER_CANCELLATION_WORKFLOW_TRIGGER = "member_cancellation"

  def user
    seller.presence || link.user
  end

  def installment_mobile_json_data(purchase: nil, subscription: nil, imported_customer: nil, follower: nil)
    installment_url_redirect = if subscription.present?
      url_redirect(subscription) || generate_url_redirect_for_subscription(subscription)
    elsif purchase.present?
      purchase_url_redirect(purchase) || generate_url_redirect_for_purchase(purchase)
    elsif imported_customer.present?
      imported_customer_url_redirect(imported_customer) || generate_url_redirect_for_imported_customer(imported_customer)
    elsif follower.present?
      # Default to sending follower post instead of breaking up
      follower_or_audience_url_redirect || generate_url_redirect_for_follower
    end

    files_data = alive_product_files.map do |product_file|
      installment_url_redirect.mobile_product_file_json_data(product_file)
    end
    released_at = if purchase.present?
      action_at_for_purchase(purchase.original_purchase)
    elsif subscription.present?
      action_at_for_purchase(subscription.original_purchase)
    end
    {
      files_data:,
      message:,
      name:,
      call_to_action_text:,
      call_to_action_url:,
      installment_type:,
      published_at: released_at || published_at,
      external_id:,
      url_redirect_external_id: installment_url_redirect.external_id,
      creator_name: seller.name_or_username,
      creator_profile_picture_url: seller.avatar_url,
      creator_profile_url: seller.profile_url
    }
  end

  def member_cancellation_trigger?
    workflow_trigger == MEMBER_CANCELLATION_WORKFLOW_TRIGGER
  end

  def displayed_name
    return name if name.present?

    truncate(strip_tags(message), separator: " ", length: 48)
  end

  def truncated_description
    TextScrubber.format(message).squish.truncate(255)
  end

  def message_with_inline_syntax_highlighting_and_upsells
    return message if message.blank?

    doc = Nokogiri::HTML.fragment(message)

    doc.search("pre > code").each do |node|
      language = node.attr("class")&.sub("language-", "")
      content = node.content
      lexer = (language.present? ? LANGUAGE_LEXERS[language] : Rouge::Lexer.guesses(source: content).first) || Rouge::Lexers::PlainText
      tokens = lexer.lex(content)
      formatter = Rouge::Formatters::HTMLInline.new(CustomRougeTheme.mode(:light))
      node.parent.replace(%(<pre style="white-space: revert; overflow: auto; border: 1px solid currentColor; border-radius: 4px; background-color: #fff;"><code style="max-width: unset; border-width: 0; width: 100vw; background-color: #fff;">#{formatter.format(tokens)}</code></pre>))
    end

    doc.search("upsell-card").each do |card|
      upsell_id = card["id"]

      upsell = seller.upsells.find_by_external_id!(upsell_id)
      product = upsell.product

      card.replace(
        ApplicationController.renderer.render(
          template: "posts/upsell",
          layout: false,
          assigns: {
            product: product,
            offer_code: upsell.offer_code,
            upsell_url: checkout_index_url(accepted_offer_id: upsell.external_id, product: product.unique_permalink, host: DOMAIN)
          }
        )
      )
    end

    doc.search(".tiptap__raw[data-url]").each do |node|
      thumbnail_url = node["data-thumbnail"]
      target_url = node["data-url"]
      alt_title = node["data-title"]
      return if target_url.blank?

      content = thumbnail_url.present? ? "<img src='#{thumbnail_url}' alt='#{alt_title}' />" : alt_title.presence || target_url
      node.replace(%(<p><a href="#{target_url}" target="_blank" rel="noopener noreferrer">#{content}</a></p>))
    end

    doc.to_html
  end

  def message_with_inline_abandoned_cart_products(products:, checkout_url: nil)
    return message if message.blank? || products.blank?

    default_checkout_url = Rails.application.routes.url_helpers.checkout_index_url(host: UrlService.domain_with_protocol)
    checkout_url ||= default_checkout_url

    doc = Nokogiri::HTML.fragment(message_with_inline_syntax_highlighting_and_upsells)
    doc.search("#{PRODUCT_LIST_PLACEHOLDER_TAG_NAME}").each do |node|
      node.replace(
        ApplicationController.renderer.render(
          template: "posts/abandoned_cart_products_list",
          layout: false,
          assigns: { products: },
        )
      )
    end
    doc.search("a[href='#{default_checkout_url}']").each { _1["href"] = checkout_url } if default_checkout_url != checkout_url
    doc.to_html
  end

  def send_preview_email(recipient_user)
    if recipient_user.has_unconfirmed_email?
      raise PreviewEmailError, "You have to confirm your email address before you can do that."
    elsif abandoned_cart_type?
      CustomerMailer.abandoned_cart_preview(recipient_user.id, id).deliver_later
    else
      recipient = { email: recipient_user.email }
      recipient[:url_redirect] = UrlRedirect.find_or_create_by!(installment: self, purchase: nil) if has_files?
      PostEmailApi.process(post: self, recipients: [recipient], preview: true)
    end
  end

  def send_installment_from_workflow_for_purchase(purchase_id)
    sale = Purchase.find(purchase_id)
    return if sale.is_recurring_subscription_charge

    sale = sale.original_purchase
    return unless sale.can_contact?
    return if sale.chargedback_not_reversed_or_refunded?
    return if sale.subscription.present? && !sale.subscription.alive?

    other_purchase_ids = Purchase.where(email: sale.email, seller_id: sale.seller_id)
                                 .all_success_states
                                 .no_or_active_subscription
                                 .not_fully_refunded
                                 .not_chargedback_or_chargedback_reversed
                                 .pluck(:id)
    return if other_purchase_ids.present? && CreatorContactingCustomersEmailInfo.where(purchase: other_purchase_ids, installment: id).present?

    return if workflow.present? && !workflow.applies_to_purchase?(sale)
    expected_delivery_time_for_sale = expected_delivery_time(sale)
    if Time.current < expected_delivery_time_for_sale
      # reschedule for later if it's too soon to send (only applicable for subscriptions
      # that have been terminated and later restarted)
      SendWorkflowInstallmentWorker.perform_at(expected_delivery_time_for_sale + 1.minute, id, installment_rule.version, sale.id, nil)
    else
      SentPostEmail.ensure_uniqueness(post: self, email: sale.email) do
        recipient = { email: sale.email, purchase: sale }
        recipient[:url_redirect] = generate_url_redirect_for_purchase(sale) if has_files?
        send_email(recipient)
      end
    end
  end

  def send_installment_from_workflow_for_member_cancellation(subscription_id)
    return unless member_cancellation_trigger?

    subscription = Subscription.find(subscription_id)
    return if subscription.alive?

    sale = subscription.original_purchase
    return unless sale.present?
    return unless sale.can_contact?
    return if sale.chargedback_not_reversed_or_refunded?

    other_purchase_ids = Purchase.where(email: sale.email, seller_id: sale.seller_id)
                                 .all_success_states
                                 .inactive_subscription
                                 .not_fully_refunded
                                 .not_chargedback_or_chargedback_reversed
                                 .pluck(:id)
    return if other_purchase_ids.present? && CreatorContactingCustomersEmailInfo.where(purchase: other_purchase_ids, installment: id).present?

    return if workflow.present? && !workflow.applies_to_purchase?(sale)

    SentPostEmail.ensure_uniqueness(post: self, email: sale.email) do
      recipient = { email: sale.email, purchase: sale, subscription: }
      recipient[:url_redirect] = generate_url_redirect_for_subscription(sale) if has_files?
      send_email(recipient)
    end
  end

  def send_installment_from_workflow_for_follower(follower_id)
    follower = Follower.find_by(id: follower_id)
    return if follower.nil? || follower.deleted? || follower.unconfirmed? # check for nil followers because we removed duplicates that may have been queued

    SentPostEmail.ensure_uniqueness(post: self, email: follower.email) do
      recipient = { email: follower.email, follower: }
      recipient[:url_redirect] = generate_url_redirect_for_follower if has_files?
      send_email(recipient)
    end
  end

  def send_installment_from_workflow_for_affiliate_user(affiliate_user_id)
    affiliate_user = User.find_by(id: affiliate_user_id)
    return if affiliate_user.nil?

    SentPostEmail.ensure_uniqueness(post: self, email: affiliate_user.email) do
      recipient = { email: affiliate_user.email, affiliate: affiliate_user }
      recipient[:url_redirect] = generate_url_redirect_for_affiliate if has_files?
      send_email(recipient)
    end
  end

  def subject
    return name if name.present?

    (link.try(:name) || seller.name || "Creator").to_s + " - " + "Update"
  end

  def post_views_count
    installment_events_count.nil? ? 0 : installment_events_count
  end

  def full_url(purchase_id: nil)
    return unless slug.present?
    if user.subdomain_with_protocol.present?
      custom_domain_view_post_url(
        host: user.subdomain_with_protocol,
        slug:,
        purchase_id: purchase_id.presence
      )
    else
      view_post_path(
        username: user.username.presence || user.external_id,
        slug:,
        purchase_id: purchase_id.presence
      )
    end
  end

  def generate_url_redirect_for_imported_customer(imported_customer, product: nil)
    return unless imported_customer
    product ||= imported_customer.link
    UrlRedirect.create(installment: self, imported_customer:, link: product)
  end

  def generate_url_redirect_for_subscription(subscription)
    UrlRedirect.create(installment: self, subscription:)
  end

  def generate_url_redirect_for_purchase(purchase)
    UrlRedirect.create(installment: self, purchase:)
  end

  def generate_url_redirect_for_follower
    UrlRedirect.create(installment: self)
  end

  def generate_url_redirect_for_affiliate
    UrlRedirect.create(installment: self)
  end

  def url_redirect(subscription)
    UrlRedirect.where(subscription_id: subscription.id, installment_id: id).first
  end

  def purchase_url_redirect(purchase)
    UrlRedirect.where(purchase_id: purchase.id, installment_id: id).first if purchase
  end

  def imported_customer_url_redirect(imported_customer)
    UrlRedirect.where(imported_customer_id: imported_customer.id, installment_id: id).last
  end

  # Public: Returns the url redirect to be used for follower or audience installments.
  # These two types of installments have one single url redirect that is not tied to any individual follower/purchase.
  def follower_or_audience_url_redirect
    url_redirects.where(purchase_id: nil).last
  end

  # NOTE: This method is now only used in one place (PostPresenter), and shouldn't be expected to create any new records:
  # it can be heavily simplified / removed altogether.
  def download_url(subscription, purchase, imported_customer = nil)
    url_redirect = nil
    # workflow installments belonging to a subscription product will include subscription in the parameters and not check
    # purchase_url_redirect which is where the url is. This results in missing 'view attachment' button for some installments
    url_redirect = self.url_redirect(subscription) if subscription.present?

    if url_redirect.nil? && (follower_type? || audience_type? || affiliate_type?) && has_files?
      url_redirect = follower_or_audience_url_redirect
    elsif url_redirect.nil? && purchase.present?
      url_redirect = purchase_url_redirect(purchase)
    elsif imported_customer.present?
      url_redirect = imported_customer_url_redirect(imported_customer)
      return nil if !has_files?

      product_files = link.try(:alive_product_files)
      return nil if !has_files? && (product_files.nil? || product_files.empty?)
    end

    return nil if url_redirect.nil? && !has_files?
    return nil if url_redirect.nil? &&
      subscription.nil? &&
      purchase.nil? &&
      needs_purchase_to_access_content?

    # We turned off the feature where new subscribers get the last update, resulting in some url_redirects not being created.
    # We need to create the url_redirect and return the download_page_url for installments with files. This also protects us from
    # customers getting/seeing an installment without a 'View Attachments' button when it has files.
    if url_redirect.nil?
      url_redirect = if subscription.present?
        generate_url_redirect_for_subscription(subscription)
      else
        generate_url_redirect_for_purchase(purchase)
      end
      url_redirect.download_page_url
    else
      has_files? ? url_redirect.download_page_url : url_redirect.url
    end
  end

  def published?
    published_at.present?
  end

  def display_type
    return "published" if published?

    ready_to_publish? ? "scheduled" : "draft"
  end

  def publish!(published_at: nil)
    enforce_user_email_confirmation!
    transcode_videos!
    self.published_at = published_at.presence || Time.current
    self.workflow_installment_published_once_already = true if workflow.present?
    save!
  end

  def unpublish!(is_unpublished_by_admin: false)
    self.published_at = nil
    self.is_unpublished_by_admin = is_unpublished_by_admin
    save!
  end

  def is_affiliate_product_post?
    !!(affiliate_type? && affiliate_products&.one?)
  end

  def streamable?
    alive_product_files.map(&:filegroup).include?("video")
  end

  def stream_only?
    alive_product_files.all?(&:stream_only?)
  end

  def targeted_at_purchased_item?(purchase)
    return true if product_type? && link_id == purchase.link_id
    return true if variant_type? && purchase.variant_attributes.pluck(:id).include?(base_variant_id)
    return true if bought_products.present? && bought_products.include?(purchase.link.unique_permalink)
    return true if bought_variants.present? && (bought_variants & purchase.variant_attributes.map(&:external_id)).present?

    false
  end

  def passes_member_cancellation_checks?(purchase)
    return true unless member_cancellation_trigger?
    return false if purchase.nil?

    sent_email_info = CreatorContactingCustomersEmailInfo.where(installment_id: id, purchase_id: purchase.id).last

    sent_email_info.present?
  end

  def unique_open_count
    Rails.cache.fetch(key_for_cache(:unique_open_count)) do
      CreatorEmailOpenEvent.where(installment_id: id).count
    end
  end

  def unique_click_count
    Rails.cache.fetch(key_for_cache(:unique_click_count)) do
      summary = CreatorEmailClickSummary.where(installment_id: id).last
      summary.present? ? summary[:total_unique_clicks] : 0
    end
  end

  # Return a breakdown of clicks by url.
  def clicked_urls
    summary = CreatorEmailClickSummary.where(installment_id: id).last
    return {} if summary.blank?

    # Change urls back into human-readable format (Necessary because Mongo keys cannot contain ".") Also remove leading protocol & www
    summary.urls.keys.each { |k| summary.urls[k.gsub(/&#46;/, ".").sub(%r{^https?://}, "").sub(/^www./, "")] = summary.urls.delete(k) }
    Hash[summary.urls.sort_by { |_, v| v }.reverse] # Sort by number of clicks.
  end

  # Public: Returns the percentage of email opens for this installment, or nil if one cannot be calculated.
  def open_rate_percent
    unique_open_count = self.unique_open_count
    total_delivered = customer_count
    return nil if total_delivered.nil?
    return 100 if total_delivered == 0

    unique_open_count / total_delivered.to_f * 100
  end

  # Public: Returns the percentage of email clicks for this installment, or nil if one cannot be calculated.
  def click_rate_percent
    unique_click_count = self.unique_click_count
    total_delivered = customer_count
    return nil if total_delivered.nil?
    return 100 if total_delivered == 0

    unique_click_count / total_delivered.to_f * 100
  end

  def action_at_for_purchase(purchase)
    action_at_for_purchases([purchase.id])
  end

  def action_at_for_purchases(purchase_ids)
    email_info = CreatorContactingCustomersEmailInfo.where(installment_id: id, purchase_id: purchase_ids).last
    action_at = email_info.present? ? email_info.sent_at || email_info.delivered_at || email_info.opened_at : published_at
    action_at || Time.current
  end

  def increment_total_delivered(by: 1)
    self.class.update_counters id, customer_count: by
  end

  def eligible_purchase_for_user(user)
    # No purchase needed to view content for post sent to followers or audience, so return nil.
    return nil if user.blank? || !needs_purchase_to_access_content?

    purchases = user.purchases.successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
    purchases = if installment_type == PRODUCT_TYPE
      purchases.where(link_id:)
    elsif installment_type == VARIANT_TYPE
      user.purchases.where(link_id:).select { |purchase| purchase.variant_attributes.pluck(:id).include?(base_variant_id) }
    elsif installment_type == SELLER_TYPE
      purchases.where(seller_id:)
    end

    purchases && purchases.select { |purchase| purchase_passes_filters(purchase) }.first
  end

  def eligible_purchase?(purchase)
    return true unless needs_purchase_to_access_content?
    return false if purchase.nil?

    is_purchase_relevant = if product_type?
      purchase.link_id == link_id
    elsif variant_type?
      purchase.variant_attributes.pluck(:id).include?(base_variant_id)
    elsif seller_type?
      purchase.seller_id == seller_id
    else
      false
    end

    is_purchase_relevant && purchase_passes_filters(purchase)
  end

  def affiliate_product_name
    return unless is_affiliate_product_post?
    Link.find_by(unique_permalink: affiliate_products.first)&.name
  end

  def audience_members_filter_params
    params = {}

    if seller_or_product_or_variant_type?
      params[:type] = "customer"
    elsif follower_type?
      params[:type] = "follower"
    elsif affiliate_type?
      params[:type] = "affiliate"
    end

    params[:bought_product_ids] = seller.products.where(unique_permalink: bought_products).ids if bought_products.present?
    params[:not_bought_product_ids] = seller.products.where(unique_permalink: not_bought_products).ids if not_bought_products.present?
    params[:bought_variant_ids] = bought_variants&.map { ObfuscateIds.decrypt(_1) }
    params[:not_bought_variant_ids] = not_bought_variants&.map { ObfuscateIds.decrypt(_1) }
    params[:paid_more_than_cents] = paid_more_than_cents.presence
    params[:paid_less_than_cents] = paid_less_than_cents.presence
    params[:created_after] = Date.parse(created_after.to_s).in_time_zone(seller.timezone).iso8601 if created_after.present?
    params[:created_before] = Date.parse(created_before.to_s).in_time_zone(seller.timezone).end_of_day.iso8601 if created_before.present?
    params[:bought_from] = bought_from if bought_from.present?
    params[:affiliate_product_ids] = seller.products.where(unique_permalink: affiliate_products).ids if affiliate_products.present?

    params.compact_blank!
  end

  def audience_members_count(limit = nil)
    AudienceMember.filter(seller_id:, params: audience_members_filter_params).limit(limit).count
  end

  def self.receivable_by_customers_of_product(product:, variant_external_id:)
    product_permalink = product.unique_permalink
    product_variant_external_ids = product.alive_variants.map(&:external_id)

    posts = self.includes(:installment_rule, :seller).alive.published.where(seller_id: product.user_id).filter do |post|
      post.seller_or_product_or_variant_type? && (
        (post.bought_products.present? && post.bought_products.include?(product_permalink)) ||
        (post.bought_variants.present? && post.bought_variants.any? { product_variant_external_ids.include?(_1) }) ||
        (post.bought_products.blank? && post.bought_variants.blank?)
      )
    end

    if variant_external_id.present?
      posts = posts.filter do |post|
        (post.bought_products.blank? && post.bought_variants.blank?) ||
        (post.bought_products.presence || []).include?(product_permalink) ||
        (post.bought_variants.presence || []).include?(variant_external_id)
      end
    end

    posts.sort_by do |post|
      post.workflow_id.present? && post.installment_rule.present? ? DateTime.current + post.installment_rule.delayed_delivery_time : post.published_at
    end.reverse
  end

  def has_been_blasted? = blasts.exists?
  def can_be_blasted? = send_emails? && !has_been_blasted?

  def featured_image_url
    return nil if message.blank?

    fragment = Nokogiri::HTML.fragment(message)
    first_element = fragment.element_children.first
    return nil unless first_element&.name == "figure"

    first_element.at_css("img")&.attr("src")
  end

  def message_snippet
    return "" if message.blank?

    # Add spaces between paragraphs and line breaks, so that `Hello<br/>World`
    # becomes `Hello World`.
    spaced_message = message.split(%r{</p>|<br\s*/?>}i).join(" ")

    strip_tags(spaced_message)
      .squish
      .truncate(200, separator: " ", omission: "...")
  end

  def tags
    return [] if message.blank?

    fragment = Nokogiri::HTML.fragment(message)
    last_element = fragment.element_children.last
    return [] unless last_element&.name == "p"

    tags = last_element.content.split
    return [] unless tags.all? { |tag| tag.start_with?("#") }

    tags.map { normalize_tag(it) }.uniq
  end

  class InstallmentInvalid < StandardError
  end

  class PreviewEmailError < StandardError
  end

  private
    # message, no name or file is ok
    # if name or file, then need the other
    def message_must_be_provided
      errors.add(:base, "Please include a message as part of the update.") if scrubbed_message.blank?
    end

    def scrubbed_message
      # Default empty message from TipTap editor is "<p><br></p>", so we need check the scrubbed version of the message for validation
      scrubber = Rails::HTML::TargetScrubber.new
      scrubber.tags = %w[br p]
      sanitize(message, scrubber:)
    end

    def validate_call_to_action_url_and_text
      return unless call_to_action_url.present? || call_to_action_text.present?

      errors.add(:base, "Please enter text for your call to action.") if call_to_action_text.blank?
      errors.add(:base, "Please provide a valid URL for your call to action.") unless call_to_action_url.present? && call_to_action_url =~ /\A#{URI.regexp([%w[http https]])}\z/
    end

    def expected_delivery_time(sale)
      return sale.created_at unless installment_rule.present?

      original_delivery_time = sale.created_at + installment_rule.delayed_delivery_time
      subscription = sale.subscription
      return original_delivery_time unless workflow.present? && subscription.present? && subscription.resubscribed?

      send_delay = subscription.last_resubscribed_at - subscription.last_deactivated_at
      original_delivery_time + send_delay
    end

    def validate_sending_limit_for_sellers
      return unless send_emails
      return if deleted_at.present?
      return if abandoned_cart_type?

      if audience_members_count(SENDING_LIMIT + 1) > SENDING_LIMIT && user.sales_cents_total < MINIMUM_SALES_CENTS_VALUE
        errors.add(:base, "<a href='/help/article/269-balance-page' target='_blank' rel='noreferrer'>Sorry, you cannot send out more than #{SENDING_LIMIT} emails until you have $#{MINIMUM_SALES_CENTS_VALUE / 100} in total earnings.</a>".html_safe)
      end
    end

    def validate_channel
      return if shown_on_profile.present? || send_emails.present?
      errors.add(:base, "Please set at least one channel for your update.")
    end

    def published_at_cannot_be_in_the_future
      return if published_at.blank?
      return if published_at <= Time.current

      errors.add(:base, "Please enter a publish date in the past.")
    end

    # This gives the FriendlyId gem a candidate of slugs in
    # increasing order of specificity if there is duplication
    def slug_candidates
      [
        :name,
        [:name, :id]
      ]
    end

    def needs_purchase_to_access_content?
      ![AUDIENCE_TYPE, FOLLOWER_TYPE, AFFILIATE_TYPE].include?(installment_type)
    end

    def shown_on_profile_only_for_confirmed_users
      return if !shown_on_profile? || seller.confirmed?

      errors.add(:base, "Please confirm your email before creating a public post.")
    end

    def enforce_user_email_confirmation!
      return if user.confirmed?

      errors.add(:base, "You have to confirm your email address before you can do that.")
      raise InstallmentInvalid, "You have to confirm your email address before you can do that."
    end

    def send_email(recipient)
      cache_key = "post_sendgrid_api:post:#{id}-#{updated_at}-#{REVISION}"
      cache = Rails.cache.read(cache_key) || {}
      PostEmailApi.process(post: self, recipients: [recipient], cache:)
      Rails.cache.write(cache_key, cache)
    end

    def trigger_iffy_ingest
      return unless saved_change_to_name? || saved_change_to_message?
      Iffy::Post::IngestJob.perform_async(id)
    end

    def normalize_tag(raw)
      raw.delete_prefix("#")
        .gsub(/([^[:alnum:]\s])/, ' \1 ')
        .squish
        .titleize
    end
end
