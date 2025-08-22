# frozen_string_literal: true

class Follower < ApplicationRecord
  include ExternalId
  include TimestampScopes
  include Follower::From
  include Deletable
  include ConfirmedFollowerEvent::FollowerCallbacks
  include Follower::AudienceMember

  has_paper_trail

  belongs_to :user, foreign_key: "followed_id", optional: true
  belongs_to :source_product, class_name: "Link", optional: true

  validates_presence_of :user
  validates_presence_of :email

  validates :email, email_format: { message: "invalid." }, if: :email_changed?

  validate :not_confirmed_and_deleted
  validate :follower_user_id_exists
  validate :double_follow_validation, on: :create

  scope :confirmed, -> { where.not(confirmed_at: nil) }
  scope :active, -> { alive.confirmed }
  scope :created_after,   ->(start_at) { where("followers.created_at > ?", start_at) if start_at.present? }
  scope :created_before,  ->(end_at) { where("followers.created_at < ?", end_at) if end_at.present? }
  scope :by_external_variant_ids_or_products, ->(external_variant_ids, product_ids) do
    return unless external_variant_ids.present? || product_ids.present?
    purchases = Purchase.by_external_variant_ids_or_products(external_variant_ids, product_ids)
    where(email: purchases.pluck(:email))
  end

  def mark_deleted!
    self.confirmed_at = nil
    super
  end

  def confirm!(schedule_workflow: true)
    return if confirmed?

    self.confirmed_at = Time.current
    self.deleted_at = nil
    save!
    schedule_workflow_jobs if schedule_workflow && user.workflows.alive.follower_or_audience_type.present?
  end

  def confirmed?
    confirmed_at.present?
  end

  def unconfirmed?
    !confirmed?
  end

  def follower_user_id_exists
    return if follower_user_id.nil?
    return if User.find_by(id: follower_user_id).present?

    errors.add(:follower_user_id, "Follower's User ID does not map to an existing user")
  end

  def double_follow_validation
    return unless Follower.where(followed_id:, email:).exists?

    errors.add(:base, "You are already following this creator.")
  end

  def follower_email
    User.find_by(id: follower_user_id).try(:email).presence || email
  end

  def schedule_workflow_jobs
    workflows = user.workflows.alive.follower_or_audience_type
    workflows.each do |workflow|
      next unless workflow.new_customer_trigger?
      workflow.installments.alive.each do |installment|
        installment_rule = installment.installment_rule
        next if installment_rule.nil?
        SendWorkflowInstallmentWorker.perform_in(installment_rule.delayed_delivery_time,
                                                 installment.id, installment_rule.version, nil, id, nil)
      end
    end
  end

  def self.unsubscribe(creator_id, email)
    follower = where(email:, followed_id: creator_id).last
    follower&.mark_deleted!
  end

  def send_confirmation_email
    # Suppress repeated sending of confirmation emails. Allow only 1 email per hour.
    Rails.cache.fetch("follower_confirmation_email_sent_#{id}", expires_in: 1.hour) do
      FollowerMailer.confirm_follower(followed_id, id).deliver_later(queue: "critical", wait: 3.seconds)
    end
  end

  def imported_from_csv?
    source == Follower::From::CSV_IMPORT
  end

  def as_json(options = {})
    pundit_user = options[:pundit_user]
    {
      id: external_id,
      email:,
      created_at:,
      source:,
      formatted_confirmed_on: confirmed_at.to_fs(:formatted_date_full_month),
      can_update: pundit_user ? Pundit.policy!(pundit_user, [:audience, self]).update? : false,
    }
  end

  private
    def not_confirmed_and_deleted
      if confirmed_at.present? && deleted_at.present?
        errors.add(:base, "Can't be both confirmed and deleted")
      end
    end
end
