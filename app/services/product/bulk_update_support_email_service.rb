# frozen_string_literal: true

class Product::BulkUpdateSupportEmailService
  # @param entries [Array<Hash>]
  # @option entries [String] :email
  # @option entries [Array<String>] :product_ids
  def initialize(user, entries)
    @user = user
    @entries = reject_blank_entries(entries)
  end

  def perform
    return unless user.product_level_support_emails_enabled?

    validate_entries!

    ActiveRecord::Base.transaction do
      clear_existing_support_emails!
      set_new_support_emails!
    end
  end

  private
    attr_reader :user, :entries

    def reject_blank_entries(entries)
      Array.wrap(entries)
        .reject { |entry| entry[:email]&.blank? || entry[:product_ids]&.blank? }
    end

    def affected_product_ids
      @_affected_product_ids ||= entries.flat_map { |entry| entry[:product_ids] }
    end

    def validate_entries!
      entries.each { |entry| validate_email!(entry[:email]) }
    end

    def validate_email!(email)
      ReplicateSupportEmailValidationsOnLink.new(support_email: email).validate!
    end

    def clear_existing_support_emails!
      @user.products
        .where.not(id: affected_product_ids.map { Link.from_external_id(it) })
        .where.not(support_email: nil)
        .update_all(support_email: nil)
    end

    def set_new_support_emails!
      entries.each do |entry|
        user.products
          .by_external_ids(entry[:product_ids])
          .update_all(support_email: entry[:email])
      end
    end

    class ReplicateSupportEmailValidationsOnLink
      include ActiveModel::API

      attr_accessor :support_email

      validates :support_email, email_format: true, not_reserved_email_domain: true, allow_nil: true
    end
end
