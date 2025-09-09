# frozen_string_literal: true

class AffiliateRequest < ApplicationRecord
  include ExternalId

  ACTION_APPROVE = "approve"
  ACTION_IGNORE = "ignore"

  belongs_to :seller, class_name: "User", optional: true

  validates :seller, :name, :email, :promotion_text, presence: true
  validates :name, length: { maximum: User::MAX_LENGTH_NAME, too_long: "Your name is too long. Please try again with a shorter one." }
  validates :email, email_format: true
  validate :duplicate_request_validation, on: :create
  validate :requester_is_not_seller, on: :create

  after_commit :notify_requester_and_seller_of_submitted_request, on: :create

  scope :approved, -> { with_state(:approved) }
  scope :unattended, -> { with_state(:created) }
  scope :unattended_or_approved_but_awaiting_requester_to_sign_up, -> { joins("LEFT OUTER JOIN users ON users.email = affiliate_requests.email").where(users: { id: nil }).approved.or(unattended) }

  state_machine :state, initial: :created do
    after_transition created: :approved, do: ->(request) { request.state_transitioned_at = DateTime.current }
    after_transition created: :approved, do: :make_requester_an_affiliate!
    after_transition any => :ignored,  do: ->(request) { request.state_transitioned_at = DateTime.current }
    after_transition any => :ignored,  do: :notify_requester_of_ignored_request

    event :approve do
      transition created: :approved
    end

    event :ignore do
      transition any => :ignored, if: :allow_to_ignore?
    end
  end

  def can_perform_action?(action)
    return can_approve? if action == ACTION_APPROVE
    return can_ignore? if action == ACTION_IGNORE

    true
  end

  def as_json(options = {})
    pundit_user = options[:pundit_user]
    {
      id: external_id,
      name:,
      email:,
      promotion: promotion_text,
      date: created_at.in_time_zone(seller.timezone).iso8601,
      state:,
      can_update: pundit_user ? Pundit.policy!(pundit_user, self).update? : false
    }
  end

  def to_param
    external_id
  end

  def make_requester_an_affiliate!
    return unless approved?

    requester = User.find_by(email:)
    if requester.nil?
      AffiliateRequestMailer.notify_unregistered_requester_of_request_approval(id)
                            .deliver_later(queue: "default", wait: 3.seconds)
      return
    end

    affiliate = seller.direct_affiliates.alive.find_by(affiliate_user_id: requester.id)
    affiliate ||= seller.direct_affiliates.new

    enabled_self_service_affiliate_products = seller.self_service_affiliate_products.enabled
    if affiliate.persisted?
      enabled_self_service_affiliate_products = enabled_self_service_affiliate_products.where.not(product_id: affiliate.product_affiliates.pluck(:link_id))
    end
    added_product_ids = enabled_self_service_affiliate_products.each_with_object([]) do |self_service_affiliate_product, product_ids|
      next unless self_service_affiliate_product.product.alive?

      if affiliate.new_record?
        affiliate.prevent_sending_invitation_email = true
        affiliate.affiliate_user = requester
        affiliate.apply_to_all_products = false
        affiliate.affiliate_basis_points = Affiliate::BasisPointsValidations::MIN_AFFILIATE_BASIS_POINTS
        affiliate.send_posts = true
      end

      affiliate.product_affiliates.build(
        link_id: self_service_affiliate_product.product_id,
        destination_url: self_service_affiliate_product.destination_url,
        affiliate_basis_points: self_service_affiliate_product.affiliate_basis_points || affiliate.affiliate_basis_points
      )
      affiliate.save!
      affiliate.schedule_workflow_jobs
      product_ids << self_service_affiliate_product.product_id
    end

    if added_product_ids.any?
      AffiliateRequestMailer.notify_requester_of_request_approval(id)
                            .deliver_later(queue: "default", wait: 3.seconds)
    end
  end

  private
    def duplicate_request_validation
      # It's fine if a requester submits a new request in case their previous
      # request was ignored
      return unless AffiliateRequest.where(seller_id:, email:, state: %i[created approved])
                                   .exists?

      errors.add(:base, "You have already requested to become an affiliate of this creator.")
    end

    def requester_is_not_seller
      return unless seller_id
      return if email != seller.email

      errors.add(:base, "You cannot request to become an affiliate of yourself.")
    end

    def notify_requester_and_seller_of_submitted_request
      AffiliateRequestMailer.notify_requester_of_request_submission(id)
                            .deliver_later(queue: "default")
      AffiliateRequestMailer.notify_seller_of_new_request(id)
                            .deliver_later(queue: "default")
    end

    def notify_requester_of_ignored_request
      AffiliateRequestMailer.notify_requester_of_ignored_request(id)
                            .deliver_later(queue: "default")
    end

    def allow_to_ignore?
      return false if ignored?

      # Allow creator to ignore an already approved request if the requester
      # hasn't signed up yet
      return false if approved? && User.exists?(email:)

      true
    end
end
