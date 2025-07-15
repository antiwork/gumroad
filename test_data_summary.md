# Test Data for Discount Bug Reproduction

## Overview
This document contains the test data created for reproducing the discount code bug where discounts don't apply correctly when switching from individual products to bundles in the cart.

## Test Data Created

### Product A
- **Name**: Product A
- **Price**: $50.00 (5000 cents)
- **Type**: Digital product
- **Permalink**: producta
- **Status**: Created successfully (ID: 4 based on console output)

### Bundle B
- **Name**: Bundle B
- **Price**: $150.00 (15000 cents)
- **Type**: Bundle
- **Permalink**: bundleb
- **Contains**: Product A
- **Status**: Attempted to create (may need to verify)

### Discount Code
- **Code**: HALF50 (also exists as HALFOFF from earlier attempt)
- **Discount**: 50% off
- **Type**: Percentage discount
- **Applies to**: Both Product A and Bundle B (when successfully associated)
- **Status**: Created (ID: 1 based on console output)

## Bug Reproduction Steps

1. Add Product A to cart
2. Apply discount code HALF50 - should show $25 (50% off $50)
3. Remove Product A from cart
4. Add Bundle B to cart
5. The discount may not apply correctly - this is the bug to investigate

## Notes
- The Rails console experienced some forking issues during data creation
- Product A was successfully created with ID 4
- Bundle B creation needs to be verified
- The discount code HALF50/HALFOFF exists and is set to 50% off
- Product-discount associations may need to be verified/completed

## Next Steps
1. Verify Bundle B was created successfully
2. Ensure Product A is added to Bundle B
3. Confirm discount code is associated with both products
4. Test the cart behavior to reproduce the bug
