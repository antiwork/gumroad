# frozen_string_literal: true

class Api::Internal::Admin::UsersController < Api::Internal::Admin::BaseController
  include Api::Internal::Admin::CursorPaginated

  VALID_AFFILIATE_DIRECTIONS = %w[granted received].freeze
  private_constant :VALID_AFFILIATE_DIRECTIONS

  def self.valid_purchase_states
    @valid_purchase_states ||= Purchase.state_machines[:purchase_state].states.map { _1.name.to_s }.freeze
  end

  def self.valid_comment_types
    @valid_comment_types ||= Comment.constants.grep(/^COMMENT_TYPE_/).map { Comment.const_get(_1) }.freeze
  end

  def info
    user = find_internal_admin_user_for_read_or_render(include_deleted: true)
    return unless user

    render json: internal_admin_user_success_payload(user, user: serialize_user_info(user))
  end

  def affiliates
    direction = params[:direction].to_s
    unless VALID_AFFILIATE_DIRECTIONS.include?(direction)
      return render json: { success: false, message: "direction must be 'granted' or 'received'" }, status: :bad_request
    end

    user = find_internal_admin_user_for_read_or_render(include_deleted: true)
    return unless user

    records, pagination = paginate_with_cursor(affiliates_scope(user, direction), order: [[:created_at, :desc], [:id, :desc]])
    sellers_by_id = sellers_by_id_for(records, direction)

    render json: internal_admin_user_success_payload(user, {
                                                       direction:,
                                                       affiliates: records.map { serialize_affiliate(_1, direction:, sellers_by_id:) },
                                                       pagination:,
                                                     })
  end

  def compliance_info
    user = find_internal_admin_user_for_read_or_render(include_deleted: true)
    return unless user

    render json: internal_admin_user_success_payload(user, {
                                                       compliance_info: serialize_compliance_info(user.alive_user_compliance_info),
                                                       info_requests: open_compliance_info_requests(user).map { serialize_compliance_info_request(_1) },
                                                     })
  end

  def comments
    user = find_internal_admin_user_for_read_or_render(include_deleted: true)
    return unless user

    comment_types = parse_comment_types
    return if comment_types.nil?

    records, pagination = paginate_with_cursor(
      comments_scope(user, comment_types),
      order: [[:created_at, :desc], [:id, :desc]]
    )

    render json: internal_admin_user_success_payload(user, {
                                                       comments: records.map { serialize_comment(_1) },
                                                       pagination:,
                                                     })
  end

  def purchases
    user = find_internal_admin_user_for_read_or_render(include_deleted: true)
    return unless user

    filters = parse_purchases_filters
    return if filters.nil?

    records, pagination = paginate_with_cursor(
      purchases_scope(user, filters),
      order: [[:created_at, :desc], [:id, :desc]]
    )

    render json: internal_admin_user_success_payload(user, {
                                                       purchases: records.map { serialize_purchase(_1) },
                                                       pagination:,
                                                     })
  end

  def suspension
    user = find_internal_admin_user_for_read_or_render
    return unless user

    render json: internal_admin_user_success_payload(user, {
                                                       status: suspension_status(user),
                                                       updated_at: last_status_changed_at(user)&.as_json,
                                                       appeal_url: nil
                                                     })
  end

  def reset_password
    user = find_internal_admin_user_for_write_or_render
    return unless user

    record_admin_write(action: "users.reset_password", target: user) do
      user.send_reset_password_instructions
      render json: internal_admin_user_success_payload(user, message: "Reset password instructions sent")
    end
  end

  def update_email
    return render_internal_admin_user_id_required if params[:user_id].blank?
    return render json: { success: false, message: "new_email is required" }, status: :bad_request if params[:new_email].blank?

    unless EmailFormatValidator.valid?(params[:new_email])
      return render json: { success: false, message: "Invalid new email format" }, status: :bad_request
    end

    user = find_internal_admin_user_for_write_or_render
    return unless user

    record_admin_write(action: "users.update_email", target: user) do
      if user.email.to_s.casecmp(params[:new_email].to_s).zero?
        return render json: { success: false, message: "New email is the same as the current email" }, status: :unprocessable_entity
      end

      user.email = params[:new_email]
      unless user.save
        return render json: { success: false, message: user.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      if user.unconfirmed_email.present?
        render json: internal_admin_user_success_payload(user, {
                                                           message: "Email change pending confirmation. Confirmation email sent to #{user.unconfirmed_email}.",
                                                           unconfirmed_email: user.unconfirmed_email,
                                                           pending_confirmation: true
                                                         })
      else
        render json: internal_admin_user_success_payload(user, {
                                                           message: "Email updated.",
                                                           email: user.email,
                                                           pending_confirmation: false
                                                         })
      end
    end
  end

  def two_factor_authentication
    return render json: { success: false, message: "enabled is required" }, status: :bad_request if params[:enabled].to_s.blank?

    user = find_internal_admin_user_for_write_or_render
    return unless user

    record_admin_write(action: "users.two_factor_authentication", target: user) do
      enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])
      user.two_factor_authentication_enabled = enabled

      if user.save
        user.totp_credential&.destroy unless user.two_factor_authentication_enabled?
        render json: internal_admin_user_success_payload(user, {
                                                           message: "Two-factor authentication #{enabled ? "enabled" : "disabled"}",
                                                           two_factor_authentication_enabled: user.two_factor_authentication_enabled?
                                                         })
      else
        render json: { success: false, message: user.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end
    end
  end

  def create_comment
    return render json: { success: false, message: "content is required" }, status: :bad_request if params[:content].blank?
    return render json: { success: false, message: "idempotency_key is required" }, status: :bad_request if params[:idempotency_key].blank?

    user = find_internal_admin_user_for_write_or_render
    return unless user

    record_admin_write(action: "users.create_comment", target: user) do
      comment = User::CreateAdminCommentService.new(user:, content: params[:content], idempotency_key: params[:idempotency_key], author_id: current_admin_actor_id).perform

      if comment.persisted?
        render json: internal_admin_user_success_payload(user, comment: serialize_comment(comment))
      else
        render json: { success: false, message: comment.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end
    rescue User::CreateAdminCommentService::IdempotencyConflictError
      render json: { success: false, message: "Idempotency key already used with different content" }, status: :conflict
    end
  end

  def mark_compliant
    user = find_internal_admin_user_for_write_or_render
    return unless user

    record_admin_write(action: "users.mark_compliant", target: user) do
      if user.compliant?
        return render json: internal_admin_user_success_payload(user, status: "already_compliant", message: "User is already compliant")
      end

      note = build_admin_note(user, params[:note]) if params[:note].present?
      return render_invalid_comment(note) if note&.invalid?

      user.mark_compliant!(author_id: current_admin_actor_id)
      note&.save!
      render json: internal_admin_user_success_payload(user, status: "marked_compliant", message: "User marked compliant")
    rescue StateMachines::InvalidTransition => e
      render json: { success: false, message: e.message }, status: :unprocessable_entity
    end
  end

  def suspend_for_fraud
    user = find_internal_admin_user_for_write_or_render
    return unless user

    record_admin_write(action: "users.suspend_for_fraud", target: user) do
      if user.suspended_for_fraud?
        return render json: internal_admin_user_success_payload(user, status: "already_suspended", message: "User is already suspended for fraud")
      end

      suspension_note = build_suspension_note(user) if params[:suspension_note].present?
      return render_invalid_comment(suspension_note) if suspension_note&.invalid?

      user.suspend_for_fraud!(author_id: current_admin_actor_id)
      suspension_note&.save!
      render json: internal_admin_user_success_payload(user, status: "suspended_for_fraud", message: "User suspended for fraud")
    rescue StateMachines::InvalidTransition => e
      render json: { success: false, message: e.message }, status: :unprocessable_entity
    end
  end

  def watch
    return render json: { success: false, message: "revenue_threshold is required" }, status: :bad_request if params[:revenue_threshold].blank?

    user = find_internal_admin_user_for_write_or_render
    return unless user

    record_admin_write(action: "users.watch", target: user) do
      threshold_cents = parse_threshold_cents(params[:revenue_threshold])
      return render json: { success: false, message: "revenue_threshold must be a positive number" }, status: :bad_request if threshold_cents.nil?

      if user.active_watched_user.present?
        return render json: { success: false, message: "User is already being watched" }, status: :unprocessable_entity
      end

      watched_user = user.watched_users.create!(
        revenue_threshold_cents: threshold_cents,
        notes: params[:notes].presence,
        created_by_id: current_admin_actor_id
      )
      watched_user.sync!

      render json: internal_admin_user_success_payload(user, {
                                                         message: "User added to watchlist",
                                                         watched_user: serialize_watched_user(watched_user)
                                                       })
    rescue ActiveRecord::RecordInvalid => e
      render json: { success: false, message: e.record.errors.full_messages.first }, status: :unprocessable_entity
    end
  end

  def update_watch
    return render json: { success: false, message: "revenue_threshold is required" }, status: :bad_request if params[:revenue_threshold].blank?

    user = find_internal_admin_user_for_write_or_render
    return unless user

    record_admin_write(action: "users.update_watch", target: user) do
      threshold_cents = parse_threshold_cents(params[:revenue_threshold])
      return render json: { success: false, message: "revenue_threshold must be a positive number" }, status: :bad_request if threshold_cents.nil?

      watched_user = user.active_watched_user
      return render json: { success: false, message: "User is not currently being watched" }, status: :unprocessable_entity if watched_user.nil?

      watched_user.update!(
        revenue_threshold_cents: threshold_cents,
        notes: params.key?(:notes) ? params[:notes].presence : watched_user.notes
      )

      render json: internal_admin_user_success_payload(user, {
                                                         message: "Watchlist updated",
                                                         watched_user: serialize_watched_user(watched_user)
                                                       })
    rescue ActiveRecord::RecordInvalid => e
      render json: { success: false, message: e.record.errors.full_messages.first }, status: :unprocessable_entity
    end
  end

  def unwatch
    user = find_internal_admin_user_for_write_or_render
    return unless user

    record_admin_write(action: "users.unwatch", target: user) do
      watched_user = user.active_watched_user
      return render json: { success: false, message: "User is not currently being watched" }, status: :unprocessable_entity if watched_user.nil?

      watched_user.mark_deleted!
      render json: internal_admin_user_success_payload(user, message: "User removed from watchlist")
    end
  end

  private
    def affiliates_scope(user, direction)
      column = direction == "granted" ? :seller_id : :affiliate_user_id
      scope = Affiliate.where(column => user.id, type: [DirectAffiliate.name, Collaborator.name])
      return scope.includes(:affiliate_user, product_affiliates: :product) if direction == "granted"

      scope.includes(product_affiliates: :product)
    end

    def comments_scope(user, comment_types)
      scope = user.comments.includes(:author)
      scope = scope.where(comment_type: comment_types) if comment_types.any?
      scope
    end

    def sellers_by_id_for(affiliates, direction)
      return {} unless direction == "received"

      seller_ids = affiliates.map(&:seller_id).compact.uniq
      User.where(id: seller_ids).index_by(&:id)
    end

    def serialize_affiliate(affiliate, direction:, sellers_by_id:)
      counterparty_user = direction == "granted" ? affiliate.affiliate_user : sellers_by_id[affiliate.seller_id]
      {
        id: affiliate.external_id,
        type: affiliate.type,
        direction:,
        counterparty: serialize_affiliate_counterparty(counterparty_user),
        affiliate_basis_points: affiliate.affiliate_basis_points,
        destination_url: affiliate.destination_url,
        apply_to_all_products: affiliate.apply_to_all_products?,
        alive: affiliate.alive?,
        deleted_at: affiliate.deleted_at&.as_json,
        created_at: affiliate.created_at.as_json,
        products: affiliate.product_affiliates.sort_by(&:id).map { serialize_affiliate_product(_1, parent_basis_points: affiliate.affiliate_basis_points) },
      }
    end

    def serialize_affiliate_counterparty(user)
      return nil if user.blank?

      {
        id: user.external_id,
        email: user.email,
        name: user.display_name(prefer_email_over_default_username: true)
      }
    end

    def serialize_affiliate_product(product_affiliate, parent_basis_points:)
      product = product_affiliate.product
      {
        id: product&.external_id,
        name: product&.name,
        basis_points: product_affiliate.affiliate_basis_points || parent_basis_points,
        destination_url: product_affiliate.destination_url,
      }
    end

    def serialize_compliance_info(info)
      return nil if info.nil?

      {
        id: info.external_id,
        is_business: info.is_business?,
        legal_name: info.legal_entity_name.presence,
        first_name: info.first_name,
        last_name: info.last_name,
        dba: info.dba,
        birthday: info.birthday&.iso8601,
        nationality: info.nationality,
        phone: info.phone,
        job_title: info.job_title,
        address: serialize_compliance_address(
          street_address: info.street_address,
          city: info.city,
          state: info.state,
          state_code: info.state_code,
          zip_code: info.zip_code,
          country: info.country,
          country_code: info.country_code
        ),
        business_name: info.business_name,
        business_type: info.business_type,
        business_phone: info.business_phone,
        business_vat_id_number: info.business_vat_id_number,
        business_address: info.is_business? ? serialize_compliance_address(
          street_address: info.business_street_address,
          city: info.business_city,
          state: info.business_state,
          state_code: info.business_state_code,
          zip_code: info.business_zip_code,
          country: info.business_country,
          country_code: info.business_country_code
        ) : nil,
        tax_ids: {
          individual_last_four: tax_id_last_four(info.individual_tax_id),
          business_last_four: tax_id_last_four(info.business_tax_id, digits_only: true),
        },
        identity_documents: {
          stripe_identity_document_id: info.stripe_identity_document_id,
          stripe_company_document_id: info.stripe_company_document_id,
          stripe_additional_document_id: info.stripe_additional_document_id,
        },
        created_at: info.created_at.as_json,
        updated_at: info.updated_at.as_json,
      }
    end

    def serialize_compliance_address(street_address:, city:, state:, state_code:, zip_code:, country:, country_code:)
      {
        street_address:,
        city:,
        state:,
        state_code:,
        zip_code:,
        country:,
        country_code:,
      }
    end

    def tax_id_last_four(encrypted_tax_id, digits_only: false)
      return nil if encrypted_tax_id.blank?

      decrypted = encrypted_tax_id.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")).to_s
      decrypted = decrypted.gsub(/\D/, "") if digits_only
      decrypted[-4..]
    end

    def open_compliance_info_requests(user)
      user.user_compliance_info_requests
          .requested
          .order(Arel.sql("ISNULL(due_at), due_at ASC, created_at ASC"))
    end

    def serialize_compliance_info_request(request)
      due_at = request.due_at
      {
        id: request.external_id,
        field_needed: request.field_needed,
        state: request.state,
        due_at: due_at&.as_json,
        overdue: due_at.present? && due_at < Time.current,
        created_at: request.created_at.as_json,
        last_email_sent_at: request.last_email_sent_at&.as_json,
      }
    end

    def parse_purchases_filters
      filters = {}
      valid_states = self.class.valid_purchase_states

      if params[:status].present?
        states = Array(params[:status]).flat_map { _1.to_s.split(",") }.map(&:strip).reject(&:blank?)
        invalid = states - valid_states
        if states.empty? || invalid.any?
          render json: { success: false, message: "status must be one of: #{valid_states.join(", ")}" }, status: :bad_request
          return nil
        end
        filters[:states] = states
      end

      if params[:start_at].present?
        filters[:start_at] = parse_iso8601_param(params[:start_at])
        return render_invalid_purchases_filter_timestamp("start_at") if filters[:start_at].nil?
      end

      if params[:end_at].present?
        filters[:end_at] = parse_iso8601_param(params[:end_at])
        return render_invalid_purchases_filter_timestamp("end_at") if filters[:end_at].nil?
      end

      %i[chargedback has_early_fraud_warning has_affiliate].each do |key|
        next unless params.key?(key)

        casted = boolean_param(params[key])
        return render_invalid_purchases_filter_boolean(key) if casted.nil?

        filters[key] = casted
      end

      filters[:stripe_fingerprint] = params[:stripe_fingerprint].to_s if params[:stripe_fingerprint].present?
      filters[:ip_address] = params[:ip_address].to_s if params[:ip_address].present?

      filters
    end

    def parse_iso8601_param(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def boolean_param(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def render_invalid_purchases_filter_timestamp(name)
      render json: { success: false, message: "#{name} must be a valid ISO 8601 timestamp" }, status: :bad_request
      nil
    end

    def render_invalid_purchases_filter_boolean(name)
      render json: { success: false, message: "#{name} must be true or false" }, status: :bad_request
      nil
    end

    def parse_comment_types
      raw = params[:comment_type].to_s
      return [] if raw.blank?

      values = raw.split(",").map(&:strip).reject(&:blank?)
      invalid = values - self.class.valid_comment_types
      if values.empty? || invalid.any?
        render json: { success: false, message: "comment_type contains invalid value: #{invalid.first || raw}" }, status: :bad_request
        return nil
      end

      values
    end

    def purchases_scope(user, filters)
      scope = Purchase.where(purchaser_id: user.id)
      scope = scope.or(Purchase.where(email: user.email)) if user.email.present?
      scope = scope.includes(:link, :seller, :refunds)

      scope = scope.where(purchase_state: filters[:states]) if filters[:states]
      scope = scope.where("purchases.created_at >= ?", filters[:start_at]) if filters[:start_at]
      scope = scope.where("purchases.created_at <= ?", filters[:end_at]) if filters[:end_at]

      if filters.key?(:chargedback)
        scope = filters[:chargedback] ? scope.where.not(chargeback_date: nil) : scope.where(chargeback_date: nil)
      end

      if filters.key?(:has_early_fraud_warning)
        scope = if filters[:has_early_fraud_warning]
          scope.joins(:early_fraud_warning)
        else
          scope.left_outer_joins(:early_fraud_warning).where(purchase_early_fraud_warnings: { id: nil })
        end
      end

      if filters.key?(:has_affiliate)
        scope = filters[:has_affiliate] ? scope.where.not(affiliate_id: nil) : scope.where(affiliate_id: nil)
      end

      scope = scope.where(stripe_fingerprint: filters[:stripe_fingerprint]) if filters[:stripe_fingerprint]
      scope = scope.where(ip_address: filters[:ip_address]) if filters[:ip_address]

      scope
    end

    def suspension_status(user)
      Admin::UserRiskStatePresenter.new(user).props[:status]
    end

    def last_status_changed_at(user)
      Admin::UserRiskStatePresenter.new(user).props[:last_status_changed_at]
    end

    def serialize_user_info(user)
      compliance_info = user.alive_user_compliance_info

      {
        id: user.external_id,
        email: user.form_email,
        name: user.name,
        username: user.username,
        profile_url: user.subdomain_with_protocol,
        country: compliance_info&.country,
        locale: user.locale,
        timezone: user.timezone,
        created_at: user.created_at.as_json,
        deleted_at: user.deleted_at&.as_json,
        risk_state: Admin::UserRiskStatePresenter.new(user).props,
        active_watched_user: serialize_watched_user(user.active_watched_user),
        two_factor_authentication_enabled: user.two_factor_authentication_enabled?,
        sign_in: serialize_sign_in(user),
        social: serialize_social(user),
        payouts: {
          paused_internally: user.payouts_paused_internally?,
          paused_by_user: user.payouts_paused_by_user?,
          paused_by_source: user.payouts_paused_by_source,
          paused_for_reason: user.payouts_paused_for_reason,
          next_payout_date: user.next_payout_date&.to_s,
          balance_for_next_payout: user.formatted_balance_for_next_payout_date
        },
        stats: {
          sales_count: user.sales.successful.count,
          total_earnings_formatted: Money.from_cents(user.sales_cents_total).format,
          unpaid_balance_formatted: Money.from_cents(user.unpaid_balance_cents).format,
          comments_count: user.comments.size
        }
      }
    end

    def serialize_sign_in(user)
      {
        account_created_ip: user.account_created_ip,
        current_ip: user.current_sign_in_ip,
        current_at: user.current_sign_in_at&.as_json,
        last_ip: user.last_sign_in_ip,
        last_at: user.last_sign_in_at&.as_json,
        count: user.sign_in_count
      }
    end

    def serialize_social(user)
      {
        twitter_user_id: user.twitter_user_id,
        twitter_handle: user.twitter_handle,
        facebook_uid: user.facebook_uid,
        google_uid: user.google_uid,
        oauth_provider: user.provider,
        external_authentications: user.user_external_authentications.order(:created_at).map { serialize_external_authentication(_1) }
      }
    end

    def serialize_external_authentication(authentication)
      {
        provider: authentication.provider,
        uid: authentication.uid,
        linked_at: authentication.created_at.as_json
      }
    end

    def serialize_comment(comment)
      {
        id: comment.external_id,
        author_name: comment.author_name.presence || comment.author&.name || "System",
        content: comment.content,
        comment_type: comment.comment_type,
        created_at: comment.created_at.iso8601,
        deleted_at: comment.deleted_at&.iso8601,
        alive: comment.alive?
      }
    end

    def build_admin_note(user, content)
      user.comments.new(
        author_id: current_admin_actor_id,
        comment_type: Comment::COMMENT_TYPE_NOTE,
        content:
      )
    end

    def build_suspension_note(user)
      user.comments.new(
        author_id: current_admin_actor_id,
        comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE,
        content: params[:suspension_note]
      )
    end

    def render_invalid_comment(comment)
      render json: { success: false, message: comment.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end

    def parse_threshold_cents(raw)
      threshold = BigDecimal(raw.to_s)
      return nil unless threshold.finite?

      cents = (threshold * 100).round
      cents.positive? ? cents : nil
    rescue ArgumentError
      nil
    end

    def serialize_watched_user(watched_user)
      return nil unless watched_user

      {
        id: watched_user.external_id,
        revenue_threshold_cents: watched_user.revenue_threshold_cents,
        revenue_cents: watched_user.revenue_cents,
        unpaid_balance_cents: watched_user.unpaid_balance_cents,
        notes: watched_user.notes,
        created_at: watched_user.created_at.iso8601,
        last_synced_at: watched_user.last_synced_at&.iso8601
      }
    end
end
