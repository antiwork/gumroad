# frozen_string_literal: true

class CustomDomain::VerificationsController < Sellers::BaseController
  def create
    authorize [:settings, :advanced, current_seller], :show?

    has_valid_configuration = CustomDomainVerificationService.new(domain: params[:domain]).process

    passes_model_validation =
      if params[:product_id]
        product = Link.find_by_external_id(params[:product_id])
        if product
          custom_domain = product.custom_domain || product.build_custom_domain
          custom_domain.domain = params[:domain]
          custom_domain.valid?
        else
          false
        end
      else
        true
      end

    success, message =
      if has_valid_configuration
        if passes_model_validation
          [true, "#{params[:domain]} domain is correctly configured!"]
        else
          [false, product&.custom_domain&.errors&.map(&:type)&.first || "Domain verification failed. Please make sure you have correctly configured the DNS record for #{params[:domain]}."]
        end
      else
        [false, "Domain verification failed. Please make sure you have correctly configured the DNS record for #{params[:domain]}."]
      end

    render json: { success:, message: }
  end
end
