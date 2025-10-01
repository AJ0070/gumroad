# Manage webhooks for Gumroad partner account

### Generate access token

```
curl <https://api.paypal.com/v1/oauth2/token> \\
  -H "Accept: application/json" \\
  -H "Accept-Language: en_US" \\
  -u "<client_id>:<client_secret>" \\
  -d "grant_type=client_credentials"
```

### Fetch Webhooks

```
curl -v -X GET <https://api.paypal.com/v1/notifications/webhooks> \\
-H "Content-Type:application/json" \\
-H "Authorization: Bearer <access_token>"
```

### Register Webhook

```
curl -v -X POST <https://api.paypal.com/v1/notifications/webhooks> \\
-H "Content-Type:application/json" \\
-H "Authorization: Bearer <access_token>" \\
-d '{
  "url": "https://<URL>/paypal-webhook",
  "event_types": [
  {
    "name": "CHECKOUT.ORDER.PROCESSED"
  }
  ]
}'
```

### Update Webhook

List of all the required Paypal webhooks is maintained here.

```
curl -v -X PATCH <https://api.paypal.com/v1/notifications/webhooks/><webhook-id> \\
-H "Content-Type:application/json" \\
-H "Authorization: Bearer <access_token>" \\
-d '[
  {
  "op": "replace",
  "path": "/event_types",
  "value": [
    {
      "name": "CHECKOUT.ORDER.PROCESSED"
    },
    {
      "name":"CUSTOMER.DISPUTE.CREATED"
    },
    {
      "name":"CUSTOMER.DISPUTE.RESOLVED"
    },
    {
      "name":"CUSTOMER.DISPUTE.UPDATED"
    },
    {
      "name": "MERCHANT.PARTNER-CONSENT.REVOKED"
    },
    {
      "name": "PAYMENT.CAPTURE.COMPLETED"
    },
    {
      "name": "PAYMENT.CAPTURE.DENIED"
    },
    {
      "name":"PAYMENT.CAPTURE.PENDING"
    },
    {
      "name": "PAYMENT.CAPTURE.REFUNDED"
    },
    {
      "name":"PAYMENT.CAPTURE.REVERSED"
    },
    {
      "name":"PAYMENT.ORDER.CREATED"
    },
    {
      "name": "PAYMENT.REFERENCED-PAYOUT-ITEM.COMPLETED"
    }
  ]
  }
]'
```

### Delete Webhook

```
curl -v -X DELETE <https://api.paypal.com/v1/notifications/webhooks/><webhook-id> \\
-H "Content-Type:application/json" \\
-H "Authorization: Bearer <access_token>"
```

# Links related to Paypal's Instant Payment Notification(IPN) feature

IPN simulator Guide

https://developer.paypal.com/docs/classic/ipn/integration-guide/IPNSimulator/

(IPN) settings (Live)

https://www.paypal.com/cgi-bin/customerprofileweb?cmd=_profile-ipn-notify

IPN Simulator

https://developer.paypal.com/developer/ipnSimulator/

Site to view sample webhook data

