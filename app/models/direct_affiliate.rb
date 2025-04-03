# frozen_string_literal: true

class DirectAffiliate < Affiliate
  include Affiliate::BasisPointsValidations
  include Affiliate::DestinationUrlValidations
  include Affiliate::Sorting

  AFFILIATE_COOKIE_LIFETIME_DAYS = 30

  attr_accessor :prevent_sending_invitation_email, :prevent_sending_invitation_email_to_seller

  belongs_to :seller, class_name: "User"
  has_and_belongs_to_many :products, class_name: "Link", join_table: "affiliates_links", foreign_key: "affiliate_id", after_add: :update_audience_member_with_added_product, after_remove: :update_audience_member_with_removed_product

  validates :affiliate_basis_points, presence: true
  validate :destination_url_or_username_required
  validate :affiliate_basis_points_must_fall_in_an_acceptable_range
  validate :eligible_for_stripe_payments

  after_commit :send_invitation_email, on: :create

  validates_uniqueness_of :affiliate_user_id, scope: :seller_id, conditions: -> { alive }, if: :alive?

  def self.cookie_lifetime
    AFFILIATE_COOKIE_LIFETIME_DAYS.days
  end

  def final_destination_url(product: nil)
    product = products.last if !apply_to_all_products && product_affiliates.one?
    product_affiliate = product_affiliates.find_by(link_id: product.id) if product.present?
    product_destination_url = product_affiliate&.destination_url

    if product_destination_url.present?
      product_destination_url
    elsif apply_to_all_products && destination_url.present?
      destination_url
    elsif product_affiliate.present?
      product.long_url
    else
      seller.subdomain_with_protocol || products.last&.long_url
    end
  end

  def as_json(options = {})
    affiliated_products = enabled_products

    affiliate_info.merge(
      products: affiliated_products,
      apply_to_all_products: affiliated_products.all? { _1[:fee_percent] == affiliate_percentage } && affiliated_products.length == seller.links.alive.count,
      product_referral_url: product_affiliates.one? ? referral_url_for_product(products.first) : referral_url)
  end

  def product_sales_info
    affiliate_credits
      .where(link_id: products.map(&:id))
      .joins(:purchase)
      .merge(Purchase.counts_towards_volume)
      .select("sum(purchases.price_cents) as volume_cents, count(purchases.id) as sales_count, affiliate_credits.link_id")
      .group("affiliate_credits.link_id")
      .each_with_object({}) { |credit, mapping| mapping[ObfuscateIds.encrypt_numeric(credit.link_id)] = { volume_cents: credit.volume_cents, sales_count: credit.sales_count } }
  end

  def products_data
    product_affiliates = self.product_affiliates.to_a
    credits = affiliate_credits.where(link_id: product_affiliates.map(&:link_id))
                               .joins(:purchase)
                               .merge(Purchase.counts_towards_volume)
                               .select("sum(purchases.price_cents) as volume_cents, count(purchases.id) as sales_count, affiliate_credits.link_id")
                               .group("affiliate_credits.link_id")

    seller.links.alive.not_is_collab.map do |product|
      credit = credits.find { _1.link_id == product.id }
      product_affiliate = product_affiliates.find { _1.link_id == product.id }
      next if product.archived? && product_affiliate.blank?

      {
        id: product.external_id_numeric,
        enabled: product_affiliate.present?,
        name: product.name,
        volume_cents: credit&.volume_cents || 0,
        sales_count: credit&.sales_count || 0,
        fee_percent: product_affiliate&.affiliate_percentage || affiliate_percentage,
        referral_url: referral_url_for_product(product),
        destination_url: product_affiliate&.destination_url,
      }
    end.compact.sort_by { |product| [product[:enabled] ? 0 : 1, -product[:volume_cents]] }
  end

  def total_amount_cents
    affiliate_credits.where(link_id: products.map(&:id))
      .joins(:purchase)
      .merge(Purchase.counts_towards_volume)
      .sum(:price_cents)
  end

  def schedule_workflow_jobs
    workflows = seller.workflows.alive.affiliate_or_audience_type
    workflows.each do |workflow|
      next unless workflow.new_customer_trigger?
      workflow.installments.alive.each do |installment|
        installment_rule = installment.installment_rule
        next if installment_rule.nil?
        SendWorkflowInstallmentWorker.perform_in(installment_rule.delayed_delivery_time,
                                                 installment.id, installment_rule.version, nil, nil, affiliate_user.id)
      end
    end
  end

  def update_posts_subscription(send_posts:)
    seller.direct_affiliates.where(affiliate_user_id:).update(send_posts:)
  end

  def eligible_for_purchase_credit?(product:, **opts)
    return false unless eligible_for_credit?
    return false if opts[:was_recommended]
    return false if seller.has_brazilian_stripe_connect_account?
    products.include?(product)
  end

  def basis_points(product_id: nil)
    return affiliate_basis_points if apply_to_all_products || product_id.blank?

    product_affiliates.find_by(link_id: product_id)&.affiliate_basis_points || affiliate_basis_points
  end

  private
    def destination_url_or_username_required
      return if destination_url.present? || seller&.username.present?

      errors.add(:base, "Please either provide a destination URL or add a username to your Gumroad account.") if products.length > 1 # .length so that we get the right number when self isn't saved.
    end

    def send_invitation_email
      return if prevent_sending_invitation_email

      AffiliateMailer.direct_affiliate_invitation(id, prevent_sending_invitation_email_to_seller).deliver_later(wait: 3.seconds)
    end

    def eligible_for_stripe_payments
      super
      return unless seller.present? && seller.has_brazilian_stripe_connect_account?
      errors.add(:base, "You cannot add an affiliate because you are using a Brazilian Stripe account.")
    end
end
