# frozen_string_literal: true

class Follower::CreateService
  delegate :followers, to: :followed_user

  def self.perform(**args)
    new(**args).perform
  end

  def initialize(followed_user:, follower_email:, follower_attributes: {}, logged_in_user: nil)
    @followed_user = followed_user
    @follower_email = follower_email
    @follower_attributes = follower_attributes
    @logged_in_user = logged_in_user
  end

  def perform
    return if followed_user.blank? || follower_email.blank?
    # Refuse to create (or revive) a follow for a suspended or deleted seller.
    #
    # Creating a Follower row sends a "Please confirm your follow request" email
    # to whatever address was submitted, from Gumroad's own sending domain. That
    # makes this endpoint an email relay pointed at arbitrary third parties, and
    # suspending the seller does NOT close it: /follow is a plain POST that never
    # loads the storefront, so a banned account whose pages 404 keeps accepting
    # submissions and keeps sending mail. A ring of accounts used exactly that to
    # deliver loan-phishing lures to hundreds of thousands of harvested addresses,
    # and kept going after every account in it was banned.
    #
    # `account_active?` is `alive? && !suspended?` — once we have decided an
    # account may no longer transact, it should not be able to make us send mail
    # on its behalf either.
    return unless followed_user.account_active?

    @follower = followers.find_by(email: follower_email)

    if @follower.present?
      reactivate_follower
    else
      create_new_follower
    end

    ApplicationRecord.connected_to(role: :writing) { confirm_follower }

    @follower
  end

  private
    attr_reader :followed_user, :follower_email, :follower_attributes, :logged_in_user

    def reactivate_follower
      @follower.mark_undeleted!

      # some users start following and then create an account so look for [email, followed_id] index and update the follower_user_id
      @follower.update(follower_attributes)
    end

    def create_new_follower
      new_follower_attributes = follower_attributes.merge(email: follower_email)
      @follower = followers.build(new_follower_attributes)
      @follower.created_at = follower_attributes[:created_at] if follower_attributes.key?(:created_at)

      begin
        @follower.save!
      rescue ActiveRecord::RecordNotUnique
        ApplicationRecord.connected_to(role: :writing) do
          @follower = followers.find_by(email: follower_email)
          reactivate_follower
        end
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.error("Cannot add follower to the database. Exception: #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
      end
    end

    def confirm_follower
      return false unless @follower.persisted? && @follower.valid?

      if @follower.imported_from_csv? || active_session_with_verified_email?
        @follower.confirm!
      else
        @follower.send_confirmation_email
      end
    end

    def active_session_with_verified_email?
      logged_in_user&.confirmed? && logged_in_user.email == follower_email
    end
end
