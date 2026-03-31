# Mission

Improve test coverage for the `billing` module from the current 40% to at
least 85%, focusing on edge cases and error paths.

## Definition of Done

- Line coverage of `src/billing/` is >= 85% (measured by coverage.py)
- New tests cover: expired cards, partial refunds, currency conversion, and zero-amount invoices
- Tests are independent and can run in any order
- No mocking of the `Invoice.calculate_total()` method (it must run for real)
- All tests pass in CI (no flaky timing-dependent assertions)

## Verifier Commands

```bash
# Fast check
python -m pytest tests/test_billing.py -x -q

# Full check
python -m pytest --cov=src/billing --cov-fail-under=85 tests/test_billing*.py
```

## Context

- Billing module: `src/billing/`
- Existing tests: `tests/test_billing.py` (sparse, mostly happy-path)
- Use `unittest.mock.patch` for external payment gateway calls only
- Fixtures for test data are in `tests/conftest.py`
