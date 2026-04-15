# frozen_string_literal: true

class Admin::UserPresenter::Card
  attr_reader :user, :pundit_user

  def initialize(user:, pundit_user:)
    @user = user
    @pundit_user = pundit_user
  end

  def props
    {
      impersonatable: Admin::Impersonators::UserPolicy.new(pundit_user, user).create?,

      # Identification
      external_id: user.external_id,

      # Basic user fields
      name: user.name,
      bio: user.bio,

      # Display fields
      avatar_url: user.avatar_url,
      username: user.username,

      # Email fields
      email: user.form_email,
      form_email: user.form_email,
      form_email_domain: user.form_email_domain,
      support_email: user.support_email,

      # URLs
      profile_url: user.avatar_url,
      subdomain_with_protocol: user.subdomain_with_protocol,

      # Financial
      custom_fee_per_thousand: user.custom_fee_per_thousand,
      unpaid_balance_cents: user.unpaid_balance_cents,
      disable_paypal_sales: user.disable_paypal_sales,

      # Status flags
      verified: user.verified?,
      suspended: user.suspended?,
      flagged_for_fraud: user.flagged_for_fraud?,
      flagged_for_tos_violation: user.flagged_for_tos_violation?,
      on_probation: user.on_probation?,
      all_adult_products: user.all_adult_products?,

      # Risk & moderation
      user_risk_state: user.user_risk_state.humanize,
      comments_count: user.comments.size,
      compliant: user.compliant?,

      # Timestamps
      created_at: user.created_at,
      updated_at: user.updated_at,
      deleted_at: user.deleted_at,

      # Blocking information
      blocked_by_form_email_object: blocked_by_object_props(user.blocked_by_form_email_object),
      blocked_by_form_email_domain_object: blocked_by_object_props(user.blocked_by_form_email_domain_object),

      # Associations
      admin_manageable_user_memberships: user_memberships,
      alive_user_compliance_info: compliance_info
    }
  end

  private
    def blocked_by_object_props(blocked_object)
      blocked_object && {
        blocked_at: blocked_object.blocked_at,
        created_at: blocked_object.created_at
      }
    end

    def user_memberships
      user.admin_manageable_user_memberships.map do |membership|
        {
          id: membership.id,
          role: membership.role,
          last_accessed_at: membership.last_accessed_at,
          created_at: membership.created_at,
          updated_at: membership.updated_at,
          seller: {
            external_id: membership.seller.external_id,
            avatar_url: membership.seller.avatar_url,
            display_name_or_email: membership.seller.display_name_or_email
          }
        }
      end
    end

    def compliance_info
      return nil unless user.alive_user_compliance_info

      info = user.alive_user_compliance_info
      {
        is_business: info.is_business,
        first_name: info.first_name,
        last_name: info.last_name,
        street_address: info.street_address,
        city: info.city,
        state: info.state,
        state_code: info.state_code,
        zip_code: info.zip_code,
        country: info.country,
        country_code: info.country_code,
        business_name: info.business_name,
        business_type: info.business_type,
        business_street_address: info.business_street_address,
        business_city: info.business_city,
        business_state: info.business_state,
        business_state_code: info.business_state_code,
        business_zip_code: info.business_zip_code,
        business_country: info.business_country,
        business_country_code: info.business_country_code,
        created_at: info.created_at,
        has_individual_tax_id: info.has_individual_tax_id,
        has_business_tax_id: info.has_business_tax_id
      }
    end
end
