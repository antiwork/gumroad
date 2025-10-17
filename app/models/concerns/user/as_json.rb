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
        :display_name,
        :form_email,
        :form_email_block,
        :form_email_domain,
        :form_email_domain_block,
        :avatar_url,
        :username,
        :subdomain_with_protocol,
        :support_email,
        :custom_fee_per_thousand,
        :updated_at,
        :verified,
        :deleted_at,
        :all_adult_products,
        :unpaid_balance_cents,
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
        },
        alive_user_compliance_info: {
          only: %i[is_business first_name last_name street_address city state state_code zip_code country country_code business_name business_type business_street_address business_city business_state business_zip_code business_country created_at],
          methods: %i[country_code business_country_code state_code business_state_code has_individual_tax_id has_business_tax_id]
        }
      }
    ).merge(
      id:,
      impersonatable:,
      user_risk_state: user_risk_state.humanize,
      comment_count: comments.size
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
