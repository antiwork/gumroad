# frozen_string_literal: true

class Api::V2::Partner::MigrationsController < Api::V2::Partner::BaseController
  # Stores a creator's products and returns a one-time link. The creator opens the link to log in or
  # sign up, and the products are then imported as drafts in that Gumroad account. The response never
  # says whether `email` has a Gumroad account; the link checks that when the creator opens it.
  def create
    external_user_id = params[:external_user_id]
    max_length = PartnerMigration::MAX_EXTERNAL_USER_ID_LENGTH
    unless external_user_id.is_a?(String) && external_user_id.present? && external_user_id.length <= max_length
      return render_bad_request("external_user_id must be a string with 1 to #{max_length} characters, not only spaces.")
    end

    products, error = PartnerMigration.normalize_products(params[:products])
    return render_bad_request(error) if error

    seller, error = PartnerMigration.normalize_seller(email: params[:email], profile: params[:profile])
    return render_bad_request(error) if error

    return render_bad_request("new_onboarding_url must be true or false.") unless [nil, true, false].include?(params[:new_onboarding_url])

    part = params[:part].nil? ? 1 : params[:part]
    return render_bad_request("part must be a whole number from 1 to #{PartnerMigration::MAX_PARTS}.") unless part.is_a?(Integer) && part.between?(1, PartnerMigration::MAX_PARTS)
    return render_bad_request("Send email and profile with part 1.") if part > 1 && (params.key?(:email) || params.key?(:profile))
    total_parts = params[:total_parts]
    return render_bad_request("total_parts must be a whole number from 1 to #{PartnerMigration::MAX_PARTS}.") unless total_parts.nil? || (total_parts.is_a?(Integer) && total_parts.between?(1, PartnerMigration::MAX_PARTS))

    migration, code = PartnerMigration.create_for!(oauth_application: current_partner_application, external_user_id:, products:, part:, total_parts:, **seller, new_link: params[:new_onboarding_url] == true)

    render json: {
      success: true,
      migration_id: migration.public_id,
      part: migration.part,
      status: migration.status,
      # Absent when the request changed only download URLs: the link that the partner has stays valid.
      **(code ? { onboarding_url: partner_migration_url(migration_code: code, host: DOMAIN, protocol: PROTOCOL) } : {}),
      # The link of part 1 opens every part, so its expiry applies to all of them.
      expires_at: migration.head.expires_at.iso8601,
    }, status: migration.previously_new_record? ? :created : :ok
  rescue PartnerMigration::CatalogConflict => e
    render json: { success: false, message: e.message }, status: :conflict
  rescue PartnerMigration::PartError => e
    render_bad_request(e.message)
  end

  def show
    migration = PartnerMigration.find_by_public_id(params[:id])
    return head :not_found unless migration&.oauth_application_id == current_partner_application.id

    render json: { success: true, status: migration.status, **migration.progress, results: migration.results_by_external_product_id, failure_reason: migration.failure_reason }
  end
end
