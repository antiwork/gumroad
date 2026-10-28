# frozen_string_literal: true

class Follower::CreateService
  RETIRED_NEWSLETTER_MESSAGE = Follower::RETIRED_NEWSLETTER_MESSAGE

  delegate :followers, to: :followed_user

  def self.perform(**args)
    new(**args).perform
  end

  def initialize(followed_user:, follower_email:, follower_attributes: {}, logged_in_user: nil, waitlist_product: nil)
    @followed_user = followed_user
    @follower_email = follower_email
    @follower_attributes = follower_attributes
    @logged_in_user = logged_in_user
    @waitlist_product = waitlist_product
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
    # A retired newsletter takes no new or revived subscribers; callers show the error to the visitor.
    return retired_newsletter_follower if FeatureAnnouncementNewsletterCutover.retired_for?(followed_user.id)

    @follower = followers.find_by(email: follower_email)

    if @follower.present?
      reactivate_follower
    else
      create_new_follower
    end

    ApplicationRecord.connected_to(role: :writing) do
      record_waitlist_entry
      confirm_follower
    end

    @follower
  rescue ActiveRecord::RecordInvalid => e
    # The check above can predate a retirement that commits before this follow is revived or confirmed.
    raise unless e.record.is_a?(Follower) && e.record.errors.added?(:base, RETIRED_NEWSLETTER_MESSAGE)

    e.record
  end

  private
    attr_reader :followed_user, :follower_email, :follower_attributes, :logged_in_user, :waitlist_product

    # One row per (follower, product), so a visitor who already follows the seller can still join a
    # product's waitlist — a column on `followers` could not, since a follow is unique per seller.
    # A waitlist row that cannot be written must not fail the follow itself.
    def record_waitlist_entry
      return if waitlist_product.blank? || !@follower.persisted?

      # Look up first: the uniqueness validation makes a repeat signup raise RecordInvalid before any
      # INSERT, so create_or_find_by! alone would log a write failure for every expected repeat.
      @waitlist_entry = @follower.waitlist_entries.find_by(product: waitlist_product) ||
                        @follower.waitlist_entries.create_or_find_by!(product: waitlist_product)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      # A concurrent signup (a double submit) can commit the same entry between the lookup and the validation.
      concurrent_repeat = e.is_a?(ActiveRecord::RecordInvalid) && e.record.errors.of_kind?(:product_id, :taken)
      Rails.logger.error("Cannot record waitlist entry for follower #{@follower.id}. Exception: #{e.message}") unless concurrent_repeat
      @waitlist_entry = @follower.waitlist_entries.find_by(product: waitlist_product)
    end

    def retired_newsletter_follower
      Follower.new(user: followed_user, email: follower_email).tap { _1.errors.add(:base, RETIRED_NEWSLETTER_MESSAGE) }
    end

    def reactivate_follower
      @follower.mark_undeleted!

      # some users start following and then create an account so look for [email, followed_id] index and update the follower_user_id
      ApplicationRecord.transaction do
        # Re-read under lock: the newsletter migration may have bound this row since it was loaded.
        @follower.lock!
        @follower.update(follower_attributes.except(*kept_newsletter_link))
      end
    end

    # A newsletter moving to Feature announcements keeps each follow's account link, so the old newsletter's
    # opt-outs still reach the account that was carried over, whatever address a later form submits.
    def kept_newsletter_link
      keep = @follower.follower_user_id.present? && FeatureAnnouncementNewsletterCutover.tracks_opt_outs_for?(@follower.followed_id)
      keep ? [:follower_user_id] : []
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
      elsif confirmed_waitlist_follower?
        # A confirmed follower joining a waitlist has nothing to confirm, so no email goes out.
        true
      else
        request_confirmation
      end
    end

    def confirmed_waitlist_follower?
      waitlist_product.present? && @follower.confirmed?
    end

    # Ordered against retiring the newsletter like the follow itself, so no request is queued once it has retired.
    def request_confirmation
      ApplicationRecord.transaction do
        if FeatureAnnouncementNewsletterCutover.retired_for_follow?(@follower.followed_id)
          @follower.errors.add(:base, RETIRED_NEWSLETTER_MESSAGE)
          raise ActiveRecord::RecordInvalid, @follower
        end
        @follower.send_confirmation_email(waitlist_product_id: @waitlist_entry&.product_id)
      end
    end

    def active_session_with_verified_email?
      logged_in_user&.confirmed? && logged_in_user.email == follower_email
    end
end
