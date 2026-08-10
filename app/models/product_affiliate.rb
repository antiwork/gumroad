# frozen_string_literal: true

class ProductAffiliate < ApplicationRecord
  class WorkflowJobNotEnqueuedError < StandardError; end

  WORKFLOW_SCHEDULE_DISPATCH_LEASE = 15.minutes

  include FlagShihTzu

  self.table_name = "affiliates_links"

  belongs_to :affiliate
  belongs_to :product, class_name: "Link", foreign_key: :link_id

  validates :affiliate, uniqueness: { scope: :product }
  validates :affiliate_basis_points, presence: true, if: -> { affiliate.is_a?(Collaborator) && !affiliate.apply_to_all_products? }
  validates :affiliate_basis_points, numericality: { greater_than_or_equal_to: Collaborator::MIN_PERCENT_COMMISSION * 100,
                                                     less_than_or_equal_to: Collaborator::MAX_PERCENT_COMMISSION * 100,
                                                     allow_nil: true }, if: -> { affiliate.is_a?(Collaborator) }
  validate :product_is_eligible_for_collabs, if: -> { affiliate.is_a?(Collaborator) }
  validate :product_is_not_a_collab, if: -> { affiliate.is_a?(DirectAffiliate) }
  after_create :enable_product_collaborator_flag_and_disable_affiliates, if: -> { affiliate.is_a?(Collaborator) }
  after_destroy :disable_product_collaborator_flag, if: -> { affiliate.is_a?(Collaborator) }
  after_create :update_audience_member_with_added_product
  after_destroy :update_audience_member_with_removed_product
  before_create :assign_workflow_schedule_token, if: -> { affiliate.is_a?(DirectAffiliate) }
  after_create :enqueue_workflow_jobs, if: -> { affiliate.is_a?(DirectAffiliate) }

  has_flags 1 => :dont_show_as_co_creator

  def affiliate_percentage
    return unless affiliate_basis_points.present?
    affiliate_basis_points / 100
  end

  def enqueue_workflow_jobs
    return unless self.class.where(workflow_schedule_token:).minimum(:id) == id

    token = workflow_schedule_token
    AfterCommitEverywhere.after_commit do
      self.class.enqueue_workflow_schedule(token)
    end
  end

  def self.enqueue_workflow_schedule(workflow_schedule_token)
    claimed_token = claim_workflow_schedule(workflow_schedule_token)
    return if claimed_token.nil?

    job_id = ScheduleAffiliateWorkflowJobsJob.perform_async(claimed_token)
    raise WorkflowJobNotEnqueuedError, "Sidekiq did not enqueue the affiliate workflow" if job_id.blank?

    job_id
  rescue => e
    Rails.logger.error("[#{name}] could not enqueue workflow_schedule_token=#{workflow_schedule_token}: #{e.class}: #{e.message}")
    begin
      where(workflow_schedule_token: claimed_token).update_all(workflow_schedule_token:) if claimed_token
    rescue => release_error
      Rails.logger.error("[#{name}] could not release workflow_schedule_token=#{claimed_token}: #{release_error.class}: #{release_error.message}")
    end
    nil
  end

  def self.workflow_schedule_dispatchable?(workflow_schedule_token)
    claimed_at = Integer(workflow_schedule_token.to_s.split(":", 2).first, exception: false)
    claimed_at.nil? || Time.zone.at(claimed_at) <= WORKFLOW_SCHEDULE_DISPATCH_LEASE.ago
  end

  def self.workflow_schedule_token
    transaction = connection.current_transaction
    raise WorkflowJobNotEnqueuedError, "A database transaction is required" unless transaction.open?

    # Rails 7.1 has no public transaction ID. One root token keeps bulk assignment scheduling bounded.
    transaction = transaction.instance_variable_get(:@parent) while transaction.instance_variable_get(:@parent)
    transaction.instance_variable_get(:@affiliate_workflow_schedule_token) ||
      transaction.instance_variable_set(:@affiliate_workflow_schedule_token, SecureRandom.uuid)
  end

  private
    def self.claim_workflow_schedule(workflow_schedule_token)
      transaction do
        assignments = where(workflow_schedule_token:).lock.to_a
        next if assignments.empty?

        claimed_token = "#{Time.current.to_i}:#{SecureRandom.uuid}"
        where(id: assignments.map(&:id), workflow_schedule_token:).update_all(workflow_schedule_token: claimed_token)
        claimed_token
      end
    end
    private_class_method :claim_workflow_schedule

    def assign_workflow_schedule_token
      self.workflow_schedule_token = self.class.workflow_schedule_token
    end

    def enable_product_collaborator_flag_and_disable_affiliates
      product.update!(is_collab: true)
      product.self_service_affiliate_products.map { _1.update!(enabled: false) }
      product.product_affiliates.where.not(id:).joins(:affiliate).merge(Affiliate.direct_affiliates).map { _1.destroy! }
    end

    def disable_product_collaborator_flag
      product.update!(is_collab: false)
    end

    def update_audience_member_with_added_product
      affiliate.update_audience_member_with_added_product(link_id)
    end

    def update_audience_member_with_removed_product
      affiliate.update_audience_member_with_removed_product(link_id)
    end

    def product_is_eligible_for_collabs
      return unless product.has_another_collaborator?(collaborator: affiliate)
      errors.add :base, "This product is not eligible for the Gumroad Affiliate Program."
    end

    def product_is_not_a_collab
      return unless product.is_collab?
      errors.add :base, "Collab products cannot have affiliates"
    end
end
