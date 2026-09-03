# Pulse iOS agent guide

## Required client gate

Run `scripts/run-client-quality-gate.sh` before claiming a client change is ready. It must pass both XCTest and the isolated XCUITest core journeys. Do not replace the generated `.xcresult` evidence with build-only validation.

The core journey gate covers:

- browsing and paging the live Feed;
- persistent Like and Comment state;
- playing another creator's generated and published Artifact;
- one-sentence generation, private preview interaction, 4+ review, publication, and Feed playback;
- visible recovery/foreground health assertions and screenshots.

## Local test accounts

| Purpose | Username | Password / sign-in | Scope |
| --- | --- | --- | --- |
| Primary client E2E account | `pulse.e2e` | None. Launch the Debug app with `PULSE_UI_TEST_USER=pulse.e2e`. | Isolated local development API only |
| Other-content fixture owner | `pulse.fixture.creator` | None. Seeded by `CoreUserJourneyUITests` through the local API header authenticator. | Isolated local development API only |
| Fixture review operator | `pulse.e2e.operator` | None. Used only by test setup with `X-Pulse-Admin`. | Isolated local development API only |

These are synthetic accounts, not Apple IDs. `PulseLocalTestIdentity` accepts the primary identity only in a Debug build and only for `localhost`/`127.0.0.1`; Release builds compile the hook inert. Never create matching production or staging accounts, never add a real password/token to this file, and never point these tests at shared data.

The gate starts the sibling `pulse-api` repository on `127.0.0.1:18787` with a temporary data file, deterministic generation, and a disposable Simulator. It deletes that data and Simulator on exit. Override only the API checkout location with `PULSE_API_REPO=/absolute/path/to/pulse-api`.
