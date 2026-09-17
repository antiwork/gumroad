# frozen_string_literal: true

# The launch email for one product: a single draft Installment addressed to the
# seller's past customers and followers, excluding buyers of the new product. The
# seller edits, schedules and sends it from the Emails tab; nothing here sends.
class Marketing::LaunchEmail
  # Both markers ride in the draft's json_data, which holds many independent keys and is
  # merged per key on save, so they cost no extra column.
  WRITTEN_COPY_DIGEST_KEY = "marketing_launch_written_copy_digest"
  # The digest of the copy we last wrote is what tells "we wrote this" from "the seller rewrote
  # it"; the product id marks the row as this product's launch draft, which the product filter
  # alone cannot, since it also matches an audience email the seller wrote themselves.
  LAUNCH_PRODUCT_KEY = "marketing_launch_product_id"

  def initialize(product:, seller:, utm_link:)
    @product = product
    @seller = seller
    @utm_link = utm_link
  end

  # The draft for this product, created on first call and reused after that. Returns
  # nil for a seller who cannot send emails yet — the caller surfaces the gate reason
  # instead of a draft that could not be sent.
  def installment
    return unless seller.eligible_to_send_emails?

    # Serialized on the product: two overlapping card loads must not both miss the draft and
    # mint one each.
    product.with_lock do
      # Re-read under the lock: the counts may have been asked for before it was taken.
      @drafts = nil
      @existing = nil
      next nil if declined?

      @existing = existing ? refresh(existing) : create_draft
    end
  rescue ActiveRecord::RecordInvalid => e
    # The gate is not the only refusal a draft can hit: `send_emails` also caps a seller
    # below the sales threshold at 100 recipients, which reaches team members whose own
    # sales are low. Report no draft instead of failing the card with a 500.
    Rails.logger.info("Marketing::LaunchEmail skipped product #{product.id}: #{e.message}")
    nil
  end

  # Deleting the draft in the Emails tab is the only way to say no to the email channel — the
  # row has no dismiss control — so a deleted draft is never replaced.
  def declined? = drafts.any?(&:deleted?) && existing.nil?

  # What the draft would reach today, per segment. `total` is the draft's own count, so
  # the card and the Emails tab cannot disagree.
  def recipient_counts
    { customers: count_for("customer"), followers: count_for("follower"), total: total_count }
  end

  def self.copy_for(product) = Marketing::Recommendations.copy_for(product)

  def self.message_for(product:, utm_link:)
    body = ERB::Util.html_escape(copy_for(product))
    link = utm_link&.short_url
    return "<p>#{body}</p>" if link.blank?

    escaped_link = ERB::Util.html_escape(link)
    %(<p>#{body}</p><p><a href="#{escaped_link}" target="_blank" rel="noopener noreferrer nofollow">#{escaped_link}</a></p>)
  end

  private
    attr_reader :product, :seller, :utm_link

    # Ours is matched by our own marker, never by name or message: the seller may edit both, and a
    # renamed or rewritten draft must still be recognised as this product's launch email instead
    # of a second draft being minted beside it. The marker is also the SQL prefilter, so a look
    # at the card cannot pull a seller's whole email history — message bodies included — into
    # memory on a GET the frontend fires on mount.
    def drafts
      @drafts ||= seller.installments
                        .where(installment_type: Installment::AUDIENCE_TYPE)
                        .where("json_data LIKE ?", "%#{LAUNCH_PRODUCT_KEY}%")
                        .select { launch_draft?(_1) }
                        .to_a
    end

    def existing = @existing ||= drafts.select(&:alive?).max_by(&:id)

    def launch_draft?(installment)
      installment.json_data[LAUNCH_PRODUCT_KEY].to_i == product.id &&
        installment.not_bought_products == [product.unique_permalink]
    end

    # A draft the seller has already scheduled or sent is theirs; so is one they rewrote.
    # Only a draft still holding our own copy is refreshed, so a second publish updates the
    # launch copy without discarding their work.
    def refresh(installment)
      return installment if installment.published_at.present? || installment.ready_to_publish?
      return installment unless untouched?(installment)

      # The subject is left as it stands: a seller who renamed the draft renamed it on
      # purpose, and the body is the part that has to follow the product.
      installment.message = message
      installment.json_data[WRITTEN_COPY_DIGEST_KEY] = written_copy_digest
      installment.save!
      installment
    end

    # Whether the draft still holds exactly the copy we last wrote. Comparing against the
    # product instead would call every untouched draft edited the moment its description
    # changes, which is the case a refresh exists for.
    def untouched?(installment) =
      installment.json_data[WRITTEN_COPY_DIGEST_KEY] == Digest::SHA256.hexdigest(installment.message.to_s)

    def create_draft
      installment = seller.installments.new(
        name:,
        message:,
        installment_type: Installment::AUDIENCE_TYPE,
        send_emails: true,
      )
      # Both markers live in json_data and the filter accessor rewrites that key wholesale,
      # so they are set on the record instead of being passed together as attributes.
      installment.json_data[WRITTEN_COPY_DIGEST_KEY] = written_copy_digest
      installment.json_data[LAUNCH_PRODUCT_KEY] = product.id
      installment.not_bought_products = [product.unique_permalink]
      installment.save!
      installment
    end

    def written_copy_digest = Digest::SHA256.hexdigest(message.to_s)

    # Subject is the product name; the body repeats it as the first word of the copy.
    def name = product.name.to_s.truncate(255)

    def message = self.class.message_for(product:, utm_link:)

    def not_bought_filter
      { not_bought_product_ids: [product.id] }
    end

    def count_for(type)
      AudienceMember.filter_count(seller_id: seller.id, params: not_bought_filter.merge(type:))
    end

    def total_count
      return existing.audience_members_count if existing

      AudienceMember.filter_count(seller_id: seller.id, params: not_bought_filter)
    end
end
