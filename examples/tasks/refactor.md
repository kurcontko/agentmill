# Mission

Extract the duplicated email-sending logic from three controller files into a
single `EmailService` class with a clean interface.

## Definition of Done

- New `src/services/email_service.ts` contains all email logic
- `UserController`, `OrderController`, and `NotificationController` use the new service
- No duplicated SMTP configuration or template-rendering code remains
- All existing tests pass without modification
- No new dependencies added

## Verifier Commands

```bash
# Fast check
npx tsc --noEmit

# Full check
npm test && npx eslint src/
```

## Context

- The three controllers are in `src/controllers/`
- Templates live in `src/templates/emails/` and use Handlebars
- SMTP config is currently copy-pasted in each controller; move it to env-based config
