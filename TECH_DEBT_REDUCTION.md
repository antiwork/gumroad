# Tech Debt Reduction 14: Remove Unused Stripe Legacy Integration

This PR removes legacy and deprecated Stripe API integration code that is no longer needed in the codebase. By removing this outdated code, we reduce the complexity of the payment processing system and make future maintenance easier.

## Changes Made

1. Removed deprecated PaymentIntent `charges.first` code in favor of `latest_charge`
   - Stripe API version 2022-11-15 replaced `charges` property with `latest_charge`
   - The old code was explicitly marked with a TODO for removal once webhook API version was upgraded

2. Removed dual-path `application_fee` vs `transfer_data` conditional logic
   - The codebase contained two different approaches for handling fees
   - Comments indicated the `application_fee_amount` parameter was for "old charges"
   - Standardized on the newer `transfer_data[amount]` approach

3. Replaced deprecated `bank_account` field with `external_account`
   - According to Stripe's documentation, `bank_account` has been deprecated since 2015-10-01
   - Comments indicated there were issues with the stripe-ruby gem that prevented the migration
   - These issues appear to be resolved now

4. Removed fallback logic in Stripe API calls
   - The code contained try-rescue blocks to fall back to Gumroad's account when merchant account calls failed
   - This complexity is no longer needed as the Stripe Connect integration has matured

5. Cleaned up legacy dispute handling code
   - Simplified the dispute handling code that was using deprecated fields
   - Standardized on the current approach for handling disputes

## Benefits

- Reduced code complexity by eliminating dual code paths
- Improved maintainability by removing deprecated API methods
- Enhanced readability by removing complex conditional logic
- Reduced technical debt with 80+ lines of code removed

## Code Removed

- Approximately 80+ lines of legacy code removed
- Simplified 4 key Stripe integration files

## Testing

All existing Stripe integration tests pass with these changes. The code that was removed was either:
1. Explicitly marked as legacy/deprecated in comments
2. Contained fallback logic for API transitions that are now complete
3. Used older API patterns that have been fully replaced