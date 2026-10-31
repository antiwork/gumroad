# frozen_string_literal: true

# One draft audience Installment for a product's launch, addressed to past customers, followers
# and affiliates but not the product's own buyers. Nothing here sends or schedules it.
class Marketing::LaunchEmail
  # json_data is merged per key on save, so these markers cost no extra column.
  WRITTEN_COPY_DIGEST_KEY = "marketing_launch_written_copy_digest"
  # The digest separates our copy from the seller's rewrite; the product id separates this
  # product's launch draft from an audience email the seller wrote themselves. The product
  # filter alone cannot do that.
  LAUNCH_PRODUCT_KEY = "marketing_launch_product_id"

  def initialize(product:, seller:, utm_link:)
    @product = product
    @seller = seller
    @utm_link = utm_link
  end

  # The draft for this product, created on first call and reused after that. Nil for a seller
  # who cannot send emails yet, so the caller surfaces the gate reason.
  def installment
    return unless seller.eligible_to_send_emails?

    # Serialized on the product: two overlapping card loads must not both mint a draft.
    product.with_lock do
      # Re-read under the lock: the counts may have been asked for before it was taken.
      @drafts = nil
      @existing = nil
      next nil if declined?

      @existing = existing ? refresh(existing) : create_draft
    end
  rescue ActiveRecord::RecordInvalid => e
    # The gate is not the only refusal: `send_emails` also caps a seller below the sales
    # threshold at 100 recipients, team members included. Report no draft, not a 500.
    Rails.logger.info("Marketing::LaunchEmail skipped product #{product.id}: #{e.message}")
    nil
  end

  # The Emails tab delete is the only way to refuse the channel (the row has no dismiss
  # control), so a deleted draft is never replaced.
  def declined? = drafts.any?(&:deleted?) && existing.nil?

  # `total` is the draft's own count, so the card and the Emails tab cannot disagree.
  def recipient_counts
    { customers: count_for("customer"), followers: count_for("follower"), affiliates: count_for("affiliate"), total: total_count }
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

    # Matched by our marker alone, never name, message or filters, which the seller may edit.
    # The marker doubles as the SQL prefilter so a card load never deserializes the whole
    # email history.
    def drafts
      @drafts ||= seller.installments
                        .where("json_data LIKE ?", "%#{LAUNCH_PRODUCT_KEY}%")
                        .select { launch_draft?(_1) }
                        .to_a
    end

    def existing = @existing ||= drafts.select(&:alive?).max_by(&:id)

    # The product filter is not re-read: the seller may retarget the draft in the Emails tab.
    def launch_draft?(installment) = installment.json_data[LAUNCH_PRODUCT_KEY].to_i == product.id

    # A draft the seller scheduled, sent or rewrote is theirs; only one still holding our own
    # copy is refreshed, so re-publishing does not discard their work.
    def refresh(installment)
      # The product lock serializes card loads, but the Emails editor writes this row.
      installment.with_lock do
        next if installment.published_at.present? || installment.ready_to_publish?
        next unless untouched?(installment)

        # Preserve the seller's subject while refreshing the generated body.
        installment.message = message
        installment.json_data[WRITTEN_COPY_DIGEST_KEY] = written_copy_digest
        installment.save!
      end
      installment
    end

    # Compares against the copy we last wrote. Comparing against the product instead would
    # call every draft edited the moment its description changes, which is the case a
    # refresh exists for.
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
      filters = existing ? existing.audience_members_filter_params : not_bought_filter
      return 0 if filters[:type].present? && filters[:type] != type

      AudienceMember.filter_count(seller_id: seller.id, params: filters.merge(type:))
    end

    def total_count
      return existing.audience_members_count if existing

      AudienceMember.filter_count(seller_id: seller.id, params: not_bought_filter)
    end
end
