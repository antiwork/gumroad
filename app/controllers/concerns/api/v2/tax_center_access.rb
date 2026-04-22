# frozen_string_literal: true

module Api::V2::TaxCenterAccess
  extend ActiveSupport::Concern

  included do
    before_action -> { doorkeeper_authorize!(:view_tax_data) }
    before_action :ensure_tax_center_enabled
  end

  private
    def ensure_tax_center_enabled
      return if current_resource_owner.tax_center_enabled?

      render status: :forbidden, json: { success: false, message: "Tax center is not enabled for this account." }
    end

    def valid_tax_year?(year)
      year.is_a?(Integer) && available_tax_years.include?(year)
    end

    def parse_year_param
      Integer(params[:year].to_s, exception: false)
    end

    def available_tax_years
      @available_tax_years ||= current_resource_owner.tax_form_available_years
    end

    def render_year_not_available(year, resource_label)
      suffix = year ? "for #{year}." : "for the requested year."
      render status: :not_found, json: { success: false, message: "#{resource_label} are not available #{suffix}" }
    end
end
