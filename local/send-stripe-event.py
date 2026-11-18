"""Sends a signed fake Stripe webhook to PaymentService, for local testing with the fake Stripe gateway.

With real Stripe test keys use the Stripe CLI instead (Stripe CLI: `stripe listen --forward-to`); its events reference real Stripe
objects, which only exist when PaymentService talks to real Stripe.

Usage:
  python local/send-stripe-event.py payment-failed <stripe_subscription_id>
  python local/send-stripe-event.py payment-failed-old-api <stripe_subscription_id>   # invoice.subscription (API < 2025-03-31)
  python local/send-stripe-event.py subscription-deleted <stripe_subscription_id>
  python local/send-stripe-event.py subscription-unpaid <stripe_subscription_id>      # customer.subscription.updated, unpaid

Options (environment variables):
  WEBHOOK_URL     default http://localhost:8000/stripe/webhooks (gateway); use http://localhost:5264/stripe/webhooks
                  when PaymentService runs from the IDE without the gateway
  WEBHOOK_SECRET  default whsec_REPLACE_ME (PaymentService appsettings.Development.json)

Find a subscription id:
  docker exec rso-postgres psql -U rso -d PaymentServiceDb -c "select data->>'StripeSubscriptionId', data->>'Status' from mt_doc_subscription"
"""
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

url = os.environ.get("WEBHOOK_URL", "http://localhost:8000/stripe/webhooks")
secret = os.environ.get("WEBHOOK_SECRET", "whsec_REPLACE_ME")

if len(sys.argv) != 3 or sys.argv[1] not in ("payment-failed", "payment-failed-old-api", "subscription-deleted",
                                             "subscription-unpaid"):
    sys.exit(__doc__)
kind, subscription_id = sys.argv[1], sys.argv[2]

if kind == "payment-failed":
    event_type = "invoice.payment_failed"
    obj = {
        "id": "in_test_" + uuid.uuid4().hex[:16],
        "object": "invoice",
        "status": "open",
        "parent": {"type": "subscription_details", "subscription_details": {"subscription": subscription_id}},
    }
elif kind == "payment-failed-old-api":
    # What a webhook endpoint on an API version before 2025-03-31 sends: no "parent", the subscription at the top level.
    event_type = "invoice.payment_failed"
    obj = {"id": "in_test_" + uuid.uuid4().hex[:16], "object": "invoice", "status": "open", "subscription": subscription_id}
elif kind == "subscription-unpaid":
    event_type = "customer.subscription.updated"
    obj = {"id": subscription_id, "object": "subscription", "status": "unpaid"}
else:
    event_type = "customer.subscription.deleted"
    obj = {"id": subscription_id, "object": "subscription", "status": "canceled"}

event = {
    "id": "evt_test_" + uuid.uuid4().hex[:16],
    "object": "event",
    "api_version": "2025-09-30.clover",
    "created": int(time.time()),
    "livemode": False,
    "type": event_type,
    "data": {"object": obj},
}

body = json.dumps(event).encode()
timestamp = str(int(time.time()))
signature = hmac.new(secret.encode(), f"{timestamp}.".encode() + body, hashlib.sha256).hexdigest()
request = urllib.request.Request(
    url, data=body, method="POST",
    headers={"Content-Type": "application/json", "Stripe-Signature": f"t={timestamp},v1={signature}"})

try:
    status = urllib.request.urlopen(request).status
except urllib.error.HTTPError as e:
    status = e.code
print(f"{event_type} {event['id']} -> {status}")
