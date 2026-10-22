-- The store transaction a subscriber row was last written for. RevenueCat's
-- app_user_id is chosen by the app, so another person's purchase can arrive
-- under someone else's id; the webhook uses this to keep such an event from
-- replacing or ending a subscription that belongs to a different transaction.
-- Additive and nullable: rows written before this keep working and are stamped
-- by their next event. Apply BEFORE deploying the Worker that reads it.
ALTER TABLE subscribers ADD COLUMN original_transaction_id TEXT;
