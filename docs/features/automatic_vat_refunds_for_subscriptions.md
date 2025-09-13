# Automatic VAT Refunds for Recurring Subscriptions

## Overview

This feature implements automatic VAT refunds for recurring subscription charges when customers have valid VAT IDs. Previously, customers needed to manually generate VAT refunds for every subscription charge, which caused confusion and increased support burden.

## How It Works

### Automatic VAT Refunds During Billing

1. **During Subscription Creation**: When a customer enters a VAT ID during checkout, it's validated and stored with the original purchase.

2. **During Recurring Charges**: When a subscription is charged:
   - The system checks if the subscription has a valid VAT ID
   - If VAT was collected on the charge and a valid VAT ID exists, an automatic VAT refund is applied immediately after the successful charge
   - The refund is processed automatically without customer intervention

3. **VAT ID Validation**: The system validates VAT IDs using country-specific validation services:
   - EU countries: `VatValidationService` (VIES system)
   - Australia: `AbnValidationService`
   - Singapore: `GstValidationService`
   - Canada (Quebec): `QstValidationService`
   - Other countries: Country-specific validation services

### Adding VAT ID After Subscription Creation

Customers can add VAT IDs to existing subscriptions through the subscription management interface:

1. **Endpoint**: `PATCH /subscriptions/:id/update_vat_id`
2. **Validation**: The VAT ID is validated against the customer's country
3. **Retroactive Refunds**: Recent charges (within 30 days) that haven't been refunded will automatically receive VAT refunds
4. **Future Charges**: All future subscription charges will automatically receive VAT refunds

## Implementation Details

### Core Components

#### 1. Subscription Model (`app/models/subscription.rb`)

**New Methods:**
- `apply_automatic_vat_refund(purchase)`: Applies automatic VAT refund to successful recurring charges
- `has_valid_vat_id?(purchase)`: Checks if subscription has a valid VAT ID
- `validate_vat_id_for_country(vat_id, country_code)`: Validates VAT ID using country-specific services
- `get_business_vat_id_for_purchase(purchase)`: Retrieves VAT ID from purchase or original purchase

**Modified Methods:**
- `handle_purchase_success(purchase)`: Now calls `apply_automatic_vat_refund` after successful charges

#### 2. VAT ID Update Service (`app/services/subscription/vat_id_update_service.rb`)

Handles updating VAT IDs for existing subscriptions:
- Validates input parameters
- Validates VAT ID against customer's country
- Updates subscription's original purchase with new VAT ID
- Applies retroactive refunds to recent eligible charges
- Provides detailed error handling and logging

#### 3. Controller Endpoint (`app/controllers/subscriptions_controller.rb`)

**New Action:**
- `update_vat_id`: Allows customers to update VAT ID for their subscription

**Route:**
- `PATCH /subscriptions/:id/update_vat_id`

### Business Logic

#### Automatic Refund Conditions

A VAT refund is automatically applied when:
1. Purchase is successful
2. Purchase has VAT collected (`gumroad_tax_cents > 0`)
3. Purchase is a recurring charge (not the original subscription purchase)
4. Subscription has a valid VAT ID
5. VAT ID passes country-specific validation

#### Retroactive Refund Conditions

When a VAT ID is added to an existing subscription, retroactive refunds are applied to:
1. Successful purchases within the last 30 days
2. Purchases with VAT collected (`gumroad_tax_cents > 0`)
3. Non-original subscription purchases
4. Purchases that haven't already received VAT refunds

#### Error Handling

- VAT refund failures don't cause subscription charges to fail
- All errors are logged with detailed information
- Service provides user-friendly error messages
- Validation errors prevent invalid VAT IDs from being stored

## API Usage

### Update VAT ID for Existing Subscription

```bash
curl -X PATCH "https://gumroad.com/subscriptions/SUBSCRIPTION_ID/update_vat_id" \
  -H "Content-Type: application/json" \
  -d '{"vat_id": "DE123456789"}'
```

**Success Response:**
```json
{
  "success": true,
  "message": "VAT ID updated successfully. Future charges will automatically receive VAT refunds."
}
```

**Error Response:**
```json
{
  "success": false,
  "errors": ["Invalid VAT ID for country DE"]
}
```

## Testing

Comprehensive test coverage includes:

1. **Unit Tests** (`spec/models/subscription/automatic_vat_refund_spec.rb`):
   - Automatic VAT refund application
   - VAT ID validation for different countries
   - Error handling scenarios

2. **Service Tests** (`spec/services/subscription/vat_id_update_service_spec.rb`):
   - VAT ID update functionality
   - Retroactive refund application
   - Input validation and error handling

3. **Controller Tests** (`spec/controllers/subscriptions_controller_spec.rb`):
   - API endpoint functionality
   - Authentication and authorization
   - Response format validation

## Logging and Monitoring

The system provides detailed logging for:
- Automatic VAT refund applications (success and failure)
- VAT ID updates
- Retroactive refund processing
- Validation errors

Log messages include subscription and purchase IDs for easy tracking and debugging.

## Customer Benefits

1. **Seamless Experience**: VAT refunds are applied automatically without customer action
2. **Immediate Refunds**: Refunds are processed immediately after successful charges
3. **Retroactive Application**: Adding a VAT ID applies refunds to recent charges
4. **Reduced Support Burden**: Eliminates confusion about VAT refund process

## Technical Benefits

1. **Robust Validation**: Uses existing country-specific VAT validation services
2. **Error Resilience**: VAT refund failures don't affect subscription billing
3. **Comprehensive Logging**: Full audit trail for debugging and monitoring
4. **Backward Compatible**: Doesn't affect existing subscription functionality

## Migration Notes

- No database migrations required (uses existing `business_vat_id` field)
- Feature is automatically enabled for all subscriptions
- Existing subscriptions can add VAT IDs through the new endpoint
- No changes required to existing checkout flow
