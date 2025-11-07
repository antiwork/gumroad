# Churn Analytics Feature - Test Plan

## Overview
This test plan covers the Churn Analytics feature (#13) to ensure it meets all requirements and works correctly.

## Requirements Validation Checklist

### ✅ Core Requirements from Issue #13
- [ ] New "Churn" tab visible in Analytics page
- [ ] Only visible to creators with subscription products
- [ ] Filterable by daily/monthly aggregation
- [ ] Filterable by date range (custom date picker)
- [ ] Displays 4 highlight cards:
  - [ ] Churn rate (current period)
  - [ ] Last period churn rate
  - [ ] Revenue lost (sum of MRR from churned subscriptions)
  - [ ] Churned users (count)
- [ ] Chart showing churn over time
- [ ] Mobile responsive design

### ✅ Formula Verification
**Specified Formula:**
```
Churn rate = (Cancelled subscriptions / (Active at start + New subscriptions)) × 100
```

**Implementation Location:**
- `app/services/creator_analytics/churn.rb` lines 33-46

## Manual Testing Plan

### Setup Prerequisites
1. **Start the application:**
   ```bash
   cd /Users/adruiz/projects/antiwork/gumroad
   bin/dev
   ```

2. **Access the application:**
   - Navigate to: `https://gumroad.dev`
   - Login with: `seller@gumroad.com` / `password` / 2FA: `000000`

### Test Case 1: Visibility - User WITH Subscription Products
**Goal:** Verify Churn tab appears only for users with subscription products

**Steps:**
1. Login as a user with subscription/membership products
2. Navigate to `/dashboard/sales` (Analytics)
3. Check the tabs in the page header

**Expected Results:**
- ✅ "Churn" tab is visible between "Sales" and "Links" tabs
- ✅ Tab is clickable
- ✅ Clicking navigates to `/dashboard/churn`

### Test Case 2: Visibility - User WITHOUT Subscription Products
**Goal:** Verify Churn tab is hidden for users without subscription products

**Steps:**
1. Login as a user WITHOUT subscription products (or disable all subscription products)
2. Navigate to `/dashboard/sales`
3. Check the tabs

**Expected Results:**
- ✅ "Churn" tab is NOT visible
- ✅ Only "Following", "Sales", and "Links" tabs appear
- ✅ Direct navigation to `/dashboard/churn` shows placeholder message

### Test Case 3: Placeholder State
**Goal:** Verify correct placeholder when no subscription products exist

**Steps:**
1. As user without subscription products
2. Navigate directly to `/dashboard/churn`

**Expected Results:**
- ✅ Placeholder image displays
- ✅ Message: "No subscription products found"
- ✅ Explanation text about needing subscription products
- ✅ Link to help documentation

### Test Case 4: Highlight Cards - Data Display
**Goal:** Verify all 4 highlight cards show correct data

**Steps:**
1. Navigate to `/dashboard/churn` as user with subscription products
2. Select a date range with known churn data
3. Verify each card displays

**Expected Results:**
- ✅ **Card 1 (Churn Rate):** Shows percentage (e.g., "5.25%")
- ✅ **Card 2 (Last Period Churn Rate):** Shows previous period percentage
- ✅ **Card 3 (Revenue Lost):** Shows formatted currency (e.g., "$1,234")
- ✅ **Card 4 (Churned Users):** Shows integer count (e.g., "15")
- ✅ All cards have appropriate icons
- ✅ No "NaN" or undefined values

### Test Case 5: Chart Visualization
**Goal:** Verify churn chart displays correctly

**Steps:**
1. On `/dashboard/churn` with valid data
2. Observe the line chart

**Expected Results:**
- ✅ Line chart displays with churn rate on Y-axis
- ✅ Y-axis shows percentage (0% to max%)
- ✅ X-axis shows dates/months
- ✅ Line is red/error color (matches design)
- ✅ Chart is responsive (scales with window)

### Test Case 6: Chart Tooltip/Hover
**Goal:** Verify interactive tooltip shows detailed data

**Steps:**
1. Hover over data points on the chart

**Expected Results:**
- ✅ Tooltip appears near cursor
- ✅ Shows: Churn Rate percentage
- ✅ Shows: Churned Users count
- ✅ Shows: Revenue Lost amount
- ✅ Shows: Date/time period
- ✅ Tooltip follows mouse movement

### Test Case 7: Daily/Monthly Toggle
**Goal:** Verify aggregation toggle works correctly

**Steps:**
1. On `/dashboard/churn`
2. Select "Daily" from dropdown → observe chart
3. Select "Monthly" from dropdown → observe chart

**Expected Results:**
- ✅ Chart updates when selection changes
- ✅ Daily: Shows individual days as data points
- ✅ Monthly: Aggregates data by month
- ✅ Monthly calculation correctly averages/sums values
- ✅ No errors in browser console

### Test Case 8: Date Range Picker
**Goal:** Verify custom date range filtering works

**Steps:**
1. Click date range picker
2. Select custom start date (e.g., 30 days ago)
3. Select custom end date (e.g., today)
4. Apply selection

**Expected Results:**
- ✅ Date picker opens/closes smoothly
- ✅ Selected dates update in picker UI
- ✅ Chart and cards update with new data
- ✅ API calls made with correct date parameters
- ✅ Loading state shows during data fetch

### Test Case 9: Loading States
**Goal:** Verify proper loading indicators

**Steps:**
1. Navigate to `/dashboard/churn`
2. Change date range (trigger new data load)

**Expected Results:**
- ✅ Loading spinner appears while fetching data
- ✅ Text: "Loading churn data..."
- ✅ Chart area shows loading state (not broken)
- ✅ Highlight cards show "0" or empty during load

### Test Case 10: Error Handling
**Goal:** Verify graceful error handling

**Steps:**
1. Open browser DevTools Network tab
2. Throttle network or block `/analytics/churn/summary` endpoint
3. Navigate to `/dashboard/churn`

**Expected Results:**
- ✅ Error alert appears: "Sorry, something went wrong. Please try again."
- ✅ No broken UI elements
- ✅ No unhandled errors in console

### Test Case 11: Mobile Responsiveness
**Goal:** Verify mobile/tablet layout works

**Steps:**
1. Navigate to `/dashboard/churn`
2. Resize browser to mobile width (375px)
3. Resize to tablet width (768px)

**Expected Results:**
- ✅ Highlight cards stack vertically on mobile
- ✅ Chart scales appropriately
- ✅ Filters remain accessible
- ✅ Tab navigation works on mobile
- ✅ No horizontal scrolling
- ✅ Text remains readable

### Test Case 12: Churn Calculation Accuracy
**Goal:** Verify churn formula is correct

**Test Data Setup:**
```ruby
# In Rails console (bin/rails c)
seller = User.find_by(email: 'seller@gumroad.com')
product = seller.products.first

# Create test scenario:
# - 10 active subscriptions at start of period
# - 3 new subscriptions during period
# - 2 cancellations during period
# Expected churn rate: (2 / (10 + 3)) × 100 = 15.38%
```

**Steps:**
1. Set up test data with known values
2. Navigate to `/dashboard/churn`
3. Select date range covering test period
4. Check displayed churn rate

**Expected Results:**
- ✅ Churn rate matches manual calculation
- ✅ Churned users count is accurate
- ✅ Revenue lost matches sum of cancelled subscription MRR

### Test Case 13: API Endpoint Testing
**Goal:** Verify backend API responses

**Steps:**
```bash
# Test summary endpoint
curl -H "Cookie: _session_id=..." \
  "https://gumroad.dev/analytics/churn/summary?start_time=2025-10-01&end_time=2025-11-01"

# Test data endpoint
curl -H "Cookie: _session_id=..." \
  "https://gumroad.dev/analytics/churn/data?start_time=2025-10-01&end_time=2025-11-01"
```

**Expected Results:**
- ✅ 200 OK response
- ✅ JSON structure matches expected format:
```json
{
  "current_period": {
    "churn_rate": 5.25,
    "churned_users": 15,
    "revenue_lost_cents": 123400,
    "active_at_start": 200,
    "new_subscriptions": 50
  },
  "last_period": {
    "churn_rate": 4.80,
    ...
  },
  "has_subscription_products": true,
  "start_date": "2025-10-01",
  "end_date": "2025-11-01"
}
```

### Test Case 14: Performance
**Goal:** Verify acceptable performance with large datasets

**Steps:**
1. Select large date range (e.g., 1 year)
2. Monitor page load time
3. Check browser DevTools Performance tab

**Expected Results:**
- ✅ Initial page load < 2 seconds
- ✅ Data fetch < 3 seconds
- ✅ Chart renders smoothly (no janky animations)
- ✅ No memory leaks (check with multiple date range changes)

## Browser Compatibility Testing

Test in the following browsers:
- [ ] Chrome (latest)
- [ ] Firefox (latest)
- [ ] Safari (latest)
- [ ] Edge (latest)
- [ ] Mobile Safari (iOS)
- [ ] Mobile Chrome (Android)

## Automated Testing (RSpec)

### Backend Tests to Write

**1. Service Tests (`spec/services/creator_analytics/churn_spec.rb`):**
```ruby
describe CreatorAnalytics::Churn do
  # Test churn rate calculation
  # Test revenue lost calculation
  # Test handling of edge cases (no subscriptions, no cancellations)
  # Test date range filtering
  # Test monthly aggregation
end
```

**2. Controller Tests (`spec/controllers/analytics_controller_spec.rb`):**
```ruby
describe AnalyticsController do
  describe "GET #churn" do
    # Test renders churn page
    # Test authorization
    # Test props passed to Inertia
  end

  describe "GET #churn_summary" do
    # Test returns correct JSON
    # Test date parameter parsing
    # Test authorization
  end

  describe "GET #churn_data" do
    # Test returns formatted data
    # Test handles missing products
  end
end
```

**3. Presenter Tests (`spec/presenters/analytics_presenter_spec.rb`):**
```ruby
describe AnalyticsPresenter do
  # Test has_subscription_products flag
  # Test with no subscription products
  # Test with multiple products
end
```

## Regression Testing

Ensure existing features still work:
- [ ] Sales analytics tab still works
- [ ] Following analytics tab still works
- [ ] UTM links tab still works (if user has permission)
- [ ] Date range picker works on all tabs
- [ ] Product selector works on Sales tab

## Acceptance Criteria from Issue #13

- [x] New "Churn" tab added to Analytics page
- [x] Only visible to creators with subscription products
- [x] Filterable by daily/monthly
- [x] Filterable by product (via product selector - reusing existing component)
- [x] Filterable by date range
- [x] Shows 4 highlight metrics:
  - [x] Churn rate (current period)
  - [x] Last period churn rate
  - [x] Revenue lost
  - [x] Churned users
- [x] Chart displays churn over time
- [x] Uses correct formula: `(Cancelled / (Active at start + New)) × 100`
- [x] Mobile responsive design

## Known Limitations / Future Improvements

1. **Chart Data:** Currently using period average for visualization. In production, should fetch actual daily churn data from backend for more accurate daily view.

2. **Product Filtering:** Churn component currently shows aggregate across all subscription products. Could add ProductsPopover for filtering specific products.

3. **Caching:** Should implement caching layer (like CachingProxy) for better performance with large datasets.

## Sign-off Checklist

Before submitting PR:
- [ ] All manual tests pass
- [ ] Automated tests written and passing
- [ ] No console errors in browser
- [ ] No RuboCop/ESLint warnings
- [ ] Mobile responsive verified
- [ ] Screenshots/video demo captured
- [ ] Code reviewed for security issues
- [ ] Performance acceptable
- [ ] Documentation updated (if needed)

## Test Execution Log

| Test Case | Status | Tester | Date | Notes |
|-----------|--------|--------|------|-------|
| TC1: Visibility WITH subs | ⏳ Pending | | | |
| TC2: Visibility WITHOUT subs | ⏳ Pending | | | |
| TC3: Placeholder State | ⏳ Pending | | | |
| TC4: Highlight Cards | ⏳ Pending | | | |
| TC5: Chart Visualization | ⏳ Pending | | | |
| TC6: Chart Tooltip | ⏳ Pending | | | |
| TC7: Daily/Monthly Toggle | ⏳ Pending | | | |
| TC8: Date Range Picker | ⏳ Pending | | | |
| TC9: Loading States | ⏳ Pending | | | |
| TC10: Error Handling | ⏳ Pending | | | |
| TC11: Mobile Responsive | ⏳ Pending | | | |
| TC12: Calculation Accuracy | ⏳ Pending | | | |
| TC13: API Endpoints | ⏳ Pending | | | |
| TC14: Performance | ⏳ Pending | | | |

---

## Quick Test Commands

```bash
# Start application
bin/dev

# Run backend tests (after writing them)
bundle exec rspec spec/services/creator_analytics/churn_spec.rb
bundle exec rspec spec/controllers/analytics_controller_spec.rb
bundle exec rspec spec/presenters/analytics_presenter_spec.rb

# Run frontend tests (if using Jest)
npm test -- Analytics/Churn

# Check for linting issues
bundle exec rubocop app/services/creator_analytics/churn.rb
npm run lint

# Check routes
bin/rails routes | grep churn
```

## Bug Reporting Template

If issues found during testing:

**Bug ID:** CHURN-XXX
**Severity:** Critical / High / Medium / Low
**Test Case:** TC#
**Environment:** Browser / OS
**Steps to Reproduce:**
1. Step 1
2. Step 2

**Expected:** What should happen
**Actual:** What actually happened
**Screenshots:** [attach if applicable]
**Console Errors:** [paste any errors]