[https://webhook.site](https://webhook.site/)

IPN history

https://www.paypal.com/us/cgi-bin/webscr?cmd=_display-ipns-history

# Orders API sample application setup Instructions

1. Clone repo - https://github.com/sharang-d/orders
2. Create file `paypal.rb` in config/initializers/
3. Add POST endpoint in the application to handle webhook notifications
4. Change webhook URL in Paypal Developer account.
   1. Login [paypal@gumroad.com](mailto:paypal@gumroad.com) account
   2. Go to dashboard
   3. Click on `My Apps & Credentials`
   4. Under `REST API apps` section Click on `Gumroad` Application.
   5. Under `Sandbox Webhooks` section Add webhook URL of your application.

`paypal.rb`

```
PAYPAL_ENDPOINT = "<https://api-3t.sandbox.paypal.com/nvp>"
PAYPAL_REST_ENDPOINT = "<https://api.sandbox.paypal.com>"
PAYPAL_ENV = "sandbox"
PAYPAL_CLIENT_ID = "AQiKjZAqXGcN_oU8wh-RKelv6Nf3IrWVY9J9rrhz1pF7aqiyZjutSdG75I6ahd3zJe1ThpklFp5jNman"
PAYPAL_CLIENT_SECRET = "EPnNdtAW6jsUleHWQmjsFNef37f1GGWLwtJx3uO2PRdbENAFxTgW1WA1V83MVYvSrRrkH0tXNevE0CJ_"
PAYPAL_LIB_MODE = "sandbox"
PAYPAL_URL = "<https://www.sandbox.paypal.com>"
PAYPAL_MERCHANT_ID = "5SCHBGJUCTP2U"
PAYPAL_USER_EMAIL = "paypal-facilitator@gumroad.com"
PAYPAL_USER = "paypal-facilitator_api1.gumroad.com"
PAYPAL_PASS = "1383112423"
PAYPAL_SIGNATURE = "AFcWxV21C7fd0v3bYYYRCpSSRl31A9TRhGDrqj7x7lF9P6NGOruW.7ak"

PayPal::SDK.configure(
  :mode => PAYPAL_ENV,
  :client_id => PAYPAL_CLIENT_ID,
  :client_secret => PAYPAL_CLIENT_SECRET,
  :username => PAYPAL_USER,
  :password => PAYPAL_PASS,
  :signature => PAYPAL_SIGNATURE
)
```

[PayPal Connect test accounts](https://www.notion.so/PayPal-Connect-test-accounts-43bc5312793a44e4a44d9503ca921f34?pvs=21)

# PayPal Dispute Handling

Gumroad supports automatic dispute handling for PayPal transactions, similar to the existing Stripe dispute handling system. This feature allows Gumroad to automatically provide evidence for PayPal disputes, including license key information when applicable.

## Overview

The PayPal dispute handling system automatically:
- Detects when a customer files a dispute with PayPal
- Collects relevant evidence including customer information, product details, and license key data
- Submits evidence to PayPal through the Disputes API
- Tracks the status of disputes through resolution

## Implementation Details

### Key Components

1. **PaypalChargeProcessor** (`app/business/payments/charging/implementations/paypal/paypal_charge_processor.rb`)
   - Contains the `fight_chargeback` method that handles dispute evidence submission
   - Builds evidence payload including license key information
   - Determines appropriate action (appeal vs provide evidence) based on dispute status
   - Handles PayPal dispute events:
     - `handle_dispute_created_event`: Processes new dispute notifications
     - `handle_dispute_updated_event`: Processes dispute status changes
     - `handle_dispute_resolved_event`: Processes dispute resolution notifications

2. **PaypalRestApi** (`app/business/payments/charging/implementations/paypal/paypal_rest_api.rb`)
   - Provides methods for interacting with PayPal Disputes API:
     - `get_dispute`: Retrieves dispute details
     - `appeal_dispute`: Appeals a dispute decision
     - `provide_evidence_for_dispute`: Provides evidence for an active dispute
   - Builds proper evidence payload structure for PayPal API

3. **PaypalEventType** (`app/business/payments/events/paypal/paypal_event_type.rb`)
   - Defines dispute event constants:
     - `CUSTOMER.DISPUTE.CREATED`: Triggers dispute creation
     - `CUSTOMER.DISPUTE.UPDATED`: Handles dispute status changes
     - `CUSTOMER.DISPUTE.RESOLVED`: Updates dispute status
   - Includes dispute events in `ORDER_API_EVENTS` for proper routing

3. **DisputeEvidence Model** (`app/models/dispute_evidence.rb`)
   - Extended to include license key fields:
     - `license_key`: The license key serial number
     - `license_key_activation_count`: Number of times the license has been activated

4. **DisputeEvidence Service** (`app/services/dispute_evidence/create_from_dispute_service.rb`)
   - Automatically populates license key information when creating dispute evidence
   - Retrieves license data from the `License` model for licensed products

### Dispute Evidence Included

The system automatically includes the following evidence in PayPal disputes:

#### Customer Information
- Customer email address
- Customer name
- Billing address
- Shipping address (if applicable)

#### Product Information
- Product description
- Purchase details and receipt URL
- Reason for winning the dispute

#### License Key Information (for licensed products)
- **License key**: The actual license key provided to the customer
- **License key activation count**: Number of times the license has been activated (serves as proof of use)

#### Shipping Information (for physical products)
- Shipping carrier
- Tracking number
- Shipping date

## API Endpoints Used

### Get Dispute Details
```
GET /v1/customer/disputes/{dispute_id}
```

### Appeal Dispute
```
POST /v1/customer/disputes/{dispute_id}/appeal
```

### Provide Evidence
```
POST /v1/customer/disputes/{dispute_id}/provide-evidence
```

## Evidence Payload Structure

The system builds evidence in the following structure for PayPal:

```json
{
  "evidence_type": "OTHER",
  "evidence_info": {
    "customer_email": "customer@example.com",
    "customer_name": "John Doe",
    "billing_address": "123 Main St, City, State 12345",
    "shipping_address": "123 Main St, City, State 12345",
    "product_description": "Product name and details",
    "tracking_number": "1Z9999W99999999999",
    "notes": "Reason for winning the dispute",
    "license_key": "LICENSE-KEY-123",
    "license_key_activation_count": 3
  }
}
```

## License Key Activation as Evidence

One of the strongest pieces of evidence for software/product disputes is the license key activation count:

- **License key**: Proves the customer received access to the product
- **Activation count**: Shows the customer has actually used the product
  - Count > 0: Strong evidence the customer accessed and used the product
  - Count = 0: Customer received the key but hasn't used it yet

This information is particularly effective in disputes where customers claim:
- They never received the product
- The product doesn't work
- Unauthorized transaction

## Error Handling

The system includes comprehensive error handling:

- **Dispute retrieval failures**: Raises `ChargeProcessorInvalidRequestError` with specific error details
- **Evidence submission failures**: Handles API errors and provides meaningful error messages
- **License key lookup failures**: Gracefully handles cases where license keys don't exist

## Testing

Comprehensive test coverage is provided in:
- `spec/business/payments/charging/implementations/paypal/paypal_dispute_handling_spec.rb`
- `spec/services/dispute_evidence/create_from_dispute_service_spec.rb`

Tests cover:
- Successful dispute evidence submission
- License key information inclusion
- Error handling scenarios
- Evidence payload construction

## Requirements

To use PayPal dispute handling:

1. **PayPal Partner Account**: Must have necessary Disputes API scopes
2. **Merchant Permissions**: Merchants must have granted dispute handling permissions during onboarding
3. **Transaction Requirements**: Only transactions created through Gumroad's partner credentials can be handled

## Webhook Events

The system listens for these PayPal webhook events:
- `CUSTOMER.DISPUTE.CREATED`: Triggers dispute creation and evidence collection
- `CUSTOMER.DISPUTE.UPDATED`: Handles dispute status changes (e.g., WAITING_FOR_BUYER_RESPONSE → UNDER_REVIEW)
- `CUSTOMER.DISPUTE.RESOLVED`: Updates dispute status and final outcome

### Dispute Event Handling Flow

1. **Dispute Created** (`CUSTOMER.DISPUTE.CREATED`)
   - Creates dispute record in Gumroad system
   - Triggers automatic evidence collection
   - May trigger automatic evidence submission if configured

2. **Dispute Updated** (`CUSTOMER.DISPUTE.UPDATED`)
   - Logs status changes for monitoring
   - Provides foundation for future automation (e.g., timed evidence submission)
   - Tracks dispute progression through PayPal's workflow

3. **Dispute Resolved** (`CUSTOMER.DISPUTE.RESOLVED`)
   - Updates dispute record with final outcome
   - Triggers seller notifications
   - Updates financial records based on dispute result

## Integration with Existing System

The PayPal dispute handling integrates seamlessly with Gumroad's existing dispute system:

- Uses the same `Dispute` and `DisputeEvidence` models as Stripe
- Follows the same workflow through `FightDisputeJob`
- Maintains consistency with existing dispute UI and reporting
- Supports the same evidence collection and submission patterns

## Monitoring and Logging

The system includes detailed logging for:
- Dispute event reception
- Evidence submission attempts
- API response handling
- Error conditions
- License key lookup results

This enables effective monitoring and troubleshooting of dispute handling performance.
