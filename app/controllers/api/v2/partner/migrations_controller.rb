# frozen_string_literal: true

class Api::V2::Partner::MigrationsController < Api::V2::Partner::BaseController
  # Stores a creator's products and returns a one-time link. The creator opens the link to log in or
  # sign up, and the products are then imported as drafts in that Gumroad account.
  def create
    external_user_id = params[:external_user_id]
    unless external_user_id.is_a?(String) && external_user_id.length.between?(1, 255)
      return render_bad_request("external_user_id must be a string with 1 to 255 characters.")
    end

    products, error = PartnerMigration.normalize_products(params[:products])
    return render_bad_request(error) if error

    migration, code = PartnerMigration.create_for!(oauth_application: current_partner_application, external_user_id:, products:)

    render json: {
      success: true,
      onboarding_url: partner_migration_url(migration_code: code, host: DOMAIN, protocol: PROTOCOL),
      expires_at: migration.expires_at.iso8601,
    }, status: :created
  end
end
