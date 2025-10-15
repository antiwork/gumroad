# frozen_string_literal: true

module User::AsJson
  extend ActiveSupport::Concern

  def as_json(options = {})
    return as_json_for_admin(impersonatable: options.delete(:impersonatable)) if options.delete(:admin)

    result =
      if options[:internal_use] || valid_api_scope?(options)
        super(only: %i[name bio twitter_handle currency_type], methods: options[:methods], include: options[:include])
          .merge(common_fields_for_as_json)
          .merge(profile_url: avatar_url, email: form_email)
      else
        super(only: %i[name bio twitter_handle])
          .compact
          .merge(common_fields_for_as_json)
      end

    if view_profile_scope?(options)
      result[:display_name] = display_name
    end

    if options[:internal_use]
      result.merge!(internal_use_fields_for_as_json)
    end

    result.with_indifferent_access
  end

  def as_json_for_admin(impersonatable: false)
    as_json(
      internal_use: true,
      methods: [
        :id,
        :display_name,
        :form_email,
        :blocked_by_form_email_at,
        :form_email_domain,
        :blocked_by_form_email_domain_at,
        :avatar_url,
        :username,
        :subdomain_with_protocol,
        :support_email,
        :custom_fee_percent,
        :has_payments,
        :updated_at,
        :verified,
        :deleted,
        :deleted_at,
        :all_adult_products,
        :unpaid_balance_cents,
        :compliant,
        :suspended,
        :flagged_for_fraud,
        :flagged_for_tos_violation,
        :on_probation,
        :disable_paypal_sales
      ],
      include: {
        admin_manageable_user_memberships: {
          include: {
            seller: {
              only: [:id],
              methods: [:avatar_url, :display_name_or_email]
            }
          }
        }
      }
    ).merge(
      impersonatable:,
      user_risk_state: user_risk_state.humanize
    )
  end

  private
    def view_profile_scope?(options)
      api_scopes_options(options).include?("view_profile")
    end

    def valid_api_scope?(options)
      (%w[edit_products view_sales revenue_share ifttt view_profile] & api_scopes_options(options)).present?
    end

    def api_scopes_options(options)
      Array(options[:api_scopes])
    end

    def common_fields_for_as_json
      {
        id: external_id,
        user_id: ObfuscateIds.encrypt(id),
        url: profile_url,
        links: (links.presence && links.alive.map(&:general_permalink)),
      }
    end

    def internal_use_fields_for_as_json
      {
        created_at:,
        sign_in_count:,
        current_sign_in_at:,
        last_sign_in_at:,
        current_sign_in_ip:,
        last_sign_in_ip:,
        purchases_count: purchases.count,
        successful_purchases_count: purchases.successful_or_preorder_authorization_successful.count,
      }
    end
end
