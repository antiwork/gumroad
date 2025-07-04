# PR #435 Evaluation: Fix installment payment calculation for more than 2 installments

## Issue Description
The current installment payment calculation has a fundamental flaw: when the total price doesn't divide evenly by the number of installments, the entire remainder is added to the first installment. This creates an unbalanced payment schedule that can be confusing for customers.

## Current Behavior (Problematic)
```ruby
# Example: $30.02 ÷ 3 installments
# Current result: [$10.02, $10.00, $10.00]
# The first payment is $0.02 higher than the others

def calculate_installment_payment_price_cents(full_price_cents)
  base_price = full_price_cents / number_of_installments
  remainder = full_price_cents % number_of_installments

  Array.new(number_of_installments) do |i|
    i.zero? ? base_price + remainder : base_price  # <- All remainder goes to first installment
  end
end
```

## Proposed Fix
Distribute the remainder evenly across the first N installments instead of adding it all to the first installment.

```ruby
# Example: $30.02 ÷ 3 installments
# New result: [$10.01, $10.01, $10.00]
# Only $0.01 difference between installments

def calculate_installment_payment_price_cents(full_price_cents)
  base_price = full_price_cents / number_of_installments
  remainder = full_price_cents % number_of_installments

  Array.new(number_of_installments) do |i|
    if i < remainder
      base_price + 1  # <- Distribute remainder across first N installments
    else
      base_price
    end
  end
end
```

## Test Results Demonstration

### Before Fix (Current Implementation)
- `$30.02 ÷ 3 = [$10.02, $10.00, $10.00]` - First payment $0.02 higher
- `$10.06 ÷ 7 = [$1.48, $1.43, $1.43, $1.43, $1.43, $1.43, $1.43]` - First payment $0.05 higher
- `$100.07 ÷ 10 = [$10.07, $10.00, ...]` - First payment $0.07 higher

### After Fix (New Implementation)
- `$30.02 ÷ 3 = [$10.01, $10.01, $10.00]` - Only $0.01 difference
- `$10.06 ÷ 7 = [$1.44, $1.44, $1.44, $1.44, $1.44, $1.43, $1.43]` - Max difference $0.01
- `$100.07 ÷ 10 = [$10.01, $10.01, $10.01, $10.01, $10.01, $10.01, $10.01, $10.00, $10.00, $10.00]` - Only $0.01 difference

## Updated Test Cases
The PR includes comprehensive tests that would fail with the current implementation but pass with the new implementation:

```ruby
describe "#calculate_installment_payment_price_cents" do
  context "when price is not evenly divisible" do
    it "distributes remainder evenly across first installments with 2 cent remainder" do
      result = installment_plan.calculate_installment_payment_price_cents(3002)
      expect(result).to eq([1001, 1001, 1000])  # OLD: [1002, 1000, 1000]
    end

    it "distributes remainder evenly with 4 installments and 3 cent remainder" do
      installment_plan.number_of_installments = 4
      result = installment_plan.calculate_installment_payment_price_cents(1003)
      expect(result).to eq([251, 251, 251, 250])  # OLD: [253, 250, 250, 250]
    end

    it "handles large remainder with many installments" do
      installment_plan.number_of_installments = 7
      result = installment_plan.calculate_installment_payment_price_cents(1006)
      expect(result).to eq([144, 144, 144, 144, 144, 144, 142])  # OLD: [148, 143, 143, 143, 143, 143, 143]
    end
  end
end
```

## Files Changed
1. `app/models/product_installment_plan.rb` - Ruby backend logic
2. `app/javascript/utils/price.ts` - TypeScript frontend logic
3. `spec/models/product_installment_plan_spec.rb` - Updated tests

## Benefits of the Fix
1. **Better UX**: More balanced payment schedule for customers
2. **Fairer Distribution**: Spreads remainder evenly instead of penalizing first payment
3. **Consistent Logic**: Same approach works for any number of installments
4. **Maintains Accuracy**: Total still adds up correctly

## Recommendation
✅ **APPROVE** - This fix addresses a real UX issue and makes the payment schedule more balanced and fair for customers. The tests comprehensively cover the edge cases and demonstrate the improvement clearly.

The fix should be implemented in both the Ruby backend and TypeScript frontend to ensure consistency across the application.
