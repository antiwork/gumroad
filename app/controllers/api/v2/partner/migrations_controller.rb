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

    migration, code = PartnerMigration.create_for!(oauth_application: current_partner_application, external_user_id:, products:, **seller)

    render json: {
      success: true,
      migration_id: migration.public_id,
      status: migration.status,
      onboarding_url: partner_migration_url(migration_code: code, host: DOMAIN, protocol: PROTOCOL),
      expires_at: migration.expires_at.iso8601,
    }, status: migration.previously_new_record? ? :created : :ok
  rescue PartnerMigration::CatalogConflict => e
    render json: { success: false, message: e.message }, status: :conflict
  end

  def show
    migration = PartnerMigration.find_by_public_id(params[:id])
    return head :not_found unless migration&.oauth_application_id == current_partner_application.id

    render json: { success: true, status: migration.status, **migration.progress, results: migration.results, failure_reason: migration.failure_reason }
  end
end
