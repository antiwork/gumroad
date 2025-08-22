# Gumroad Bounty Tracker

## Available Bounties (as of August 22, 2025)

### 🎯 Quick Wins ($2.5K each)

#### Issue #855: Add "Resend receipt" to API - $2.5K
- **Status**: ✅ Open (no active PRs)
- **Scope**: Add API endpoint to resend purchase receipts
- **Complexity**: Low - Single endpoint addition
- **Key tasks**:
  - Add new API endpoint `/api/v2/sales/{sale_id}/resend_receipt`
  - Integrate with existing email service
  - Write API tests
  - Update API documentation
- **Dependencies**: Email service (SendGrid/Resend)
- **Estimate**: 1-2 days

#### Issue #698: Add tax-inclusive pricing option for products - $2.5K
- **Status**: ✅ Open (no active PRs)
- **Scope**: Allow sellers to set tax-inclusive prices
- **Complexity**: Medium - Model + UI changes
- **Key tasks**:
  - Add tax_inclusive flag to products
  - Update pricing calculations
  - Modify checkout flow
  - Add UI toggle in product settings
- **Dependencies**: Tax calculation services (TaxJar, VATStack)
- **Estimate**: 3-4 days

#### Issue #864: Improve product quality - $1K + $250 (design)
- **Status**: ✅ Open (no active PRs)  
- **Scope**: UI/UX improvements for product pages
- **Complexity**: Low-Medium
- **Key tasks**: TBD based on specific requirements
- **Estimate**: 2-3 days

### 🔧 Medium Complexity

#### Issue #959: Run Gumroad tests without secrets - $5K
- **Status**: ⚠️ Multiple PR attempts (#961, #974) - needs fresh approach
- **Scope**: Enable test suite to run without environment secrets
- **Complexity**: Medium - Many services to mock
- **Key tasks**:
  - Create test-safe defaults for all env vars
  - Mock external services (Stripe, PayPal, AWS, etc.)
  - Ensure CI compatibility
  - Update documentation
- **Dependencies**: All external services used in tests
- **Existing work**: PR #961 (comprehensive approach), PR #974 (closed)
- **Estimate**: 4-5 days

#### Issue #568: Display error message to seller when payout fails - $2.5K
- **Status**: ⚠️ Assigned to @hchhabra
- **Scope**: Error handling for failed payouts
- **Complexity**: Medium
- **Note**: Already assigned, may not be available

### 📊 Long Haul

#### Issue #13: Add churn chart to analytics - $5K
- **Status**: ✅ Open (no active PRs)
- **Scope**: New analytics feature for subscription churn
- **Complexity**: High - New charts, data processing
- **Key tasks**:
  - Design churn calculation logic
  - Create data aggregation jobs
  - Build chart UI components
  - Add to analytics dashboard
- **Dependencies**: Chart libraries, background jobs
- **Estimate**: 5-7 days

### 🚀 Epic Level

#### Issue #856: SPA (Single Page Application) - $10K
- **Status**: ⚠️ Multiple PR attempts (#893, #942)
- **Scope**: Convert dashboard to React SPA
- **Complexity**: Very High - Major architectural change
- **Key tasks**:
  - React Router integration
  - API-first approach for all features
  - State management
  - Backward compatibility
  - Full test coverage
- **Note**: Requires senior/staff engineer level skills
- **Estimate**: 2-3 weeks

## Recommended Strategy

### Phase 1: Quick Wins (Week 1)
1. **Issue #855** - Resend receipt API ($2.5K)
   - Cleanest scope, minimal dependencies
   - Good first contribution to build reputation

2. **Issue #698** - Tax-inclusive pricing ($2.5K)
   - Moderate complexity but well-defined
   - Shows ability to handle business logic

### Phase 2: Medium Tasks (Week 2)
3. **Issue #959** - Tests without secrets ($5K)
   - Learn from previous attempts
   - Comprehensive solution needed

### Phase 3: Advanced (Week 3+)
4. **Issue #13** - Churn analytics ($5K)
   - If analytics experience available

## Contributing Guidelines Highlights

- Use conventional commits: `feat()`, `fix()`, `chore()`, etc.
- No "should" in test descriptions
- Sentence case for UI text (not Title Case)
- No code comments or apologies
- Native-sounding English in all communications
- Include test screenshots in PRs
- Don't force-push after reviews start

## Notes

- Total potential: $25K+ in bounties
- Competition exists - move fast on open issues
- Quality > Speed - maintainers value clean, tested code
- Build reputation with smaller tasks first
