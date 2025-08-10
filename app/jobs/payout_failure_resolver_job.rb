# Job para resolver fallos de pago de forma asíncrona
class PayoutFailureResolverJob < ApplicationJob
  queue_as :high_priority

  def perform(user_id, failure_type, context = {})
    resolver = PayoutFailureResolver.new(
      user_id: user_id,
      failure_type: failure_type.to_sym,
      context: context.symbolize_keys
    )

    begin
      resolver.resolve!
      Rails.logger.info("Successfully resolved payout failure for user #{user_id}, type: #{failure_type}")
    rescue => e
      Rails.logger.error("Failed to resolve payout failure for user #{user_id}: #{e.message}")
      raise e
    end
  end
end

# Rake task para aplicar correcciones masivas
namespace :payouts do
  desc "Fix payout failures based on issue #650"
  task fix_failures: :environment do
    failures = [
      { user_id: 11152070, type: :duplicate_balance_increment, 
        context: { 
          duplicate_purchase_ids: [246694096, 270145984, 271240392, 275937297, 280598592, 285010678],
          excess_amount: 118.41,
          currency: 'EUR'
        }
      },
      { user_id: 366191, type: :stripe_account_mismatch,
        context: {
          old_stripe_account_id: 'acct_ca_deleted',
          new_stripe_account_id: 'acct_it_current',
          dispute_amount: 120.43,
          currency: 'USD'
        }
      },
      { user_id: 20913918, type: :negative_balance_country_change,
        context: {
          old_country: 'SG',
          new_country: 'SG', # Verificar país correcto
          negative_balance: -100 # Ejemplo, usar valor real
        }
      },
      { user_id: 6888879, type: :stripe_loan_webhook_handling,
        context: {
          loan_amount: 3446.89,
          webhook_payment_id: 'py_example'
        }
      },
      { user_id: 20768641, type: :obsolete_stripe_account,
        context: {
          obsolete_stripe_account_id: 'acct_old_stripe'
        }
      }
    ]

    failures.each do |failure|
      puts "Processing failure for user #{failure[:user_id]}..."
      
      PayoutFailureResolverJob.perform_now(
        failure[:user_id],
        failure[:type],
        failure[:context]
      )
      
      puts "✓ Completed"
    end

    puts "All payout failures have been processed!"
  end
end
