# frozen_string_literal: true

class Onetime::BackfillUserTaxForms
  def initialize(stripe_account_ids:, tax_year:, tax_form_type:)
    @stripe_account_ids = stripe_account_ids
    @tax_year = tax_year
    @tax_form_type = tax_form_type
    @results = { created: 0, skipped: 0, errors: {} }

    validate_inputs!
  end

  def perform
    stripe_account_ids.each { backfill_stripe_account(_1) }

    puts "Done!"
  end

  private
    attr_reader :stripe_account_ids, :tax_year, :tax_form_type, :results

    def validate_inputs!
      unless UserTaxForm::TAX_FORM_TYPES.include?(tax_form_type)
        raise ArgumentError, "Invalid tax_form_type: #{tax_form_type}. Must be one of: #{UserTaxForm::TAX_FORM_TYPES.join(', ')}"
      end

      unless tax_year.is_a?(Integer) && tax_year >= UserTaxForm::MIN_TAX_YEAR && tax_year <= Time.current.year
        raise ArgumentError, "Invalid year: #{tax_year}. Must be between #{MIN_TAX_YEAR} and #{Time.current.year}"
      end

      unless stripe_account_ids.is_a?(Array) && stripe_account_ids.all? { |id| id.is_a?(String) }
        raise ArgumentError, "stripe_account_ids must be an array of strings"
      end
    end

    def backfill_stripe_account(stripe_account_id)
      merchant_account = MerchantAccount.stripe.find_by(charge_processor_merchant_id: stripe_account_id)

      unless merchant_account
        @results[:errors][stripe_account_id] ||= []
        @results[:errors][stripe_account_id] << "Stripe account not found"
        return
      end

      user = merchant_account.user

      tax_form = UserTaxForm.find_or_initialize_by(user:, tax_year:, tax_form_type:)

      if tax_form.new_record?
        tax_form.stripe_account_id = stripe_account_id
        if tax_form.save
          @results[:created] += 1
          puts "[CREATED] user_id=#{user.id}, year=#{tax_year}, type=#{tax_form_type}, stripe_account_id=#{stripe_account_id}"
        else
          @results[:errors][stripe_account_id] ||= []
          @results[:errors][stripe_account_id] << "Failed to save for user_id=#{user.id}: #{tax_form.errors.full_messages.join(', ')}"
        end
      else
        @results[:skipped] += 1
        puts "[SKIPPED] user_id=#{user.id}, year=#{tax_year}, type=#{tax_form_type}"
      end
    rescue => e
      @results[:errors][stripe_account_id] ||= []
      @results[:errors][stripe_account_id] << "Error processing #{stripe_account_id}: #{e.message}"
    end
end
