# frozen_string_literal: true

# Usage:
#   CreatorAnalytics::Churn::DemoData.seed("creator@example.com")
#   CreatorAnalytics::Churn::DemoData.seed("creator@example.com", intensity: 0.5)
#   CreatorAnalytics::Churn::DemoData.purge("creator@example.com")
#   CreatorAnalytics::Churn::DemoData.check("creator@example.com")
#
# Options:
#   dataset: :realistic (default) or :classic
#     - :realistic: Generates 24 months of data with seasonal patterns and product-specific churn rates
#     - :classic: Fixed set of 18 scenarios spanning various time periods
#   intensity: Float multiplier for monthly subscription counts in :realistic dataset (default: 1.0)
#     - Scales the base monthly subscription counts (e.g., 0.5 = half subscriptions, 2.0 = double)
#     - Only affects :realistic dataset; :classic uses a fixed set of scenarios
#   logger: Proc for logging messages (default: ->(msg) { puts msg })
#
class CreatorAnalytics::Churn::DemoData
  DEMO_PRODUCT_DESCRIPTION = "Churn demo membership product"
  PRODUCTS = [
    { slug: "alpha", name: "Alpha Membership", price_cents: 1000, duration: :monthly },
    { slug: "beta", name: "Beta Membership", price_cents: 1500, duration: :biannually },
    { slug: "premium", name: "Premium Membership", price_cents: 19900, duration: :yearly },
    { slug: "enterprise", name: "Enterprise Membership", price_cents: 250000, duration: :every_two_years },
  ].freeze

  DATASET_CONFIGS = {
    classic: {},
    realistic: {
      months_of_history: 24,
      monthly_new_subscriptions: {
        "alpha" => 14,
        "beta" => 10,
        "premium" => 6,
        "enterprise" => 4,
      },
      churn_profiles: {
        "alpha" => {
          within_first_month: 0.15,
          within_three_months: 0.25,
          within_year: 0.30,
        },
        "beta" => {
          within_first_month: 0.22,
          within_three_months: 0.30,
          within_year: 0.25,
        },
        "premium" => {
          within_first_month: 0.10,
          within_three_months: 0.18,
          within_year: 0.22,
        },
        "enterprise" => {
          within_first_month: 0.08,
          within_three_months: 0.15,
          within_year: 0.18,
        },
      },
      seasonal_multipliers: {
        1 => 1.1,
        2 => 1.05,
        3 => 1.0,
        4 => 1.0,
        5 => 1.05,
        6 => 1.1,
        7 => 1.15,
        8 => 1.15,
        9 => 1.0,
        10 => 0.95,
        11 => 4.5,
        12 => 1.05,
      },
      random_seed: 13_337,
    },
  }.freeze

  def self.seed(seller_email, dataset: :realistic, intensity: 1.0, logger: ->(msg) { puts msg })
    ensure_not_production!
    new(seller_email:, dataset:, intensity:, logger:).seed
  end

  def self.purge(seller_email, dataset: :realistic, intensity: 1.0, logger: ->(msg) { puts msg })
    ensure_not_production!
    new(seller_email:, dataset:, intensity:, logger:).purge
  end

  def self.check(seller_email, logger: ->(msg) { puts msg })
    ensure_not_production!
    new(seller_email:, dataset: :realistic, intensity: 1.0, logger:).check
  end

  def initialize(seller_email:, dataset:, intensity:, logger:)
    @seller_email = seller_email.strip
    @dataset = (dataset || :realistic).to_sym
    @intensity = intensity.to_f
    @logger = logger
    @scenario_definitions = nil
  end

  def seed
    ActiveRecord::Base.transaction do
      self.seller = find_or_create_seller!
      logger.call("Seeding churn demo data for #{seller.email}")
      clean_up_existing_data
      create_or_update_products
      create_scenarios!
    end
    logger.call("Churn demo data seeded for #{seller.email}")
  end

  def purge
    ActiveRecord::Base.transaction do
      self.seller = User.find_by(email: seller_email)
      unless seller
        logger.call("Seller #{seller_email} not found. Nothing to purge.")
        return
      end

      logger.call("Purging churn demo data for #{seller.email}")
      clean_up_existing_data
    end
    logger.call("Churn demo data purged for #{seller_email}")
  end

  def check
    self.seller = User.find_by(email: seller_email)
    unless seller
      logger.call("Seller #{seller_email} not found. Nothing to check.")
      return
    end

    products = Link.where(user: seller, description: DEMO_PRODUCT_DESCRIPTION).order(:id)
    if products.empty?
      logger.call("No demo products found for #{seller.email}")
      return
    end

    logger.call("Found #{products.count} demo products for #{seller.email}")
    products.each do |product|
      subs = Subscription.where(seller:, link: product)
      total = subs.count
      churned = subs.where.not(deactivated_at: nil).count
      active = total - churned
      last_started = subs.maximum(:created_at)
      last_churned = subs.maximum(:deactivated_at)

      logger.call("#{product.name}: #{total} subscriptions (active: #{active}, churned: #{churned}), " \
        "latest signup: #{format_time(last_started)}, latest churn: #{format_time(last_churned)}")
    end
    nil
  end

  private
    def self.ensure_not_production!
      return unless Rails.env.production?
      raise "CreatorAnalytics::Churn::DemoData cannot run in production"
    end

    attr_reader :seller_email, :logger, :dataset, :intensity
    attr_accessor :seller

    def find_or_create_seller!
      user = User.find_or_initialize_by(email: seller_email)
      user.password = seller_email
      user.name ||= "Churn Demo Seller"
      user.username ||= seller_email.parameterize.presence || "churn-demo-seller"
      user.timezone ||= "UTC"
      user.user_risk_state ||= "not_reviewed"
      user.confirmed_at ||= Time.current
      user.save!(validate: false)
      user
    end

    def create_or_update_products
      PRODUCTS.each do |definition|
        product = Link.where(user: seller, description: DEMO_PRODUCT_DESCRIPTION, name: definition[:name]).first_or_initialize
        product.user = seller
        product.name = definition[:name]
        product.description = DEMO_PRODUCT_DESCRIPTION
        product.filetype ||= "link"
        product.filegroup ||= "url"
        product.price_cents = definition[:price_cents]
        product.price_currency_type = "usd"
        product.is_recurring_billing = true
        product.subscription_duration = (definition[:duration] || :monthly)
        product.is_tiered_membership = false
        product.native_type = Link::NATIVE_TYPE_MEMBERSHIP if product.respond_to?(:native_type=)
        product.save!
        find_or_create_price_for_duration!(product:, definition:)
      end
    end

    def create_scenarios!
      scenarios.each_with_index do |scenario, index|
        buyer = find_or_create_buyer!(scenario[:suffix], index)
        product = find_product_by_slug(scenario[:product_slug])
        started_at = scenario[:started_at] || scenario[:start_days_ago].days.ago.change(hour: 12)
        churned_at = scenario[:churned_at]
        churned_at ||= scenario[:churn_days_ago]&.days&.ago&.change(hour: 12)

        subscription = find_or_create_subscription!(buyer:, product:, started_at:, churned_at:)
        find_or_create_purchase!(subscription:, product:, buyer:, started_at:, churned_at:)
      end
    end

    def find_or_create_buyer!(suffix, index)
      email = buyer_email_for(suffix)
      user = User.find_or_initialize_by(email:)
      user.password = email
      user.name ||= "Churn Demo Buyer #{index + 1}"
      user.username ||= email.parameterize
      user.timezone ||= seller.timezone
      user.user_risk_state ||= "not_reviewed"
      user.confirmed_at ||= Time.current
      user.save!(validate: false)
      user
    end

    def find_or_create_subscription!(buyer:, product:, started_at:, churned_at:)
      subscription = Subscription.find_or_initialize_by(seller:, link: product, user: buyer)
      definition = PRODUCTS.find { |entry| entry[:name] == product.name }
      price = find_or_create_price_for_duration!(product:, definition:)
      if subscription.new_record? && subscription.payment_options.blank? && price.present?
        # Build a placeholder payment option so Subscription callbacks don't fail validation before we persist one.
        subscription.payment_options.build(price:)
      end
      subscription.created_at ||= started_at
      subscription.cancelled_at = churned_at if churned_at
      subscription.deactivated_at = churned_at if churned_at
      subscription.save!(validate: false)
      subscription.update_columns(created_at: started_at)
      subscription.update_columns(cancelled_at: churned_at, deactivated_at: churned_at) if churned_at
      find_or_create_payment_option!(subscription:, product:, price:)
      subscription
    end

    def find_or_create_purchase!(subscription:, product:, buyer:, started_at:, churned_at:)
      purchase = Purchase.find_or_initialize_by(subscription:, link: product, seller:, purchaser: buyer)
      price_cents = product.price_cents || 0
      purchase.email = buyer.email
      purchase.price_cents = price_cents
      purchase.displayed_price_cents = price_cents
      purchase.total_transaction_cents = price_cents
      purchase.tax_cents ||= 0
      purchase.gumroad_tax_cents ||= 0
      purchase.displayed_price_currency_type = product.price_currency_type
      purchase.purchase_state = "successful"
      purchase.created_at ||= started_at
      purchase.succeeded_at = started_at
      purchase.ip_address ||= "127.0.0.1"
      purchase.ip_country ||= "United States"
      purchase.ip_state ||= "CA"
      purchase.is_original_subscription_purchase = true if purchase.respond_to?(:is_original_subscription_purchase=)
      purchase.save!(validate: false)
      purchase.update_columns(created_at: started_at, succeeded_at: started_at)
      purchase
    end

    def clean_up_existing_data
      remove_buyers
      remove_products
    end

    def remove_buyers
      pattern = "#{base_identifier}+%@example.com"
      User.where("email LIKE ?", pattern).find_each do |buyer|
        Purchase.where(purchaser: buyer).find_each(&:destroy!)
        Subscription.where(user: buyer).find_each(&:destroy!)
        buyer.destroy!
      end
    end

    def remove_products
      Link.where(user: seller, description: DEMO_PRODUCT_DESCRIPTION).find_each do |product|
        destroy_associations_for(product)
      end
    end

    def destroy_associations_for(product)
      [
        CartProduct.where(product:),
        WishlistProduct.where(product:),
        BundleProduct.where(product:),
        ProductAffiliate.where(product:),
        ProductReview.where(link: product),
        ProductRefundPolicy.where(product:),
        LegacyPermalink.where(product:),
        RecommendedPurchaseInfo.where(recommended_link: product),
        RecommendedPurchaseInfo.where(recommended_by_link: product),
        ProductCachedValue.where(product:),
        Upsell.where(product:),
        ProductIntegration.where(product:),
        ThirdPartyAnalytic.where(link: product),
        UrlRedirect.where(link: product),
        AssetPreview.where(link: product),
        CallAvailability.where(call: product),
        PublicFile.where(resource: product),
        Community.where(resource: product),
        Price.where(link: product),
        Purchase.where(link: product, seller: seller),
        Subscription.where(link: product, seller: seller),
      ].each do |relation|
        relation.find_each(&:destroy!)
      end

      VariantCategory.where(link: product).find_each do |category|
        Variant.where(variant_category: category).find_each(&:destroy!)
        category.destroy!
      end

      product.destroy!
    end

    def find_product_by_slug(slug)
      definition = PRODUCTS.find { |config| config[:slug] == slug }
      raise ActiveRecord::RecordNotFound, "Missing demo product #{slug}" unless definition

      product = Link.find_by(user: seller, description: DEMO_PRODUCT_DESCRIPTION, name: definition[:name])
      raise ActiveRecord::RecordNotFound, "Missing demo product #{slug}" unless product
      product
    end

    def buyer_email_for(suffix)
      "#{base_identifier}+#{suffix}@example.com"
    end

    def base_identifier
      @base_identifier ||= (seller&.username.presence || seller_email).parameterize
    end

    def find_or_create_price_for_duration!(product:, definition:)
      recurrence = price_recurrence_for(product:, definition:)
      product.prices.where(recurrence:, currency: product.price_currency_type).first ||
        product.prices.create!(
          price_cents: definition[:price_cents],
          currency: product.price_currency_type,
          recurrence:
        )
    end

    def find_or_create_payment_option!(subscription:, product:, price: nil)
      definition = PRODUCTS.find { |entry| entry[:name] == product.name }
      price ||= find_or_create_price_for_duration!(product:, definition:)
      subscription.payment_options.find_or_create_by!(price:)
    end

    def price_recurrence_for(product:, definition:)
      product.subscription_duration.presence ||
        definition[:duration]&.to_s ||
        BasePrice::Recurrence::MONTHLY
    end

    def scenarios
      @scenario_definitions ||= case dataset
                                when :classic
                                  classic_scenarios
                                when :realistic
                                  generate_realistic_scenarios
                                else
                                  raise ArgumentError, "Unknown dataset #{dataset}"
      end
    end

    def classic_scenarios
      [
        { suffix: "buyer1", product_slug: "alpha", start_days_ago: 90, churn_days_ago: 30 },
        { suffix: "buyer2", product_slug: "alpha", start_days_ago: 75, churn_days_ago: nil },
        { suffix: "buyer3", product_slug: "beta",  start_days_ago: 60, churn_days_ago: 15 },
        { suffix: "buyer4", product_slug: "beta",  start_days_ago: 45, churn_days_ago: nil },
        { suffix: "buyer5", product_slug: "alpha", start_days_ago: 30, churn_days_ago: nil },
        { suffix: "buyer6", product_slug: "beta",  start_days_ago: 20, churn_days_ago: 5 },
        { suffix: "buyer7", product_slug: "alpha", start_days_ago: 400, churn_days_ago: 360 },
        { suffix: "buyer8", product_slug: "alpha", start_days_ago: 360, churn_days_ago: nil },
        { suffix: "buyer9", product_slug: "beta",  start_days_ago: 330, churn_days_ago: 310 },
        { suffix: "buyer10", product_slug: "beta", start_days_ago: 300, churn_days_ago: nil },
        { suffix: "buyer11", product_slug: "alpha", start_days_ago: 700, churn_days_ago: 660 },
        { suffix: "buyer12", product_slug: "alpha", start_days_ago: 650, churn_days_ago: nil },
        { suffix: "buyer13", product_slug: "beta",  start_days_ago: 620, churn_days_ago: 610 },
        { suffix: "buyer14", product_slug: "beta",  start_days_ago: 590, churn_days_ago: nil },
        { suffix: "buyer15", product_slug: "alpha", start_days_ago: 1000, churn_days_ago: 900 },
        { suffix: "buyer16", product_slug: "beta",  start_days_ago: 950, churn_days_ago: 920 },
        { suffix: "buyer17", product_slug: "alpha", start_days_ago: 900, churn_days_ago: nil },
        { suffix: "buyer18", product_slug: "beta",  start_days_ago: 850, churn_days_ago: nil },
      ]
    end

    def generate_realistic_scenarios
      config = DATASET_CONFIGS.fetch(:realistic).deep_dup
      random = Random.new(config[:random_seed])
      total_months = config[:months_of_history]
      # Start one full month earlier so analytics windows beginning at the first
      # seeded month still have a prior cohort for initial_active_counts.
      base_start = current_time.beginning_of_month - total_months.months
      definitions = []

      total_months.times do |month_index|
        month_start_time = base_start + month_index.months
        month_end_time = [month_start_time.end_of_month.end_of_day, current_time].min
        next if month_start_time > current_time

        PRODUCTS.each do |product|
          product_slug = product[:slug]
          monthly_base = config[:monthly_new_subscriptions][product_slug]
          monthly_base ||= config[:monthly_new_subscriptions].values.max
          seasonal_multiplier = config[:seasonal_multipliers][month_start_time.month] || 1.0
          signup_count = [(monthly_base * seasonal_multiplier * intensity).round, 1].max

          signup_count.times do |signup_index|
            suffix = "buyer-#{product_slug}-#{month_start_time.strftime("%Y%m")}-#{signup_index + 1}"
            started_at = random_time_within(month_start_time, month_end_time, random:)
            churned_at = determine_churn_time(product_slug:, started_at:, random:, config:)

            definitions << {
              suffix:,
              product_slug:,
              started_at:,
              churned_at:,
            }
          end
        end
      end

      definitions.sort_by { |entry| entry[:started_at] }
    end

    def random_time_within(start_time, end_time, random:)
      span_seconds = [end_time - start_time, 1].max
      offset_seconds = random.rand(span_seconds)
      (start_time + offset_seconds).change(min: 0, sec: 0)
    end

    def determine_churn_time(product_slug:, started_at:, random:, config:)
      profile = config[:churn_profiles][product_slug]
      return nil unless profile

      roll = random.rand
      churn_at = if roll < profile[:within_first_month]
        started_at + random.rand(10..27).days
      elsif roll < profile[:within_first_month] + profile[:within_three_months]
        started_at + random.rand(35..95).days
      elsif roll < profile[:within_first_month] + profile[:within_three_months] + profile[:within_year]
        started_at + random.rand(120..300).days
      else
        nil
      end

      return nil unless churn_at
      churn_at > current_time ? nil : churn_at.change(hour: 12, min: 0)
    end

    def current_time
      Time.current
    end

    def format_time(value)
      value ? value.strftime("%Y-%m-%d") : "n/a"
    end
end
