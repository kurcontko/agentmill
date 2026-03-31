# Mission

Fix the race condition in `OrderService.checkout()` that causes duplicate
charges when users double-click the submit button.

## Definition of Done

- Concurrent checkout calls for the same cart return 409 Conflict on the second call
- A database-level lock or unique constraint prevents duplicate payment records
- The fix is covered by at least one new test that simulates concurrent requests
- No changes to the public API contract

## Verifier Commands

```bash
# Fast check
python -m pytest tests/test_checkout.py -x -q

# Full check
python -m pytest && python -m mypy src/
```

## Context

- Checkout handler: `src/services/order_service.py`
- Payments are recorded in the `payments` table via SQLAlchemy
- PostgreSQL is the production database; tests use SQLite
